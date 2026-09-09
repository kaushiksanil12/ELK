#!/usr/bin/env bash
# =============================================================================
#  prepare-server.sh — Prepare a Fresh Server for ELK Stack
#
#  Run this ONCE on a brand-new Linux host (Ubuntu, Debian, RHEL, Amazon Linux)
#  before starting the ELK stack.
#
#  What this script does:
#    1. Detects OS and system architecture.
#    2. Installs required system packages (curl, openssl, jq, unzip, etc.).
#    3. Installs Docker Engine & Docker Compose plugin (if not already installed).
#    4. Configures and persists kernel parameters (vm.max_map_count >= 262144).
#    5. Creates required directory structure and sets permissions.
#    6. Generates a production-ready .env with secure random keys (if missing).
#
#  Usage:
#    chmod +x prepare-server.sh
#    sudo ./prepare-server.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
ENV_EXAMPLE="${ROOT_DIR}/.env.example"

# ─── Colors & Helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
section() { echo -e "\n${BLUE}${BOLD}──── $* ────${RESET}\n"; }

echo -e "${CYAN}${BOLD}"
echo "  ███████╗██╗     ██╗  ██╗"
echo "  ██╔════╝██║     ██║ ██╔╝"
echo "  █████╗  ██║     █████╔╝ "
echo "  ██╔══╝  ██║     ██╔═██╗ "
echo "  ███████╗███████╗██║  ██╗"
echo "  ╚══════╝╚══════╝╚═╝  ╚═╝  Fresh Server Preparation"
echo -e "${RESET}"

# ─── Must be run with root / sudo ─────────────────────────────────────────────
if [[ "${EUID}" -ne 0 ]]; then
  error "This script requires root privileges. Please run with sudo:"
  echo "  sudo $0"
  exit 1
fi

# ─── 1. System Detection ──────────────────────────────────────────────────────
section "1. System Detection"

OS=""
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID_LIKE:-$ID}" in
    *debian*|*ubuntu*) OS="debian" ;;
    *rhel*|*centos*|*fedora*|*amzn*) OS="rhel" ;;
    *) OS="unknown" ;;
  esac
elif [[ "$(uname -s)" == "Darwin" ]]; then
  OS="darwin"
fi

info "Detected OS:       ${PRETTY_NAME:-$(uname -s)}"
info "Architecture:      $(uname -m)"
info "Total RAM:         $(free -h 2>/dev/null | awk '/^Mem:/ {print $2}' || echo 'N/A')"
info "Free Disk Space:   $(df -h "${SCRIPT_DIR}" | awk 'NR==2 {print $4}')"

# ─── 2. Install Required Base Utilities ────────────────────────────────────────
section "2. Installing Base Utilities"

case "${OS}" in
  debian)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg lsb-release openssl jq unzip
    info "Base packages installed ✓"
    ;;
  rhel)
    yum install -y curl openssl jq unzip ca-certificates
    info "Base packages installed ✓"
    ;;
  darwin)
    info "macOS detected — skipping apt/yum installation ✓"
    ;;
  *)
    warn "Unrecognised OS. Please ensure curl, openssl, jq, and unzip are installed manually."
    ;;
esac

# ─── 3. Install Docker & Docker Compose ────────────────────────────────────────
section "3. Checking Docker & Docker Compose"

install_docker() {
  info "Installing Docker Engine via official script..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
  info "Docker Engine installed and started ✓"
}

if ! command -v docker >/dev/null 2>&1; then
  if [[ "${OS}" == "debian" || "${OS}" == "rhel" ]]; then
    install_docker
  else
    error "Docker is not installed. Please install Docker manually."
    exit 1
  fi
else
  info "Docker is already installed: $(docker --version) ✓"
fi

# Check Docker Compose plugin (v2)
if ! docker compose version >/dev/null 2>&1; then
  info "Installing Docker Compose plugin..."
  if [[ "${OS}" == "debian" ]]; then
    apt-get update -y && apt-get install -y docker-compose-plugin
  elif [[ "${OS}" == "rhel" ]]; then
    yum install -y docker-compose-plugin
  fi
fi

if docker compose version >/dev/null 2>&1; then
  info "Docker Compose is ready: $(docker compose version) ✓"
else
  error "Docker Compose (plugin v2) could not be verified."
  exit 1
fi

# Add invoking user to docker group if SUDO_USER is set
if [[ -n "${SUDO_USER:-}" ]]; then
  usermod -aG docker "${SUDO_USER}" 2>/dev/null || true
  info "Added user '${SUDO_USER}' to 'docker' group ✓"
fi

# ─── 4. Configure Kernel Settings for Elasticsearch ───────────────────────────
section "4. Kernel Tuning (vm.max_map_count)"

