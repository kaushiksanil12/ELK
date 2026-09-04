#!/bin/bash
set -e

# ANSI Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
section() { echo -e "\n${CYAN}${BOLD}──── $* ────${RESET}\n"; }

section "Fleet Server Setup"

# ── Locate script directory ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Check .env ─────────────────────────────────────────────────────────────────
if [ ! -f "${SCRIPT_DIR}/.env" ]; then
  error ".env file not found. Please run setup.sh first."
  exit 1
fi

set -a
source "${SCRIPT_DIR}/.env"
set +a

# ── Check for enrollment token ─────────────────────────────────────────────────
if [[ -z "${FLEET_SERVER_ENROLLMENT_TOKEN}" ]]; then
  error "FLEET_SERVER_ENROLLMENT_TOKEN is not set in your .env file!"
  echo ""
  warn "Generate it in Kibana:"
  warn "  1. Go to  https://${ELK_SERVER_DOMAIN}  → Management → Fleet"
  warn "  2. Click 'Add Fleet Server'"
  warn "  3. Create a policy named 'Fleet Server Policy'"
  warn "  4. Copy the enrollment token shown on screen"
  warn "  5. Add it to your .env:  FLEET_SERVER_ENROLLMENT_TOKEN=\"<token>\""
  warn "  6. Re-run:  sudo bash ./start-fleet.sh"
  exit 1
fi

info "Found FLEET_SERVER_ENROLLMENT_TOKEN ✓"

# ── Stop any existing fleet-server container ───────────────────────────────────
if docker ps -a --format '{{.Names}}' | grep -q '^fleet-server$'; then
  info "Removing existing fleet-server container..."
  docker rm -f fleet-server >/dev/null 2>&1
fi

# ── Start Fleet Server ─────────────────────────────────────────────────────────
section "Starting Fleet Server Container"

CERTS_VOL=$(docker volume ls --format '{{.Name}}' | grep 'certs' | head -1)
FLEET_VOL=$(docker volume ls --format '{{.Name}}' | grep 'fleetdata\|fleet' | head -1)
NETWORK=$(docker network ls --format '{{.Name}}' | grep 'elk\|default' | head -1)

info "Using network:     ${NETWORK}"
info "Using certs vol:   ${CERTS_VOL}"
info "Using fleet vol:   ${FLEET_VOL}"
info "Stack version:     ${STACK_VERSION}"

docker run -d \
  --name fleet-server \
  --hostname fleet-server \
  --network "${NETWORK}" \
  --restart unless-stopped \
  --user root \
  --memory "${FLEET_MEM_LIMIT:-512m}" \
  --add-host "${ELK_SERVER_DOMAIN:-localhost}:host-gateway" \
  -v "${CERTS_VOL}:/certs" \
  -v "${FLEET_VOL}:/usr/share/elastic-agent/state" \
  -e STATE_PATH=/usr/share/elastic-agent/state \
  -e FLEET_SERVER_ENABLE=true \
  -e FLEET_URL="https://fleet-server:${FLEET_SERVER_PORT:-8220}" \
  -e FLEET_SERVER_ELASTICSEARCH_HOST="https://elasticsearch:${ES_PORT:-9200}" \
  -e FLEET_SERVER_ELASTICSEARCH_CA=/certs/ca/ca.crt \
  -e FLEET_SERVER_CERT=/certs/fleet-server/fleet-server.crt \
  -e FLEET_SERVER_CERT_KEY=/certs/fleet-server/fleet-server.key \
  -e FLEET_SERVER_PORT="${FLEET_SERVER_PORT:-8220}" \
  -e FLEET_SERVER_HOST="${FLEET_SERVER_HOST:-0.0.0.0}" \
  -e FLEET_SERVER_POLICY_ID="${FLEET_SERVER_POLICY:-fleet-server-policy}" \
  -e KIBANA_HOST="https://kibana:${KIBANA_PORT:-5601}" \
  -e KIBANA_CA=/certs/ca/ca.crt \
  -e KIBANA_USERNAME=elastic \
  -e KIBANA_PASSWORD="${ELASTIC_PASSWORD}" \
  -e ELASTICSEARCH_USERNAME=elastic \
  -e ELASTICSEARCH_PASSWORD="${ELASTIC_PASSWORD}" \
  -e FLEET_SERVER_SERVICE_TOKEN="${FLEET_SERVER_ENROLLMENT_TOKEN}" \
  "docker.elastic.co/elastic-agent/elastic-agent:${STACK_VERSION}"

echo ""
info "Fleet Server container started! ✓"
info "Checking enrollment status (this may take ~30 seconds)..."
echo ""

# ── Wait for Fleet Server to become healthy ────────────────────────────────────
ATTEMPT=0
until docker exec fleet-server \
      curl -sk "https://localhost:${FLEET_SERVER_PORT:-8220}/api/status" \
      | grep -q "HEALTHY" 2>/dev/null; do
  ATTEMPT=$((ATTEMPT + 1))
  if [[ ${ATTEMPT} -ge 24 ]]; then
    warn "Fleet Server has not reported HEALTHY within 2 minutes."
    warn "Check logs: sudo docker logs fleet-server --tail 50"
    break
  fi
  echo -ne "\r  Waiting... ${ATTEMPT}/24"
  sleep 5
done
echo ""

if docker exec fleet-server \
   curl -sk "https://localhost:${FLEET_SERVER_PORT:-8220}/api/status" \
   | grep -q "HEALTHY" 2>/dev/null; then
  info "Fleet Server is HEALTHY ✓"
  info "Fleet Server URL: https://${ELK_SERVER_DOMAIN}:${FLEET_SERVER_PORT:-8220}"
else
  warn "Fleet Server may still be starting up."
  warn "Monitor with: sudo docker logs -f fleet-server"
fi
