#!/usr/bin/env bash
# =============================================================================
#  ELK Stack Setup Script — v8.x with Fleet Server + Elastic Agent
#  Usage:
#    chmod +x setup.sh
#    ./setup.sh [--help] [--down] [--clean]
#
#  Environment variables are read from the .env file in the same directory.
#  Copy .env.example to .env and edit before running.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

banner() {
  echo -e "${CYAN}${BOLD}"
  echo "  ███████╗██╗     ██╗  ██╗"
  echo "  ██╔════╝██║     ██║ ██╔╝"
  echo "  █████╗  ██║     █████╔╝ "
  echo "  ██╔══╝  ██║     ██╔═██╗ "
  echo "  ███████╗███████╗██║  ██╗"
  echo "  ╚══════╝╚══════╝╚═╝  ╚═╝  Stack Setup — v9.x"
  echo -e "${RESET}"
}

info()    { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
section() { echo -e "\n${BLUE}${BOLD}──── $* ────${RESET}\n"; }

# ─── Help ─────────────────────────────────────────────────────────────────────
usage() {
  echo "Usage: $0 [--down] [--clean] [--help]"
  echo ""
  echo "  (no args)   Start / bring up the ELK stack"
  echo "  --down      Stop all containers (keep volumes)"
  echo "  --clean     Stop all containers AND remove all volumes (data loss!)"
  echo "  --help      Show this help message"
  exit 0
}

# ─── Argument parsing ──────────────────────────────────────────────────────────
ACTION="up"
for arg in "$@"; do
  case "$arg" in
    --help)  usage ;;
    --down)  ACTION="down" ;;
    --clean) ACTION="clean" ;;
    *) error "Unknown argument: $arg"; usage ;;
  esac
done

banner

# ─── Pre-flight checks ────────────────────────────────────────────────────────
section "Pre-flight Checks"

command -v docker   >/dev/null 2>&1 || { error "docker is not installed.";         exit 1; }
command -v docker   >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 \
  || { error "docker compose plugin is not installed."; exit 1; }
command -v curl     >/dev/null 2>&1 || { error "curl is required.";                exit 1; }
command -v openssl  >/dev/null 2>&1 || warn "openssl not found — password generation will fall back to /dev/urandom."

info "Docker:         $(docker --version)"
info "Docker Compose: $(docker compose version)"

# Check .env file
if [[ ! -f "${ENV_FILE}" ]]; then
  error ".env file not found at ${ENV_FILE}"
  echo  "  Hint: cp .env.example .env  then edit the values."
  exit 1
fi

# Load env vars for use in this script
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

info ".env loaded: STACK_VERSION=${STACK_VERSION}, CLUSTER=${CLUSTER_NAME}"

# ─── Validate required variables ──────────────────────────────────────────────
section "Validating Configuration"

REQUIRED_VARS=(
  STACK_VERSION CLUSTER_NAME ELASTICSEARCH_NODE_NAME
  ELASTIC_PASSWORD KIBANA_SYSTEM_PASSWORD
  KIBANA_ENCRYPTION_KEY KIBANA_REPORTING_ENCRYPT_KEY
  ES_PORT KIBANA_PORT FLEET_SERVER_PORT APM_SERVER_PORT
  ES_JVM_HEAP ES_MEM_LIMIT ES_CPU_LIMIT
  KIBANA_MEM_LIMIT FLEET_MEM_LIMIT
  ES_MAX_SHARDS_PER_NODE ES_WATERMARK_LOW ES_WATERMARK_HIGH ES_WATERMARK_FLOOD_STAGE
)

MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    MISSING+=("$var")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  error "The following required variables are not set in .env:"
  for v in "${MISSING[@]}"; do echo "    • $v"; done
  exit 1
fi

# Warn about default passwords
if [[ "${ELASTIC_PASSWORD}" == "changeme_elastic" || "${KIBANA_SYSTEM_PASSWORD}" == "changeme_kibana_system" ]]; then
  warn "You are using DEFAULT PASSWORDS. Change them in .env before production use!"
fi

