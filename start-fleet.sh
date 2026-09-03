#!/bin/bash
set -e

# ANSI Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}──── Starting Fleet Server ────${NC}\n"

# Check if .env exists
if [ ! -f .env ]; then
  echo -e "${RED}[ERROR] .env file not found. Please run setup.sh first.${NC}"
  exit 1
fi

# Load variables from .env
set -a
source .env
set +a

if [[ -z "${FLEET_SERVER_ENROLLMENT_TOKEN}" ]]; then
  echo -e "${RED}[ERROR] FLEET_SERVER_ENROLLMENT_TOKEN is empty in your .env file!${NC}"
  echo -e "${YELLOW}Please generate the token manually in Kibana:${NC}"
  echo "  1. Go to Management -> Fleet -> Add Fleet Server"
  echo "  2. Name the policy 'Fleet Server Policy'"
  echo "  3. Generate the Enrollment Token and copy it"
  echo "  4. Paste it into your .env file as FLEET_SERVER_ENROLLMENT_TOKEN=\"your-token\""
  echo "  5. Run this script again."
  exit 1
fi

echo -e "${GREEN}[INFO] Found Fleet Enrollment Token in .env${NC}"
echo -e "${GREEN}[INFO] Starting Fleet Server container...${NC}"

sudo docker compose --profile fleet up -d fleet-server

echo -e "\n${GREEN}[INFO] Fleet Server started! It will now enroll itself in Kibana.${NC}"
echo -e "You can check its logs with: ${CYAN}sudo docker logs -f fleet-server${NC}\n"
