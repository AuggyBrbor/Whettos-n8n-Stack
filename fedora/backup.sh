#!/bin/bash

# This script provides a graceful backup of the n8n pod.
# It stops the n8n services, runs temporary backup containers, and restarts them.
# It should be run from the root directory of the toolkit.

set -eo pipefail

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
if ! command -v podman &> /dev/null; then
    echo -e "${RED}Error: 'podman' not found.${NC}"; exit 1;
fi
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: '$ENV_FILE' not found. Cannot proceed without credentials.${NC}"; exit 1;
fi
mkdir -p "$BACKUP_DIR"

# --- Dynamic Name Discovery ---
# Discover names based on the current project directory name.
PROJECT_NAME=$(basename "$PWD")
NETWORK_NAME=$(podman network ls --format "{{.Name}}" | grep "${PROJECT_NAME}_n8n-stack" | head -n 1)
N8N_DATA_VOLUME=$(podman volume ls --format "{{.Name}}" | grep "${PROJECT_NAME}_n8n-data" | head -n 1)

if [ -z "$NETWORK_NAME" ] || [ -z "$N8N_DATA_VOLUME" ]; then
    echo -e "${RED}Error: Could not find the podman network or volume for project '${PROJECT_NAME}'. Is the pod running?${NC}"
    exit 1
fi
echo -e "${GREEN}Discovered network '${NETWORK_NAME}' and volume '${N8N_DATA_VOLUME}'${NC}"

# --- Main Logic ---
echo -e "\n--- Starting Graceful Backup: $(date) ---"

# Source environment variables for credentials
set -a
source "$ENV_FILE"
set +a

if [[ -z "$POSTGRES_USER" ]]; then
    echo -e "${RED}Error: POSTGRES_USER is not set in the .env file. Please update it.${NC}"
    exit 1
fi

RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-7}

# 1. Gracefully stop n8n services
echo -e "\n${YELLOW}Step 1: Gracefully stopping n8n services...${NC}"
podman-compose -f "$COMPOSE_FILE" stop n8n-main n8n-worker

# Use a trap to ensure services are restarted even if the script fails
function cleanup {
  echo -e "\n${YELLOW}--- Final Step: Restarting n8n services... ---${NC}"
  podman-compose -f "$COMPOSE_FILE" start n8n-main n8n-worker
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
  -v "$PWD/$CURRENT_BACKUP_DIR:/backups:z" \
  docker.io/alpine:latest \
  tar -czf "/backups/n8n_data_volume.tar.gz" -C "/n8n-data" .
echo "Data volume backup complete."

# 5. Prune Old Backups
echo -e "\n${YELLOW}Step 4: Pruning backups older than $RETENTION_DAYS days...${NC}"
find "$BACKUP_DIR" -type d -name "backup_*" -mtime +"$RETENTION_DAYS" -exec echo "Removing old backup: {}" \; -exec rm -rf {} \;
echo "Pruning complete."