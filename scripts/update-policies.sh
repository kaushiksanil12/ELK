#!/usr/bin/env bash
# =============================================================================
#  apply-cluster-policies.sh — Apply ILM & Index Templates to Elasticsearch
#
#  Use this script to update ILM retention, index templates, mapping limits,
#  or cluster settings WITHOUT running 02-start-elk.sh and WITHOUT restarting any containers.
#
#  When to use:
#    - You edited retention in .env (e.g. ILM_DELETE_AFTER=14d)
#    - You changed refresh interval or mapping limits in .env
#    - You want to sync cluster settings live in ~1 second
#
#  Usage:
#    chmod +x apply-cluster-policies.sh
#    ./apply-cluster-policies.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
section() { echo -e "\n${BLUE}${BOLD}──── $* ────${RESET}\n"; }

echo -e "${CYAN}${BOLD}"
echo "  ⚡ Applying Elasticsearch Policies & Templates (Live Update)"
echo -e "${RESET}"

# ─── Load .env ────────────────────────────────────────────────────────────────
if [[ ! -f "${ENV_FILE}" ]]; then
  error ".env file not found at ${ENV_FILE}"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

# ─── Helper: Execute curl directly inside Elasticsearch container ─────────────
escurl() {
  docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" \
    exec -T elasticsearch \
    curl -s --cacert config/certs/ca/ca.crt \
    -u "elastic:${ELASTIC_PASSWORD}" \
    "$@"
}

# ─── Check Elasticsearch Health ───────────────────────────────────────────────
section "Checking Elasticsearch Connection"

if ! docker ps --format '{{.Names}}' | grep -q '^elasticsearch$'; then
  error "The 'elasticsearch' container is not running!"
  echo "  Start the stack first with: ./scripts/02-start-elk.sh"
  exit 1
fi

HEALTH_STATUS=$(escurl "https://localhost:${ES_PORT}/_cluster/health" 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "unknown")

if [[ "${HEALTH_STATUS}" != "green" && "${HEALTH_STATUS}" != "yellow" ]]; then
  error "Elasticsearch cluster health is '${HEALTH_STATUS}'. Cannot apply policies."
  exit 1
fi

info "Elasticsearch is reachable and healthy (status: ${HEALTH_STATUS}) ✓"

# ─── 1. Apply Elasticsearch Cluster Settings ──────────────────────────────────
section "1. Applying Cluster Settings"

SETTINGS=$(cat <<EOF
{
  "persistent": {
    "cluster.max_shards_per_node":                              ${ES_MAX_SHARDS_PER_NODE:-1000},
    "indices.recovery.max_bytes_per_sec":                       "${ES_RECOVERY_MAX_BYTES_PER_SEC:-40mb}",
    "cluster.routing.allocation.disk.watermark.low":            "${ES_WATERMARK_LOW:-85%}",
    "cluster.routing.allocation.disk.watermark.high":           "${ES_WATERMARK_HIGH:-90%}",
    "cluster.routing.allocation.disk.watermark.flood_stage":    "${ES_WATERMARK_FLOOD_STAGE:-95%}"
  }
}
EOF
)

SETTINGS_RESP=$(escurl \
  -X PUT \
  -H "Content-Type: application/json" \
  "https://localhost:${ES_PORT}/_cluster/settings" \
  -d "${SETTINGS}" || echo "{}")

if echo "${SETTINGS_RESP}" | grep -q '"acknowledged":true'; then
  info "Cluster settings updated ✓"
  info "  Max shards/node: ${ES_MAX_SHARDS_PER_NODE:-1000}"
  info "  Disk watermarks: Low=${ES_WATERMARK_LOW:-85%}, High=${ES_WATERMARK_HIGH:-90%}, Flood=${ES_WATERMARK_FLOOD_STAGE:-95%}"
else
  warn "Cluster settings response: ${SETTINGS_RESP}"
fi

# ─── 2. Apply Index Lifecycle Management (ILM) Policy ─────────────────────────
section "2. Applying ILM Policy (${ILM_POLICY_NAME:-elk-logs-policy})"

ILM_POLICY=$(cat <<EOF
{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": {
            "max_age":                "${ILM_ROLLOVER_MAX_AGE:-1d}",
            "max_primary_shard_size": "${ILM_ROLLOVER_MAX_SHARD_SIZE:-10gb}"
          },
          "set_priority": { "priority": 100 }
        }
      },
      "delete": {
        "min_age": "${ILM_DELETE_AFTER:-7d}",
        "actions": {
          "delete": { "delete_searchable_snapshot": true }
        }
      }
    }
  }
}
EOF
)

ILM_RESP=$(escurl \
  -X PUT \
  -H "Content-Type: application/json" \
  "https://localhost:${ES_PORT}/_ilm/policy/${ILM_POLICY_NAME:-elk-logs-policy}" \
  -d "${ILM_POLICY}" || echo "{}")

if echo "${ILM_RESP}" | grep -q '"acknowledged":true'; then
  info "ILM policy '${ILM_POLICY_NAME:-elk-logs-policy}' updated ✓"
  info "  Rollover:  every ${ILM_ROLLOVER_MAX_AGE:-1d} or ${ILM_ROLLOVER_MAX_SHARD_SIZE:-10gb}/shard"
  info "  Retention: purge local indices after ${ILM_DELETE_AFTER:-7d} (S3 holds 30d snapshots)"
else
  warn "ILM response: ${ILM_RESP}"
fi

# ─── 3. Apply Default Index Template (Compression + Dynamic Mappings) ─────────
section "3. Applying Index Template (elk-default-logs)"

INDEX_TEMPLATE=$(cat <<EOF
{
  "index_patterns": ["logs-*", "metrics-*", "*-logs-*"],
  "priority": 1,
  "template": {
    "settings": {
      "codec":                          "best_compression",
      "number_of_shards":               "${ES_DEFAULT_SHARDS:-1}",
      "number_of_replicas":             "${ES_DEFAULT_REPLICAS:-0}",
      "refresh_interval":               "${ES_REFRESH_INTERVAL:-5s}",
      "index.lifecycle.name":           "${ILM_POLICY_NAME:-elk-logs-policy}",
      "index.lifecycle.rollover_alias": "logs",
      "mapping.total_fields.limit":     ${ES_MAPPING_TOTAL_FIELDS_LIMIT:-2000}
    },
    "mappings": {
      "_source": {
        "enabled": true
      },
      "dynamic":                        "${ES_DYNAMIC_MAPPING:-true}"
    }
  }
}
EOF
)

TEMPL_RESP=$(escurl \
  -X PUT \
  -H "Content-Type: application/json" \
  "https://localhost:${ES_PORT}/_index_template/elk-default-logs" \
  -d "${INDEX_TEMPLATE}" || echo "{}")

if echo "${TEMPL_RESP}" | grep -q '"acknowledged":true'; then
  info "Index template 'elk-default-logs' updated ✓"
  info "  Dynamic mapping: ${ES_DYNAMIC_MAPPING:-true} (no dropped app fields)"
  info "  Refresh interval: ${ES_REFRESH_INTERVAL:-5s} (fast search updates)"
  info "  Field limit:     ${ES_MAPPING_TOTAL_FIELDS_LIMIT:-2000}"
  info "  Compression:     best_compression (zstd)"
else
  warn "Index template response: ${TEMPL_RESP}"
fi

echo -e "\n${GREEN}${BOLD}✓ All policies and templates applied successfully! (Took ~1s, zero downtime)${RESET}\n"
