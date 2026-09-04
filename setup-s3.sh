#!/bin/bash
# -----------------------------------------------------------------------------
# Script: setup-s3.sh
# Description: Automates the configuration of S3 Snapshot backups for Elasticsearch.
#              Injects credentials securely into the keystore, registers the S3
#              repository, and applies a 30-day daily Snapshot Lifecycle Policy (SLM).
# -----------------------------------------------------------------------------

set -e

# --- UI Formatting ------------------------------------------------------------
RESET="\e[0m"
BOLD="\e[1m"
GREEN="\e[32m"
BLUE="\e[34m"
YELLOW="\e[33m"
RED="\e[31m"

section() { echo -e "\n${BLUE}${BOLD}▶ $1${RESET}"; }
info()    { echo -e "  ${GREEN}✓${RESET} $1"; }
warn()    { echo -e "  ${YELLOW}!${RESET} $1"; }
error()   { echo -e "  ${RED}✗${RESET} $1"; }

# --- Load Environment Variables -----------------------------------------------
if [ ! -f .env ]; then
  error ".env file not found! Please run setup.sh first."
  exit 1
fi

# Load variables
set -a; source .env; set +a

if [ -z "${ELASTIC_PASSWORD}" ]; then
  error "ELASTIC_PASSWORD is not set in .env. Cannot authenticate with Elasticsearch."
  exit 1
fi

# --- Verify Elasticsearch is running ------------------------------------------
section "Verifying Cluster State"
if ! docker ps --format '{{.Names}}' | grep -q '^elasticsearch$'; then
  error "Elasticsearch container is not running!"
  exit 1
fi
info "Elasticsearch container is running."

# --- Prompt for AWS Credentials if missing ------------------------------------
section "AWS S3 Configuration"

if [ -z "${AWS_ACCESS_KEY_ID}" ]; then
  echo -e "${BOLD}Please enter your AWS Access Key ID:${RESET}"
  read -rp "  > " AWS_ACCESS_KEY_ID
fi

if [ -z "${AWS_SECRET_ACCESS_KEY}" ]; then
  echo -e "${BOLD}Please enter your AWS Secret Access Key:${RESET}"
  read -rs -p "  > " AWS_SECRET_ACCESS_KEY
  echo ""
fi

if [ -z "${S3_SNAPSHOT_BUCKET}" ]; then
  echo -e "${BOLD}Please enter the name of your S3 Bucket (e.g., my-elk-backups):${RESET}"
  read -rp "  > " S3_SNAPSHOT_BUCKET
fi

if [ -z "${S3_SNAPSHOT_REGION}" ]; then
  echo -e "${BOLD}Please enter the AWS Region (e.g., us-east-1):${RESET}"
  read -rp "  > " S3_SNAPSHOT_REGION
fi

if [ -z "${AWS_ACCESS_KEY_ID}" ] || [ -z "${AWS_SECRET_ACCESS_KEY}" ] || [ -z "${S3_SNAPSHOT_BUCKET}" ]; then
  error "Missing required AWS credentials or bucket name. Exiting."
  exit 1
fi

# --- Inject Keystore ----------------------------------------------------------
section "Injecting Secure Credentials"

info "Adding AWS Access Key to Elasticsearch keystore..."
echo "${AWS_ACCESS_KEY_ID}" | docker exec -i elasticsearch bin/elasticsearch-keystore add --stdin --force s3.client.default.access_key >/dev/null

info "Adding AWS Secret Key to Elasticsearch keystore..."
echo "${AWS_SECRET_ACCESS_KEY}" | docker exec -i elasticsearch bin/elasticsearch-keystore add --stdin --force s3.client.default.secret_key >/dev/null

info "Reloading secure settings..."
docker exec elasticsearch curl -s -k -X POST -u "elastic:${ELASTIC_PASSWORD}" "https://localhost:9200/_nodes/reload_secure_settings" >/dev/null

info "Credentials applied successfully."

# --- Register S3 Repository ---------------------------------------------------
section "Registering S3 Snapshot Repository"

REPO_RESPONSE=$(docker exec elasticsearch curl -s -k -X PUT -u "elastic:${ELASTIC_PASSWORD}" \
  -H "Content-Type: application/json" \
  "https://localhost:9200/_snapshot/s3_backup" \
  -d '{
    "type": "s3",
    "settings": {
      "bucket": "'"${S3_SNAPSHOT_BUCKET}"'",
      "region": "'"${S3_SNAPSHOT_REGION}"'"
    }
  }')

if echo "${REPO_RESPONSE}" | grep -q '"acknowledged":true'; then
  info "Repository 's3_backup' registered successfully in bucket '${S3_SNAPSHOT_BUCKET}'."
else
  error "Failed to register repository. Response: ${REPO_RESPONSE}"
  exit 1
fi

# --- Configure Snapshot Lifecycle Management (SLM) ----------------------------
section "Configuring Daily Backups (SLM)"

# Policy: Daily at 12:00 AM UTC, retain for 30 days.
SLM_RESPONSE=$(docker exec elasticsearch curl -s -k -X PUT -u "elastic:${ELASTIC_PASSWORD}" \
  -H "Content-Type: application/json" \
  "https://localhost:9200/_slm/policy/daily-snapshots" \
  -d '{
    "schedule": "0 0 0 * * ?",
    "name": "<daily-snap-{now/d}>",
    "repository": "s3_backup",
    "config": {
      "indices": ["*"],
      "ignore_unavailable": true,
      "include_global_state": true
    },
    "retention": {
      "expire_after": "30d",
      "min_count": 5,
      "max_count": 31
    }
  }')

if echo "${SLM_RESPONSE}" | grep -q '"acknowledged":true'; then
  info "Snapshot Lifecycle Policy 'daily-snapshots' created successfully."
  info "Backups will run automatically every day at midnight (UTC) and be kept for 30 days."
else
  error "Failed to create SLM policy. Response: ${SLM_RESPONSE}"
  exit 1
fi

echo -e "\n${GREEN}${BOLD}🎉 S3 Backup Configuration Complete!${RESET}"
echo -e "You can view your snapshots and policies in Kibana under:"
echo -e "${BOLD}Management → Stack Management → Snapshot and Restore${RESET}\n"
