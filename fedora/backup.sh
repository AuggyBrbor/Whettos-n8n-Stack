#!/bin/bash

# This script provides a graceful backup of the n8n pod.
# It stops the n8n services, runs temporary backup containers, and restarts them.
# It should be run from the root directory of the toolkit.

# set -eo pipefail

# --- Configuration ---
COMPOSE_FILE="./fedora/podman-compose.yml"
ENV_FILE=".env"
BACKUP_DIR="./backups"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Pre-flight Checks ---
echo "--- Running Pre-flight Checks ---"
if ! command -v podman &> /dev/null || ! command -v podman-compose &> /dev/null; then
    echo -e "${RED}Error: 'podman' or 'podman-compose' not found.${NC}"; exit 1;
fi
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: '$ENV_FILE' not found. Cannot proceed without credentials.${NC}"; exit 1;
fi
mkdir -p "$BACKUP_DIR"

# --- Dynamic Name Discovery ---
PROJECT_NAME="n8n_stack";

NETWORK_NAME="${PROJECT_NAME}_n8n-stack"
N8N_DATA_VOLUME="${PROJECT_NAME}_n8n-data"
echo -e "${GREEN}Discovered project '${PROJECT_NAME}', network '${NETWORK_NAME}', and volume '${N8N_DATA_VOLUME}'${NC}"

# --- Main Logic ---
echo -e "\n--- Starting Graceful Backup: $(date) ---"

# Source environment variables and validate them
set -a
source "$ENV_FILE"
set +a

# --- ADDED: Explicit checks for required backup variables ---
if [[ -z "$POSTGRES_USER" || -z "$POSTGRES_PASSWORD" || -z "$POSTGRES_DB" ]]; then
    echo -e "${RED}Error: Required database variables are not set in the .env file.${NC}"; exit 1;
fi
RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-7}

# 1. Dynamically find and gracefully stop all n8n services

podman-compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" stop n8n-main n8n-worker

# Use a trap to ensure services are restarted even if the script fails
function cleanup {
  echo -e "\n${YELLOW}--- Final Step: Restarting n8n services... ---${NC}"
  podman start $N8N_CONTAINERS > /dev/null
  echo -e "${GREEN}Backup process finished. Services are running.${NC}"
}
trap cleanup EXIT

# 2. Create timestamped backup directory
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
CURRENT_BACKUP_DIR="$BACKUP_DIR/backup_$TIMESTAMP"

echo "Creating backup directory: $CURRENT_BACKUP_DIR"
mkdir -p "$CURRENT_BACKUP_DIR"
echo "Created backup directory: $CURRENT_BACKUP_DIR"

# 3. Backup PostgreSQL Database
DB_BACKUP_FILE="$CURRENT_BACKUP_DIR/n8n_db_backup.sql.gz"
echo -e "\n${YELLOW}Step 2: Backing up PostgreSQL database...${NC}"
podman run --rm \
  --network "$NETWORK_NAME" \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  -v "$PWD/$CURRENT_BACKUP_DIR:/backups:z" \
  docker.io/postgres:16 \
  pg_dump -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" -F c -b -v | gzip > "$CURRENT_BACKUP_DIR/n8n_db_backup.sql.gz"
echo "Database backup complete."

# 4. Backup n8n Data Volume
echo -e "\n${YELLOW}Step 3: Backing up n8n data volume...${NC}"
podman run --rm \
  --user 1000:1000 \
  -v "$N8N_DATA_VOLUME:/n8n-data:ro,z" \
  docker.io/alpine:latest \
  tar -czf - -C "/n8n-data" . \
  > "$CURRENT_BACKUP_DIR/n8n_data_volume.tar.gz"
echo "Data volume backup complete."

# 5. Prune Old Backups
echo -e "\n${YELLOW}Step 4: Pruning backups older than $RETENTION_DAYS days...${NC}"
find "$BACKUP_DIR" -type d -name "backup_*" -mtime +"$RETENTION_DAYS" -exec echo "Removing old backup: {}" \; -exec rm -rf {} \;
echo "Pruning complete."

podman-compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" start n8n-main n8n-worker