# Warn about short encryption keys
if [[ ${#KIBANA_ENCRYPTION_KEY} -lt 32 ]]; then
  error "KIBANA_ENCRYPTION_KEY must be at least 32 characters."
  exit 1
fi

info "All required variables validated ✓"

# ─── Validate numeric limits ───────────────────────────────────────────────────
section "Validating Resource Limits"

validate_mem() {
  local val="$1" name="$2"
  if ! [[ "$val" =~ ^[0-9]+(m|g|M|G|mb|gb|MB|GB)$ ]]; then
    error "${name}='${val}' is not a valid memory value (e.g. 512m, 2g)"
    exit 1
  fi
  info "  ${name} = ${val} ✓"
}
validate_mem "${ES_MEM_LIMIT}"       "ES_MEM_LIMIT"
validate_mem "${KIBANA_MEM_LIMIT}"   "KIBANA_MEM_LIMIT"
validate_mem "${FLEET_MEM_LIMIT}"    "FLEET_MEM_LIMIT"
validate_mem "${ES_JVM_HEAP}"        "ES_JVM_HEAP"

info "Resource limits validated ✓"

# ─── Check vm.max_map_count (macOS: Docker Desktop handles this automatically) ──
section "System Requirements"

if [[ "$(uname -s)" == "Linux" ]]; then
  CURRENT_MAP_COUNT=$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)
  if [[ "${CURRENT_MAP_COUNT}" -lt 262144 ]]; then
    warn "vm.max_map_count is ${CURRENT_MAP_COUNT} (need >= 262144 for Elasticsearch)"
    info "Applying: sudo sysctl -w vm.max_map_count=262144"
    sudo sysctl -w vm.max_map_count=262144
    echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-elk.conf >/dev/null
    info "vm.max_map_count updated and persisted ✓"
  else
    info "vm.max_map_count=${CURRENT_MAP_COUNT} ✓"
  fi
else
  info "macOS detected — Docker Desktop handles vm.max_map_count automatically ✓"
fi

# ─── Create required directories ──────────────────────────────────────────────
section "Creating Directories"

mkdir -p "${SCRIPT_DIR}/config/certs"

info "Directories ready ✓"

# ─── Handle --down / --clean ──────────────────────────────────────────────────
if [[ "${ACTION}" == "down" ]]; then
  section "Stopping Containers"
  docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" down
  info "Stack stopped (volumes preserved)."
  exit 0
fi

if [[ "${ACTION}" == "clean" ]]; then
  section "⚠️  Removing Containers AND Volumes"
  warn "This will DELETE all ELK data. Sleeping 5 s — press Ctrl-C to abort..."
  sleep 5
  docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" down -v --remove-orphans
  info "Stack and volumes removed."
  exit 0
fi

# ─── Pull images ──────────────────────────────────────────────────────────────
section "Pulling Docker Images (${STACK_VERSION})"
docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" pull
info "Images pulled ✓"

# ─── Provision Initial Let's Encrypt Cert ─────────────────────────────────────
if [[ -n "${ELK_SERVER_DOMAIN}" ]] && [[ "${ELK_SERVER_DOMAIN}" != "YOUR_ELK_SERVER_IP_OR_HOSTNAME" ]] && [[ "${ELK_SERVER_DOMAIN}" != "YOUR_ELK_SERVER_IP" ]]; then
  if [[ ! -d "./letsencrypt/live/${ELK_SERVER_DOMAIN}" ]]; then
    section "Provisioning initial Let's Encrypt Certificate for ${ELK_SERVER_DOMAIN}"
    info "Temporarily binding to Port 80 to request certificate..."
    # Ensure Port 80 is not currently in use by an old nginx container
    docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" stop nginx 2>/dev/null || true
    
    docker run -it --rm --name certbot-init \
      -v "$(pwd)/letsencrypt:/etc/letsencrypt" \
      -v "$(pwd)/certbot-www:/var/www/certbot" \
      -p 80:80 \
      certbot/certbot certonly --standalone \
      -d "${ELK_SERVER_DOMAIN}" \
      --non-interactive --agree-tos -m admin@"${ELK_SERVER_DOMAIN}" || {
        error "Failed to obtain Let's Encrypt certificate! Please ensure Port 80 is open in your AWS Security Group to 0.0.0.0/0."
        exit 1
      }
    info "Certificate provisioned successfully ✓"
  fi
fi

# ─── Start Stack ──────────────────────────────────────────────────────────────
section "Starting ELK Stack"
docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d --remove-orphans
info "Containers started ✓"

# ─── Wait for Elasticsearch ───────────────────────────────────────────────────
section "Waiting for Elasticsearch"
ES_URL="https://localhost:${ES_PORT}"
CERT_PATH="${SCRIPT_DIR}/config/certs/ca/ca.crt"

MAX_RETRIES=60
ATTEMPT=0
until curl -sk --cacert "${CERT_PATH}" \
      -u "elastic:${ELASTIC_PASSWORD}" \
      "${ES_URL}/_cluster/health" \
      | grep -qE '"status":"(green|yellow)"' 2>/dev/null; do
  ATTEMPT=$((ATTEMPT + 1))
  if [[ ${ATTEMPT} -ge ${MAX_RETRIES} ]]; then
    error "Elasticsearch did not become healthy within $((MAX_RETRIES * 5)) seconds."
    docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" logs elasticsearch | tail -50
    exit 1
  fi
  echo -ne "\r  Waiting... attempt ${ATTEMPT}/${MAX_RETRIES}"
  sleep 5
done
echo ""
info "Elasticsearch is healthy ✓"

# ─── Wait for Kibana ──────────────────────────────────────────────────────────
section "Waiting for Kibana"
KIBANA_URL="https://localhost:${KIBANA_PORT}"
ATTEMPT=0
until curl -sk \
      -u "elastic:${ELASTIC_PASSWORD}" \
      "${KIBANA_URL}/api/status" \
      | grep -q '"overall":{"level":"available"' 2>/dev/null; do
  ATTEMPT=$((ATTEMPT + 1))
  if [[ ${ATTEMPT} -ge 60 ]]; then
    error "Kibana did not become available within 300 seconds."
    docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" logs kibana | tail -50
    exit 1
  fi
  echo -ne "\r  Waiting... attempt ${ATTEMPT}/60"
  sleep 5
done
echo ""
info "Kibana is available ✓"

# ─── Generate Fleet enrollment token ──────────────────────────────────────────
section "Fleet Server — Enrollment Token"

info "Initializing Fleet..."
curl -sk \
  --cacert "${CERT_PATH}" \
  -u "elastic:${ELASTIC_PASSWORD}" \
  -X POST \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  "${KIBANA_URL}/api/fleet/setup" >/dev/null 2>&1

# Give Kibana a few seconds to build the default policies in its database
sleep 5

info "Updating default Fleet Output for Nginx SSL compatibility..."
OUTPUT_ID=$(curl -sk --cacert "${CERT_PATH}" -u "elastic:${ELASTIC_PASSWORD}" "${KIBANA_URL}/api/fleet/outputs" | grep -o '"id":"[^"]*"' | head -n 1 | cut -d'"' -f4)
if [[ -n "${OUTPUT_ID}" ]]; then
  curl -sk \
    --cacert "${CERT_PATH}" \
    -u "elastic:${ELASTIC_PASSWORD}" \
    -X PUT \
    -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    "${KIBANA_URL}/api/fleet/outputs/${OUTPUT_ID}" \
    -d '{
      "name": "default",
      "type": "elasticsearch",
      "hosts": ["https://'${ELK_SERVER_DOMAIN}':9200"],
      "is_default": true,
      "is_default_monitoring": true,
      "config_yaml": "ssl.verification_mode: none"
    }' >/dev/null 2>&1
  info "Default Fleet Output updated successfully ✓"
fi

info "Creating Fleet enrollment token..."
TOKEN_RESPONSE=$(curl -sk \
  --cacert "${CERT_PATH}" \
  -u "elastic:${ELASTIC_PASSWORD}" \
  -X POST \
  -H "kbn-xsrf: true" \
  -H "Content-Type: application/json" \
  "${KIBANA_URL}/api/fleet/enrollment_api_keys" \
  -d '{"policy_id":"fleet-server-policy"}' 2>/dev/null || echo "")

ENROLLMENT_TOKEN=$(echo "${TOKEN_RESPONSE}" | grep -o '"api_key":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")

if [[ -n "${ENROLLMENT_TOKEN}" ]]; then
  # Persist token back into .env
  if grep -q "^FLEET_ENROLLMENT_TOKEN=" "${ENV_FILE}"; then
    sed -i.bak "s|^FLEET_ENROLLMENT_TOKEN=.*|FLEET_ENROLLMENT_TOKEN=${ENROLLMENT_TOKEN}|" "${ENV_FILE}"
  else
    echo "FLEET_ENROLLMENT_TOKEN=${ENROLLMENT_TOKEN}" >> "${ENV_FILE}"
  fi
  info "Fleet enrollment token saved to .env ✓"
  info "Use this token with install-agent.sh on your remote servers."
else
  warn "Could not auto-generate Fleet enrollment token."
  warn "Generate it manually via Kibana → Fleet → Enrollment Tokens."
fi

# ─── Apply Elasticsearch cluster-level settings ────────────────────────────────
section "Applying Elasticsearch Cluster Settings"

SETTINGS=$(cat <<EOF
{
  "persistent": {
    "cluster.max_shards_per_node":                              ${ES_MAX_SHARDS_PER_NODE},
    "indices.recovery.max_bytes_per_sec":                       "${ES_RECOVERY_MAX_BYTES_PER_SEC}",
    "cluster.routing.allocation.disk.watermark.low":            "${ES_WATERMARK_LOW}",
    "cluster.routing.allocation.disk.watermark.high":           "${ES_WATERMARK_HIGH}",
    "cluster.routing.allocation.disk.watermark.flood_stage":    "${ES_WATERMARK_FLOOD_STAGE}",
    "thread_pool.write.queue_size":                             ${ES_THREADPOOL_WRITE_QUEUE},
    "thread_pool.search.queue_size":                            ${ES_THREADPOOL_SEARCH_QUEUE}
  }
}
EOF
)

SETTINGS_RESP=$(curl -sk \
  --cacert "${CERT_PATH}" \
  -u "elastic:${ELASTIC_PASSWORD}" \
  -X PUT \
  -H "Content-Type: application/json" \
  "${ES_URL}/_cluster/settings" \
  -d "${SETTINGS}" || echo "{}")

if echo "${SETTINGS_RESP}" | grep -q '"acknowledged":true'; then
  info "Cluster settings applied ✓"
else
  warn "Cluster settings may not have been applied. Response: ${SETTINGS_RESP}"
fi

# ─── Index Lifecycle Management (ILM) policy ───────────────────────────────────────
section "Applying ILM Policy (Log Volume Control)"

# Retention days & rollover thresholds are read from .env
ILM_POLICY=$(
cat <<EOF
{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": {
            "max_age":            "${ILM_ROLLOVER_MAX_AGE}",
            "max_primary_shard_size": "${ILM_ROLLOVER_MAX_SHARD_SIZE}"
          },
          "set_priority": { "priority": 100 }
        }
      },
      "warm": {
        "min_age": "${ILM_WARM_AFTER}",
        "actions": {
          "shrink":     { "number_of_shards": 1 },
          "forcemerge": { "max_num_segments": 1 },
          "set_priority": { "priority": 50 }
        }
      },
      "cold": {
        "min_age": "${ILM_COLD_AFTER}",
        "actions": {
          "set_priority": { "priority": 0 },
          "readonly":     {}
        }
      },
      "delete": {
        "min_age": "${ILM_DELETE_AFTER}",
        "actions": {
          "delete": { "delete_searchable_snapshot": true }
        }
      }
    }
  }
}
EOF
)

