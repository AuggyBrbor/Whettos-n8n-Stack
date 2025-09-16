#!/bin/bash

# This script restores the n8n instance from a selected backup using a hot-swap method.
# WARNING: This is a destructive operation and will restart your n8n pod.
# It should be run from the root directory of the toolkit.

set -e # Exit on any error

# --- Configuration ---
COMPOSE_FILE="./fedora/podman-compose.yml"
BACKUP_DIR="./backups"
ENV_FILE=".env"
DB_CONTAINER="n8n-postgres"
# The project name is used for volumes, pods, and compose operations.
PROJECT_NAME="n8n_stack"
N8N_DATA_VOLUME="${PROJECT_NAME}_n8n-data"
POD_NAME="pod_${PROJECT_NAME}"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Pre-flight Checks ---
echo "--- Running Pre-flight Checks ---"
if ! command -v podman &> /dev/null || ! command -v podman-compose &> /dev/null; then
    echo -e "${RED}Error: 'podman' or 'podman-compose' not found. Please install them.${NC}"
    exit 1
fi

if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A $BACKUP_DIR)" ]; then
    echo -e "${RED}Error: Backup directory '$BACKUP_DIR' not found or is empty.${NC}"
    exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: '$ENV_FILE' not found. Cannot proceed without database credentials.${NC}"
    exit 1
fi

# --- User Interaction ---
echo "Please select a backup to restore from:"
PS3="Enter the number of the backup: "
select backup_folder in $(ls -d $BACKUP_DIR/backup_*/ | xargs -n 1 basename); do
    if [ -n "$backup_folder" ]; then
        SELECTED_BACKUP_DIR="$BACKUP_DIR/$backup_folder"
        echo -e "${GREEN}You have selected: $backup_folder${NC}"
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

DB_BACKUP_FILE="$SELECTED_BACKUP_DIR/n8n_db.dump"
N8N_BACKUP_FILE="$SELECTED_BACKUP_DIR/n8n_data.tar.gz"

if [ ! -f "$DB_BACKUP_FILE" ] || [ ! -f "$N8N_BACKUP_FILE" ]; then
    echo -e "${RED}Error: Backup is incomplete. Missing database or data file in $SELECTED_BACKUP_DIR${NC}"
    exit 1
fi

# Confirmation Prompt
echo -e "\n${YELLOW}WARNING: This will completely destroy the current n8n instance, including all containers, volumes, and data. This action is irreversible.${NC}"
read -p "Are you sure you want to proceed with the restore? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Restore cancelled."
    exit 0
fi

# --- Restore Process ---
echo -e "\n--- Starting Restore Process ---"
echo "Step 1: Stopping application containers (PostgreSQL will remain running)..."
# We add '|| true' to prevent the script from exiting if a container is already stopped.
podman container stop n8n-main n8n-redis n8n-worker n8n-mcp ollama-service || true
echo "Application containers stopped."

echo "Step 2: Restoring n8n data volume..."
podman run --rm \
  --user root \
  -v "$N8N_DATA_VOLUME:/n8n-data:z" \
  -v "$PWD/$SELECTED_BACKUP_DIR:/backups:ro,z" \
  docker.io/alpine:latest \
  tar -xzpf "/backups/n8n_data.tar.gz" -C "/n8n-data"
echo "Data volume restored."

echo "Step 3: Restoring database..."
# Source the .env file to get credentials
set -a; source "$ENV_FILE"; set +a
# Pipe the backup file into 'podman exec' which runs pg_restore inside the container.
# Execute as the OS user 'postgres' and connect as the DB user 'n8n'.
cat "$DB_BACKUP_FILE" | podman exec -i --user postgres \
  "$DB_CONTAINER" \
  pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --exit-on-error
echo "Database restore complete."

echo "Step 4: Stopping and removing the pod to ensure a clean restart..."
# Use 'podman pod exists' to avoid errors if the pod is already gone.
if podman pod exists "$POD_NAME"; then
    podman pod stop "$POD_NAME"
fi
yes | podman pod prune > /dev/null
echo "Pod has been stopped and podman pruned."

echo "Step 5: Starting all services from compose file..."
# You can set N8N_WORKER_SCALE in your .env file or it will default to 2.
N8N_WORKER_SCALE=${N8N_WORKER_SCALE:-2}
podman-compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d --scale n8n-worker="$N8N_WORKER_SCALE"

echo -e "\n${GREEN}Restore successfully completed!${NC}"
echo "Your n8n instance is now running with the restored data."
echo -e "Access it here: ${GREEN}http://localhost:5678${NC}"
