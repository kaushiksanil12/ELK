#!/usr/bin/env bash
# =============================================================================
#  install-agent.sh — Install & Enroll Elastic Agent on a REMOTE server
#
#  Run this script ON THE SERVER YOU WANT TO MONITOR (not the ELK server).
#
#  Usage:
#    chmod +x install-agent.sh
#    sudo ./install-agent.sh \
#      --fleet-url   https://<ELK_SERVER_IP>:8220 \
#      --token       <ENROLLMENT_TOKEN> \
#      --insecure                                 # optional, for IP-only self-signed certs
#
#  Where to get the values:
#    Fleet URL       : https://<ELK_SERVER_IP>:8220
#    Enrollment Token: Kibana → Fleet → Enrollment Tokens → Create token
#
#  Supported OS: Ubuntu/Debian, RHEL/CentOS/Amazon Linux, macOS
# =============================================================================
set -euo pipefail

# ─── Defaults (override via flags) ───────────────────────────────────────────
FLEET_URL=""
ENROLLMENT_TOKEN=""
INSECURE_FLAG=""
STACK_VERSION="9.5.0"    # Must match the ELK server version
INSTALL_DIR="/opt/elastic-agent"

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
section() { echo -e "\n${BLUE}${BOLD}──── $* ────${RESET}\n"; }

# ─── Parse arguments ──────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: sudo $0 --fleet-url <URL> --token <TOKEN> [--version <VER>]

Required:
  --fleet-url   https://<ELK_SERVER_IP>:8220   Fleet Server public URL
  --token       <enrollment_token>              From Kibana → Fleet → Enrollment Tokens

Optional:
  --version     8.14.3                          Elastic Stack version (default: ${STACK_VERSION})
  --insecure                                    Skip TLS verification (required if using IP instead of domain)
  --help        Show this help

Example:
  sudo ./install-agent.sh \\
    --fleet-url https://10.0.0.5:8220 \\
    --token     AbCdEfGhIjKlMnOpQrStUvWxYz==
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fleet-url) FLEET_URL="$2";         shift 2 ;;
    --token)     ENROLLMENT_TOKEN="$2";  shift 2 ;;
    --version)   STACK_VERSION="$2";     shift 2 ;;
    --insecure)  INSECURE_FLAG="--insecure"; shift 1 ;;
    --help)      usage ;;
    *) error "Unknown argument: $1"; usage ;;
  esac
done

# ─── Validate required args ───────────────────────────────────────────────────
[[ -z "${FLEET_URL}"         ]] && { error "--fleet-url is required"; usage; }
[[ -z "${ENROLLMENT_TOKEN}"  ]] && { error "--token is required";     usage; }

# ─── Must run as root ─────────────────────────────────────────────────────────
if [[ "${EUID}" -ne 0 ]]; then
  error "This script must be run as root (use sudo)."
  exit 1
fi

section "System Detection"

OS=""
ARCH=$(uname -m)
case "${ARCH}" in
  x86_64)  ARCH_SUFFIX="x86_64" ;;
  aarch64|arm64) ARCH_SUFFIX="arm64" ;;
  *) error "Unsupported architecture: ${ARCH}"; exit 1 ;;
esac

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID_LIKE:-$ID}" in
    *debian*|*ubuntu*) OS="deb"  ;;
    *rhel*|*centos*|*fedora*|*amzn*) OS="rpm" ;;
    *) OS="tar" ;;
  esac
elif [[ "$(uname -s)" == "Darwin" ]]; then
  OS="darwin"
else
  OS="tar"
fi

info "OS type:      ${OS}"
info "Architecture: ${ARCH_SUFFIX}"
info "Stack version: ${STACK_VERSION}"

# ─── Download Elastic Agent ───────────────────────────────────────────────────
section "Downloading Elastic Agent ${STACK_VERSION}"

BASE_URL="https://artifacts.elastic.co/downloads/beats/elastic-agent"

