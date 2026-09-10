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

# ── Detect Target Non-Root User ───────────────────────────────────────────────
TARGET_USER=""
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  TARGET_USER="${SUDO_USER}"
else
  # Check standard cloud image users
  for u in ubuntu ec2-user debian centos admin; do
    if id "${u}" >/dev/null 2>&1; then
      TARGET_USER="${u}"
      break
    fi
  done
  # Fallback: check who owns the repo directory
  if [[ -z "${TARGET_USER}" ]]; then
    DIR_OWNER=$(stat -c '%U' "${ROOT_DIR}" 2>/dev/null || stat -f '%Su' "${ROOT_DIR}" 2>/dev/null || echo "")
    if [[ -n "${DIR_OWNER}" && "${DIR_OWNER}" != "root" ]]; then
      TARGET_USER="${DIR_OWNER}"
    fi
  fi
fi

# If on a pure root VPS with no regular user, create standard 'elk' user
if [[ -z "${TARGET_USER}" && "${OS}" != "darwin" ]]; then
  TARGET_USER="elk"
  if ! id "${TARGET_USER}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${TARGET_USER}"
    info "Created dedicated non-root user '${TARGET_USER}' ✓"
  fi
fi

info "Managing User:     ${TARGET_USER:-root}"

# ─── 2. Install Required Base Utilities ────────────────────────────────────────
section "2. Installing Base Utilities"

case "${OS}" in
  debian)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg lsb-release openssl jq unzip acl
    info "Base packages installed ✓"
    ;;
  rhel)
    yum install -y curl openssl jq unzip ca-certificates acl
    info "Base packages installed ✓"
    ;;
  darwin)
    info "macOS detected — skipping apt/yum installation ✓"
    ;;
  *)
    warn "Unrecognised OS. Please ensure curl, openssl, jq, and unzip are installed manually."
    ;;
esac

# ─── 3. Install Docker & Configure User/Group Permissions ─────────────────────
section "3. Checking Docker & Configuring User/Group Permissions"

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

if [[ "${OS}" != "darwin" ]]; then
  # Ensure docker daemon is started
  systemctl enable docker 2>/dev/null || true
  systemctl start docker 2>/dev/null || true

  # Ensure docker group exists
  if ! getent group docker >/dev/null 2>&1; then
    groupadd docker
    info "Created 'docker' group ✓"
  else
    info "'docker' group already exists ✓"
  fi

  # Add TARGET_USER to docker group for permanent future sessions
  if [[ -n "${TARGET_USER}" ]]; then
    usermod -aG docker "${TARGET_USER}"
    info "Added user '${TARGET_USER}' to 'docker' group ✓"
  fi

  # Configure systemd socket override so /var/run/docker.sock retains non-root access
  if systemctl list-unit-files docker.socket >/dev/null 2>&1; then
    mkdir -p /etc/systemd/system/docker.socket.d
    cat > /etc/systemd/system/docker.socket.d/override.conf <<'EOF'
[Socket]
SocketMode=0666
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart docker.socket 2>/dev/null || true
  fi

  # Ensure Docker socket permissions allow immediate access in active session without re-login
  if [[ -S /var/run/docker.sock ]]; then
    chown root:docker /var/run/docker.sock 2>/dev/null || true
    chmod 666 /var/run/docker.sock 2>/dev/null || true
    if command -v setfacl >/dev/null 2>&1 && [[ -n "${TARGET_USER}" ]]; then
      setfacl -m "u:${TARGET_USER}:rw" /var/run/docker.sock 2>/dev/null || true
    fi
    info "Configured Docker socket permissions ('docker ps' works immediately without sudo) ✓"
  fi

  # Verify non-root access
  if [[ -n "${TARGET_USER}" && "${TARGET_USER}" != "root" ]]; then
    if su -s /bin/bash "${TARGET_USER}" -c "docker ps" >/dev/null 2>&1; then
      info "Verified non-root access: '${TARGET_USER}' can run 'docker ps' without sudo ✓"
    fi
  fi
fi

# ─── 4. Configure Swap File (Emergency OOM Protection) ────────────────────────
section "4. Swap File & Memory Protection"

