#!/usr/bin/env bash
# =============================================================================
#  02-start-elk.sh — ELK Stack Startup & Controller (v9.x)
#  Usage:
#    chmod +x 02-start-elk.sh
#    ./02-start-elk.sh [--help] [--down] [--clean] [--policies-only]
#
#  Environment variables are read from the .env file in the same directory.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"

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

# Helper: run a curl command inside the elasticsearch container
escurl() {
  docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" \
    exec -T elasticsearch \
    curl -s --cacert config/certs/ca/ca.crt \
    -u "elastic:${ELASTIC_PASSWORD}" \
    "$@"
}

# ─── Help ─────────────────────────────────────────────────────────────────────
usage() {
  echo "Usage: $0 [--down] [--clean] [--help]"
  echo ""
  echo "  (no args)          Start / bring up the ELK stack & apply policies"
  echo "  --policies-only    Apply ILM and index templates only (runs update-policies.sh)"
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
    --policies-only)
      exec "${SCRIPT_DIR}/update-policies.sh"
      ;;
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
    if command -v sudo >/dev/null 2>&1; then
      info "Attempting: sudo sysctl -w vm.max_map_count=262144"
      sudo sysctl -w vm.max_map_count=262144 2>/dev/null || true
      echo "vm.max_map_count=262144" | sudo tee /etc/sysctl.d/99-elk.conf >/dev/null 2>&1 || true
    else
      warn "Please run './scripts/01-prepare-server.sh' with sudo once to set vm.max_map_count=262144."
    fi
  else
    info "vm.max_map_count=${CURRENT_MAP_COUNT} ✓"
  fi
else
  info "macOS detected — Docker Desktop handles vm.max_map_count automatically ✓"
fi

# ─── Create required directories ──────────────────────────────────────────────
section "Creating Directories"

mkdir -p "${ROOT_DIR}/letsencrypt"
mkdir -p "${ROOT_DIR}/certbot-www"
mkdir -p "${ROOT_DIR}/nginx/templates"

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

# ─── Select Nginx SSL Mode ────────────────────────────────────────────────────
section "Configuring Nginx"

NGINX_TMPL_DIR="${ROOT_DIR}/nginx/templates"

if [[ -n "${ELK_SERVER_DOMAIN}" ]] && \
   [[ "${ELK_SERVER_DOMAIN}" != "YOUR_ELK_SERVER_IP_OR_HOSTNAME" ]] && \
   [[ "${ELK_SERVER_DOMAIN}" != "YOUR_ELK_SERVER_IP" ]]; then
  info "Domain mode: using Let's Encrypt certs for ${ELK_SERVER_DOMAIN}"
  cp "${NGINX_TMPL_DIR}/kibana-domain.conf.tmpl" "${NGINX_TMPL_DIR}/default.conf.template"
else
  info "IP-only mode: using self-signed certs (ELK_SERVER_DOMAIN not set)"
  cp "${NGINX_TMPL_DIR}/kibana-ip.conf.tmpl" "${NGINX_TMPL_DIR}/default.conf.template"
fi

if [[ -n "${ELK_SERVER_DOMAIN}" ]] && [[ "${ELK_SERVER_DOMAIN}" != "YOUR_ELK_SERVER_IP_OR_HOSTNAME" ]] && [[ "${ELK_SERVER_DOMAIN}" != "YOUR_ELK_SERVER_IP" ]]; then
  if [[ ! -d "${ROOT_DIR}/letsencrypt/live/${ELK_SERVER_DOMAIN}" ]]; then
    section "Provisioning initial Let's Encrypt Certificate for ${ELK_SERVER_DOMAIN}"
    info "Temporarily binding to Port 80 to request certificate..."
    # Ensure Port 80 is not currently in use by an old nginx container
    docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" stop nginx 2>/dev/null || true
    
    docker run -it --rm --name certbot-init \
      -v "${ROOT_DIR}/letsencrypt:/etc/letsencrypt" \
      -v "${ROOT_DIR}/certbot-www:/var/www/certbot" \
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

