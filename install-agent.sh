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
#      --ca-cert     /path/to/ca.crt              # optional, for TLS verify
#
#  Where to get the values:
#    Fleet URL       : https://<ELK_SERVER_IP>:8220
#    Enrollment Token: Kibana → Fleet → Enrollment Tokens → Create token
#    CA cert         : Copy ca.crt from ELK server (config/certs/ca/ca.crt)
#                      to this remote server and pass the path here.
#
#  Supported OS: Ubuntu/Debian, RHEL/CentOS/Amazon Linux, macOS
# =============================================================================
set -euo pipefail

# ─── Defaults (override via flags) ───────────────────────────────────────────
FLEET_URL=""
ENROLLMENT_TOKEN=""
CA_CERT=""
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
Usage: sudo $0 --fleet-url <URL> --token <TOKEN> [--ca-cert <PATH>] [--version <VER>]

Required:
  --fleet-url   https://<ELK_SERVER_IP>:8220   Fleet Server public URL
  --token       <enrollment_token>              From Kibana → Fleet → Enrollment Tokens

Optional:
  --ca-cert     /path/to/ca.crt                CA cert copied from ELK server
  --version     8.14.3                          Elastic Stack version (default: ${STACK_VERSION})
  --help        Show this help

Example:
  sudo ./install-agent.sh \\
    --fleet-url https://10.0.0.5:8220 \\
    --token     AbCdEfGhIjKlMnOpQrStUvWxYz== \\
    --ca-cert   /tmp/ca.crt
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fleet-url) FLEET_URL="$2";         shift 2 ;;
    --token)     ENROLLMENT_TOKEN="$2";  shift 2 ;;
    --ca-cert)   CA_CERT="$2";           shift 2 ;;
    --version)   STACK_VERSION="$2";     shift 2 ;;
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
info "CA cert:    ${CA_CERT:-not provided}"
echo ""

# Why do we need a CA cert?
# ─────────────────────────────────────────────────────────────────────────────
# The ELK server uses a self-signed TLS certificate issued by its own CA.
# The Fleet Server's cert includes the ELK server's IP and/or domain as SANs,
# so remote agents CAN verify it — but only if they have the CA cert.
#
# Without the CA cert → you must use --insecure (TLS not verified — bad!)
# With the CA cert    → full TLS verification, no --insecure needed (correct)
#
# Get the CA cert from the ELK server:
#   scp user@elk-server:/path/to/elk/config/certs/ca/ca.crt /tmp/elk-ca.crt
# ─────────────────────────────────────────────────────────────────────────────

if [[ -n "${CA_CERT}" && -f "${CA_CERT}" ]]; then
  info "✓ CA cert found — enrolling with full TLS verification"
  elastic-agent install \
    --url="${FLEET_URL}" \
    --enrollment-token="${ENROLLMENT_TOKEN}" \
    --certificate-authorities="${CA_CERT}" \
    --non-interactive

elif [[ -n "${CA_CERT}" && ! -f "${CA_CERT}" ]]; then
  error "CA cert path given but file not found: ${CA_CERT}"
  error "Copy it from the ELK server first:"
  error "  scp user@elk-server:/path/to/elk/config/certs/ca/ca.crt /tmp/elk-ca.crt"
  exit 1

else
  echo ""
  warn "═══════════════════════════════════════════════════════════════"
  warn "  WARNING: No --ca-cert provided."
  warn "  Falling back to --insecure (TLS certificate NOT verified)."
  warn "  This is acceptable for testing, NOT for production."
  warn ""
  warn "  To fix: copy ca.crt from the ELK server and rerun:"
  warn "    scp user@elk-server:/path/elk/config/certs/ca/ca.crt /tmp/elk-ca.crt"
  warn "    sudo $0 --fleet-url ${FLEET_URL} --token <TOKEN> --ca-cert /tmp/elk-ca.crt"
  warn "═══════════════════════════════════════════════════════════════"
  echo ""
  elastic-agent install \
    --url="${FLEET_URL}" \
    --enrollment-token="${ENROLLMENT_TOKEN}" \
    --insecure \
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

warn "TIP: Keep your CA cert (ca.crt) safe — you need it for every new agent."
