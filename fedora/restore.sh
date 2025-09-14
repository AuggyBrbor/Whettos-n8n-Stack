#!/bin/bash

# This script restores the n8n instance from a selected backup.
# WARNING: This is a destructive operation and will remove existing data.
# It should be run from the root directory of the toolkit.

# --- Configuration ---
COMPOSE_FILE="./fedora/podman-compose.yml"
BACKUP_DIR="./backups"
ENV_FILE=".env"
DB_CONTAINER="n8n-postgres"
DB_SERVICE_NAME="postgres"
# --- UPDATED: Volume name is now constructed dynamically from the project folder name ---
PROJECT_NAME=$(basename "$PWD")
N8N_DATA_VOLUME="${PROJECT_NAME}_n8n-data"
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

DB_BACKUP_FILE="$SELECTED_BACKUP_DIR/n8n_db_backup.sql.gz"
DATA_BACKUP_FILE="$SELECTED_BACKUP_DIR/n8n_data_volume.tar.gz"

if [ ! -f "$DB_BACKUP_FILE" ] || [ ! -f "$DATA_BACKUP_FILE" ]; then
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

# 1. Tear down existing environment
echo "Stopping and removing existing containers and volumes..."
podman-compose -f "$COMPOSE_FILE" down -v
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to tear down existing environment. Please check for errors.${NC}"
    exit 1
fi
echo "Environment cleared."

# 2. Restore n8n data volume
echo "Creating and restoring n8n data volume (${N8N_DATA_VOLUME})..."
podman volume create "$N8N_DATA_VOLUME" > /dev/null
gunzip < "$DATA_BACKUP_FILE" | podman volume import "$N8N_DATA_VOLUME" -
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to restore n8n data volume.${NC}"
    exit 1
fi
echo "Data volume restored."

# 3. Start database and restore data
echo "Starting PostgreSQL service..."
podman-compose -f "$COMPOSE_FILE" up -d "$DB_SERVICE_NAME"
echo "Waiting for database to initialize (20 seconds)..."
sleep 20

echo "Restoring database from backup..."
set -a; source "$ENV_FILE"; set +a
export PGPASSWORD=$POSTGRES_PASSWORD
gunzip < "$DB_BACKUP_FILE" | podman exec -i "$DB_CONTAINER" pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB"
unset PGPASSWORD
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to restore database.${NC}"
    exit 1
fi
echo "Database restore complete."

# 4. Start all other services
echo "Starting all remaining services..."
podman-compose -f "$COMPOSE_FILE" up -d
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to start all services.${NC}"
    exit 1
fi

echo -e "\n${GREEN}Restore successfully completed!${NC}"
echo "Your n8n instance is now running with the restored data."
echo -e "Access it here: ${GREEN}http://localhost:5678${NC}"