case "${OS}" in
  deb)
    PKG="elastic-agent-${STACK_VERSION}-amd64.deb"
    [[ "${ARCH_SUFFIX}" == "arm64" ]] && PKG="elastic-agent-${STACK_VERSION}-arm64.deb"
    DOWNLOAD_URL="${BASE_URL}/${PKG}"
    DOWNLOAD_PATH="/tmp/${PKG}"
    ;;
  rpm)
    PKG="elastic-agent-${STACK_VERSION}-x86_64.rpm"
    [[ "${ARCH_SUFFIX}" == "arm64" ]] && PKG="elastic-agent-${STACK_VERSION}-aarch64.rpm"
    DOWNLOAD_URL="${BASE_URL}/${PKG}"
    DOWNLOAD_PATH="/tmp/${PKG}"
    ;;
  darwin)
    PKG="elastic-agent-${STACK_VERSION}-darwin-x86_64.tar.gz"
    [[ "${ARCH_SUFFIX}" == "arm64" ]] && PKG="elastic-agent-${STACK_VERSION}-darwin-aarch64.tar.gz"
    DOWNLOAD_URL="${BASE_URL}/${PKG}"
    DOWNLOAD_PATH="/tmp/${PKG}"
    ;;
  tar)
    PKG="elastic-agent-${STACK_VERSION}-linux-${ARCH_SUFFIX}.tar.gz"
    DOWNLOAD_URL="${BASE_URL}/${PKG}"
    DOWNLOAD_PATH="/tmp/${PKG}"
    ;;
esac

info "Downloading: ${DOWNLOAD_URL}"
curl -fL --progress-bar -o "${DOWNLOAD_PATH}" "${DOWNLOAD_URL}"
info "Download complete ✓"

# ─── Install ──────────────────────────────────────────────────────────────────
section "Installing Elastic Agent"

case "${OS}" in
  deb)
    dpkg -i "${DOWNLOAD_PATH}"
    ;;
  rpm)
    rpm -ivh "${DOWNLOAD_PATH}"
    ;;
  darwin|tar)
    mkdir -p "${INSTALL_DIR}"
    tar -xzf "${DOWNLOAD_PATH}" -C "${INSTALL_DIR}" --strip-components=1
    export PATH="${INSTALL_DIR}:${PATH}"
    ;;
esac

rm -f "${DOWNLOAD_PATH}"
info "Elastic Agent installed ✓"

# ─── Enroll with Fleet Server ─────────────────────────────────────────────────
section "Enrolling with Fleet Server"
info "Fleet URL:  ${FLEET_URL}"
echo ""

if [[ "${OS}" == "deb" || "${OS}" == "rpm" ]]; then
  # For system packages, the agent is already installed. We just need to enroll it.
  # We might need to stop it first if it started automatically
  systemctl stop elastic-agent 2>/dev/null || true
  
  elastic-agent enroll \
    --url="${FLEET_URL}" \
    --enrollment-token="${ENROLLMENT_TOKEN}" \
    ${INSECURE_FLAG} \
    --force
else
  # For tarball/macOS, 'install' copies files to the permanent system path and enrolls
  elastic-agent install \
    --url="${FLEET_URL}" \
    --enrollment-token="${ENROLLMENT_TOKEN}" \
    ${INSECURE_FLAG} \
    --non-interactive
fi

# ─── Enable and start service ──────────────────────────────────────────────────
section "Starting Elastic Agent Service"

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable elastic-agent
  systemctl start  elastic-agent
  sleep 3
  systemctl status elastic-agent --no-pager || true
  info "Elastic Agent service started ✓"
elif [[ "${OS}" == "darwin" ]]; then
  "${INSTALL_DIR}/elastic-agent" run &
  info "Elastic Agent started (background) ✓"
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
section "✅ Elastic Agent Enrolled Successfully"

echo -e "${BOLD}"
echo "  This server is now monitored by Elastic."
echo ""
echo "  ➜  Check agent status in Kibana:"
echo "     Kibana → Management → Fleet → Agents"
echo ""
echo "  ➜  To check locally:"
echo "     elastic-agent status"
echo ""
echo "  ➜  To unenroll / uninstall:"
echo "     sudo elastic-agent uninstall"
echo -e "${RESET}"

warn "TIP: If you enrolled using an IP instead of a domain, ensure you passed --insecure."