if [[ "${OS}" != "darwin" ]]; then
  CURRENT_SWAP_MB=$(free -m | awk '/^Swap:/ {print $2}')
  if [[ "${CURRENT_SWAP_MB:-0}" -eq 0 ]]; then
    SWAP_FILE="/swapfile"
    SWAP_SIZE_GB=4

    # If disk space is tight (< 15GB free), allocate 2GB swap
    FREE_DISK_MB=$(df -m / | awk 'NR==2 {print $4}')
    if [[ "${FREE_DISK_MB}" -lt 15360 ]]; then
      SWAP_SIZE_GB=2
    fi

    info "No swap partition detected. Allocating ${SWAP_SIZE_GB}GB swap file at ${SWAP_FILE}..."
    if command -v fallocate >/dev/null 2>&1; then
      fallocate -l "${SWAP_SIZE_GB}G" "${SWAP_FILE}" 2>/dev/null || dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=$((SWAP_SIZE_GB * 1024)) status=progress
    else
      dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=$((SWAP_SIZE_GB * 1024)) status=progress
    fi

    chmod 600 "${SWAP_FILE}"
    mkswap "${SWAP_FILE}" >/dev/null
    swapon "${SWAP_FILE}"

    # Persist in /etc/fstab if not already present
    if ! grep -q "${SWAP_FILE}" /etc/fstab; then
      echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
      info "Added ${SWAP_FILE} to /etc/fstab for persistence on reboot ✓"
    fi

    # Set vm.swappiness=1 (prevents swapping JVM memory unless RAM is completely exhausted)
    sysctl -w vm.swappiness=1 >/dev/null
    echo "vm.swappiness=1" > /etc/sysctl.d/99-swappiness.conf
    info "${SWAP_SIZE_GB}GB swap created and enabled with vm.swappiness=1 ✓"
  else
    info "Swap already configured: $(free -h | awk '/^Swap:/ {print $2}') ✓"
    sysctl -w vm.swappiness=1 >/dev/null 2>&1 || true
    echo "vm.swappiness=1" > /etc/sysctl.d/99-swappiness.conf 2>/dev/null || true
  fi
else
  info "macOS detected — swap is managed automatically by macOS ✓"
fi

# ─── 5. Configure Kernel Settings for Elasticsearch ───────────────────────────
section "5. Kernel Tuning (vm.max_map_count)"

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

# ─── 6. Directory Structure & Permissions ─────────────────────────────────────
section "6. Preparing Directories & Permissions"

mkdir -p "${ROOT_DIR}/letsencrypt"
mkdir -p "${ROOT_DIR}/certbot-www"
mkdir -p "${ROOT_DIR}/nginx/templates"

# Ensure correct permissions
chmod 755 "${ROOT_DIR}"
chmod 755 "${ROOT_DIR}/scripts"

info "Directory structure verified ✓"

# ─── 7. Generate .env File if Missing ─────────────────────────────────────────
section "7. Configuration File (.env)"

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
  if grep -q "ES_CIRCUIT_BREAKER_TOTAL_LIMIT=70%" "${ENV_FILE}" 2>/dev/null; then
    sed -i.bak "s/ES_CIRCUIT_BREAKER_TOTAL_LIMIT=70%/ES_CIRCUIT_BREAKER_TOTAL_LIMIT=95%/" "${ENV_FILE}"
    rm -f "${ENV_FILE}.bak"
    info "Updated ES_CIRCUIT_BREAKER_TOTAL_LIMIT to 95% in existing .env ✓"
  fi
fi

# Ensure non-root ownership so the invoking user can manage the stack without root
if [[ -n "${TARGET_USER}" ]]; then
  TARGET_GROUP=$(id -gn "${TARGET_USER}" 2>/dev/null || echo "${TARGET_USER}")
  chown -R "${TARGET_USER}:${TARGET_GROUP}" "${ROOT_DIR}"
  info "Transferred ownership of project directory to '${TARGET_USER}:${TARGET_GROUP}' (non-root access enabled) ✓"
fi

# Ensure .env has restricted permissions (read/write only by owner)
chmod 600 "${ENV_FILE}" 2>/dev/null || true

# ─── Summary ──────────────────────────────────────────────────────────────────
section "🎉 Server Preparation Complete!"

echo -e "${BOLD}"
echo "  Your server is fully prepared for the ELK Stack."
echo "  • Managing User:   ${TARGET_USER:-root} (added to 'docker' group)"
echo "  • Active Swap:     $(free -h 2>/dev/null | awk '/^Swap:/ {print $2}' || echo 'N/A') (vm.swappiness=1)"
echo ""
if [[ -n "${AUTO_ELASTIC_PW:-}" ]]; then
  echo "  ┌─────────────────────────────────────────────────────────────┐"
  echo "  │  🔐 Auto-Generated Credentials (saved in .env):             │"
  echo "  │                                                             │"
  printf "  │  Username:        elastic                                   │\n"
  printf "  │  Password:        %-42s│\n" "${AUTO_ELASTIC_PW}"
  printf "  │  Kibana Password: %-42s│\n" "${AUTO_KIBANA_PW}"
  echo "  │                                                             │"
  echo "  │  View/change anytime:  nano .env                            │"
  echo "  └─────────────────────────────────────────────────────────────┘"
  echo ""
fi
echo "  Next steps to start the stack:"
echo "    1. Verify Docker works:     docker ps  (works immediately without sudo!)"
echo "    2. Review/edit settings:    nano .env"
echo "    3. Start the ELK stack:     ./scripts/02-start-elk.sh"
echo "    4. Start Fleet Server:      ./scripts/03-start-fleet.sh"
echo "    5. Configure S3 backup:     ./scripts/04-setup-s3-backup.sh"
echo ""
echo "  To update ILM retention or templates later without running 02-start-elk.sh:"
echo "    ./scripts/update-policies.sh"
echo -e "${RESET}"