if [[ "${OS}" != "darwin" ]]; then
  TARGET_MAP_COUNT=262144
  CURRENT_MAP_COUNT=$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)

  if [[ "${CURRENT_MAP_COUNT}" -lt "${TARGET_MAP_COUNT}" ]]; then
    info "Setting vm.max_map_count to ${TARGET_MAP_COUNT}..."
    sysctl -w vm.max_map_count=${TARGET_MAP_COUNT}
    echo "vm.max_map_count=${TARGET_MAP_COUNT}" > /etc/sysctl.d/99-elk.conf
    info "Persisted vm.max_map_count to /etc/sysctl.d/99-elk.conf ✓"
  else
    info "vm.max_map_count is already ${CURRENT_MAP_COUNT} (>= ${TARGET_MAP_COUNT}) ✓"
  fi

  # Ensure file descriptor limits are adequate
  if ! grep -q "elasticsearch" /etc/security/limits.conf 2>/dev/null; then
    cat >> /etc/security/limits.conf <<EOF
* soft nofile 65535
* hard nofile 65535
* soft memlock unlimited
* hard memlock unlimited
EOF
    info "File descriptor and memlock limits configured in /etc/security/limits.conf ✓"
  fi
else
  info "macOS detected — Docker Desktop manages memory maps automatically ✓"
fi

# ─── 5. Directory Structure & Permissions ─────────────────────────────────────
section "5. Preparing Directories & Permissions"

mkdir -p "${ROOT_DIR}/letsencrypt"
mkdir -p "${ROOT_DIR}/certbot-www"
mkdir -p "${ROOT_DIR}/nginx/templates"

# Ensure correct permissions
chmod 755 "${ROOT_DIR}"
chmod 755 "${ROOT_DIR}/scripts"

info "Directory structure verified ✓"

# ─── 6. Generate .env File if Missing ─────────────────────────────────────────
section "6. Configuration File (.env)"

generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32
  fi
}

if [[ ! -f "${ENV_FILE}" ]]; then
  if [[ -f "${ENV_EXAMPLE}" ]]; then
    info "Creating .env from .env.example with auto-generated secure credentials..."
    cp "${ENV_EXAMPLE}" "${ENV_FILE}"

    AUTO_ELASTIC_PW=$(generate_password)
    AUTO_KIBANA_PW=$(generate_password)
    AUTO_KIBANA_KEY=$(generate_password)$(generate_password) # 64 chars
    AUTO_REPORT_KEY=$(generate_password)$(generate_password)

    sed -i.bak "s/ELASTIC_PASSWORD=changeme_elastic/ELASTIC_PASSWORD=${AUTO_ELASTIC_PW}/" "${ENV_FILE}"
    sed -i.bak "s/KIBANA_SYSTEM_PASSWORD=changeme_kibana_system/KIBANA_SYSTEM_PASSWORD=${AUTO_KIBANA_PW}/" "${ENV_FILE}"
    sed -i.bak "s/KIBANA_ENCRYPTION_KEY=a-32-char-random-string-here!!!!/KIBANA_ENCRYPTION_KEY=${AUTO_KIBANA_KEY}/" "${ENV_FILE}"
    sed -i.bak "s/KIBANA_REPORTING_ENCRYPT_KEY=another-32-char-random-key!!!/KIBANA_REPORTING_ENCRYPT_KEY=${AUTO_REPORT_KEY}/" "${ENV_FILE}"
    rm -f "${ENV_FILE}.bak"

    info "Generated new .env with secure random passwords ✓"
    warn "Your auto-generated elastic password is: ${AUTO_ELASTIC_PW}"
    warn "(You can inspect and change it anytime in ${ENV_FILE})"
  else
    error ".env.example not found in ${SCRIPT_DIR}. Cannot create .env automatically."
    exit 1
  fi
else
  info ".env file already exists ✓"
fi

# Ensure non-root ownership so the invoking user can manage the stack without root
if [[ -n "${SUDO_USER:-}" ]]; then
  TARGET_GROUP=$(id -gn "${SUDO_USER}" 2>/dev/null || echo "${SUDO_USER}")
  chown -R "${SUDO_USER}:${TARGET_GROUP}" "${ROOT_DIR}"
  info "Transferred ownership of project directory to '${SUDO_USER}:${TARGET_GROUP}' (non-root access enabled) ✓"
fi

# Ensure .env has restricted permissions (read/write only by owner)
chmod 600 "${ENV_FILE}" 2>/dev/null || true

# ─── Summary ──────────────────────────────────────────────────────────────────
section "🎉 Server Preparation Complete!"

echo -e "${BOLD}"
echo "  Your server is fully prepared for the ELK Stack."
echo ""
echo "  Next steps to start the stack:"
echo "    1. Review settings:         nano .env"
echo "    2. Start the ELK stack:     ./scripts/02-start-elk.sh"
echo "    3. Start Fleet Server:      ./scripts/03-start-fleet.sh"
echo "    4. Configure S3 backup:     ./scripts/04-setup-s3-backup.sh"
echo ""
echo "  To update ILM retention or templates later without running 02-start-elk.sh:"
echo "    ./scripts/update-policies.sh"
echo -e "${RESET}"