ILM_RESP=$(curl -sk \
  --cacert "${CERT_PATH}" \
  -u "elastic:${ELASTIC_PASSWORD}" \
  -X PUT \
  -H "Content-Type: application/json" \
  "${ES_URL}/_ilm/policy/${ILM_POLICY_NAME}" \
  -d "${ILM_POLICY}" || echo "{}")

if echo "${ILM_RESP}" | grep -q '"acknowledged":true'; then
  info "ILM policy '${ILM_POLICY_NAME}' applied ✓"
  info "  Rollover:  every ${ILM_ROLLOVER_MAX_AGE} or ${ILM_ROLLOVER_MAX_SHARD_SIZE}/shard"
  info "  Warm:      after ${ILM_WARM_AFTER} (shrink + forcemerge)"
  info "  Cold:      after ${ILM_COLD_AFTER} (read-only)"
  info "  Delete:    after ${ILM_DELETE_AFTER}"
else
  warn "ILM policy may not have applied. Response: ${ILM_RESP}"
fi

# ─── Default index template — compression + ILM + mapping limits ───────────────
section "Applying Default Index Template (Compression + Limits)"

INDEX_TEMPLATE=$(
cat <<EOF
{
  "index_patterns": ["logs-*", "metrics-*", "*-logs-*"],
  "priority": 1,
  "template": {
    "settings": {
      "codec":                          "best_compression",
      "number_of_shards":               "${ES_DEFAULT_SHARDS}",
      "number_of_replicas":             "${ES_DEFAULT_REPLICAS}",
      "refresh_interval":               "${ES_REFRESH_INTERVAL}",
      "index.lifecycle.name":           "${ILM_POLICY_NAME}",
      "index.lifecycle.rollover_alias": "logs",
      "mapping.total_fields.limit":     ${ES_MAPPING_TOTAL_FIELDS_LIMIT}
    },
    "mappings": {
      "_source": {
        "enabled": true
      },
      "dynamic":                        "${ES_DYNAMIC_MAPPING}"
    }
  }
}
EOF
)