MAX_RETRIES=60
ATTEMPT=0
until docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" \
      exec -T elasticsearch \
      curl -s --cacert config/certs/ca/ca.crt \
      -u "elastic:${ELASTIC_PASSWORD}" \
      "https://localhost:${ES_PORT}/_cluster/health" \
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
ATTEMPT=0
until docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" \
      exec -T kibana \
      curl -sk \
      -u "elastic:${ELASTIC_PASSWORD}" \
      "https://localhost:5601/api/status" \
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


# ─── Apply cluster settings, ILM policies & index templates ───────────────────
"${SCRIPT_DIR}/update-policies.sh"

# ─── Fix Fleet Output Fingerprint for Let's Encrypt ────────────────────────────
if [[ -n "${ELK_SERVER_DOMAIN}" ]]; then
  section "Configuring Fleet Outputs (Domain Mode)"
  info "Domain detected. Let's Encrypt will be used by Nginx."
  info "Clearing self-signed CA fingerprint from Fleet default output..."

  # Force Fleet setup initialization
  escurl -X POST -H "kbn-xsrf: true" \
    "https://localhost:${KIBANA_PORT}/api/fleet/setup" >/dev/null 2>&1 || true
    
  # Wait a few seconds for Kibana to initialize the fleet-default-output
  sleep 3

  # Update the default output to remove the auto-populated self-signed fingerprint
  OUTPUT_RESP=$(escurl \
    -X PUT \
    -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    "https://localhost:${KIBANA_PORT}/api/fleet/outputs/fleet-default-output" \
    -d '{
      "name": "default",
      "type": "elasticsearch",
      "is_default": true,
      "is_default_monitoring": true,
      "hosts": ["https://'"${ELK_SERVER_DOMAIN}"':'"${ES_PORT}"'"],
      "ca_trusted_fingerprint": ""
    }' || echo "{}")

  if echo "${OUTPUT_RESP}" | grep -q '"is_default":true'; then
    info "Fleet output fingerprint cleared successfully ✓"
  else
    warn "Failed to clear Fleet fingerprint. You may need to do it manually in Kibana UI."
  fi
fi

# ─── Health Summary ───────────────────────────────────────────────────────────
section "🎉 ELK Stack is Ready!"

CLUSTER_HEALTH=$(escurl \
  "https://localhost:${ES_PORT}/_cluster/health?pretty" | grep '"status"' | head -1 | tr -d ' ",')

echo -e "${BOLD}"
echo "  ┌──────────────────────────────────────────────────────────────"
echo "  │  Service          │  URL                                 │"
echo "  ├──────────────────────────────────────────────────────────────"
printf "  │  Kibana           │  %-36s  │\n" "https://${ELK_SERVER_DOMAIN:-localhost}"
printf "  │  Elasticsearch    │  %-36s  │\n" "https://${ELK_SERVER_DOMAIN:-localhost}:${ES_PORT}"
printf "  │  Fleet Server     │  %-36s  │\n" "https://${ELK_SERVER_DOMAIN:-localhost}:${FLEET_SERVER_PORT} (run ./scripts/03-start-fleet.sh)"
printf "  │  APM Server       │  %-36s  │\n" "https://${ELK_SERVER_DOMAIN:-localhost}:${APM_SERVER_PORT}"
echo  "  ├──────────────────────────────────────────────────────────────"
printf "  │  Cluster status:  ${CLUSTER_HEALTH:?}  %-36s  │\n" ""
echo  "  └──────────────────────────────────────────────────────────┘"
echo -e "${RESET}"

info "Username: elastic"
info "Password: (see ELASTIC_PASSWORD in .env)"
echo ""
warn "TIP: To stop the stack:           zsh --down"
warn "TIP: To destroy all data:         zsh --clean"
warn "TIP: To view logs:                docker compose logs -f <service>"