TEMPL_RESP=$(curl -sk \
  --cacert "${CERT_PATH}" \
  -u "elastic:${ELASTIC_PASSWORD}" \
  -X PUT \
  -H "Content-Type: application/json" \
  "${ES_URL}/_index_template/elk-default-logs" \
  -d "${INDEX_TEMPLATE}" || echo "{}")

if echo "${TEMPL_RESP}" | grep -q '"acknowledged":true'; then
  info "Index template 'elk-default-logs' applied ✓"
  info "  Compression:     best_compression (zstd — ~60-70% smaller than default)"
  info "  Shards/Replicas: ${ES_DEFAULT_SHARDS} / ${ES_DEFAULT_REPLICAS}"
  info "  Refresh:         ${ES_REFRESH_INTERVAL} (batches writes, reduces overhead)"
  info "  Dynamic mapping: ${ES_DYNAMIC_MAPPING} (prevents field explosion)"
else
  warn "Index template may not have applied. Response: ${TEMPL_RESP}"
fi

# ─── Health Summary ───────────────────────────────────────────────────────────
section "🎉 ELK Stack is Ready!"

CLUSTER_HEALTH=$(curl -sk \
  --cacert "${CERT_PATH}" \
  -u "elastic:${ELASTIC_PASSWORD}" \
  "${ES_URL}/_cluster/health?pretty" | grep '"status"' | head -1 | tr -d ' ",')

echo -e "${BOLD}"
echo "  ┌──────────────────────────────────────────────────────────────"
echo "  │  Service          │  URL                                 │"
echo "  ├──────────────────────────────────────────────────────────────"
printf "  │  Elasticsearch    │  %-36s  │\n" "https://localhost:${ES_PORT}"
printf "  │  Kibana           │  %-36s  │\n" "https://localhost:${KIBANA_PORT}"
printf "  │  Fleet Server     │  %-36s  │\n" "https://localhost:${FLEET_SERVER_PORT}"
printf "  │  APM Server       │  %-36s  │\n" "https://localhost:${APM_SERVER_PORT}"
echo  "  ├──────────────────────────────────────────────────────────────"
printf "  │  Cluster status:  ${CLUSTER_HEALTH:?}  %-36s  │\n" ""
echo  "  └──────────────────────────────────────────────────────────┘"
echo -e "${RESET}"

info "Username: elastic"
info "Password: (see ELASTIC_PASSWORD in .env)"
echo ""
warn "TIP: To stop the stack:           ./setup.sh --down"
warn "TIP: To destroy all data:         ./setup.sh --clean"
warn "TIP: To view logs:                docker compose logs -f <service>"
