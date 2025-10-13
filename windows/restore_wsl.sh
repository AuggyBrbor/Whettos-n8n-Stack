#!/bin/bash

# This script restores the n8n instance from a selected backup using a hot-swap method.
# It now also restores all databases for the independent 'clientData' PostgreSQL container.
# This version is designed to be run from the 'windows' subdirectory via a wrapper.
# WARNING: This is a destructive operation and will restart your n8n pod.

set -e # Exit on any error

# --- Configuration (Dynamic Pathing) ---
# Resolve the script's actual location (e.g., /mnt/c/project/windows)
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
# PROJECT_ROOT is two directories up (e.g., /mnt/c/project)
PROJECT_ROOT=$(dirname $(dirname "$SCRIPT_DIR"))

# Set paths using the calculated PROJECT_ROOT
COMPOSE_FILE="${PROJECT_ROOT}/windows/podman-compose.yml"
BACKUP_DIR="${PROJECT_ROOT}/backups"
ENV_FILE="${PROJECT_ROOT}/.env"

# The project name is used for volumes, pods, and compose operations.
PROJECT_NAME="n8n_stack"
N8N_DATA_VOLUME_NAME="${PROJECT_NAME}_n8n-data"
N8N_PG_VOLUME_NAME="${PROJECT_NAME}_n8n-postgres-data"
N8N_REDIS_VOLUME_NAME="${PROJECT_NAME}_n8n-redis-data"
OLLAMA_VOLUME_NAME="${PROJECT_NAME}_ollama-data"
N8N_DATA_VOLUME="${PROJECT_NAME}_n8n-data"
POD_NAME="pod_${PROJECT_NAME}"

# Client DB variables from the attached restore.sh
POSTGRES_HOST_CD="clientData" # Container Name for Client DB
POSTGRES_USER_CD="admin"     # User for Client DB

# Variables for n8n DB (read from .env)
POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-n8n}"
POSTGRES_USER="${POSTGRES_USER:-n8n}"
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

if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR")" ]; then
    echo -e "${RED}Error: Backup directory '$BACKUP_DIR' not found or is empty.${NC}"
    exit 1
fi

if [ -f "$ENV_FILE" ]; then
    set -a
    # Source environment variables using the absolute path
    source "$ENV_FILE"
    set +a
else
    echo "❌ Error: .env file not found at $ENV_FILE"
    exit 1
fi

# --- User Interaction ---
echo "Please select a backup to restore from:"
PS3="Enter the number of the backup: "
# Use the absolute BACKUP_DIR path
select backup_folder in $(ls -d "$BACKUP_DIR"/backup_*/ | xargs -n 1 basename); do
    if [ -n "$backup_folder" ]; then
        SELECTED_BACKUP_DIR="$BACKUP_DIR/$backup_folder"
        echo -e "${GREEN}You have selected: $backup_folder${NC}"
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

N8N_DB_BACKUP_FILE="$SELECTED_BACKUP_DIR/n8n_database.sql.gz"
N8N_BACKUP_FILE="$SELECTED_BACKUP_DIR/n8n_files.tar.gz"
CLIENT_DB_BACKUP_DIR="$SELECTED_BACKUP_DIR/client_databases"

echo "Checking for required files in $backup_folder..."
if [ ! -f "$N8N_DB_BACKUP_FILE" ] || [ ! -f "$N8N_BACKUP_FILE" ]; then
    echo -e "${RED}Error: n8n backup is incomplete. Missing database or data file in $SELECTED_BACKUP_DIR${NC}"
    exit 1
fi
if [ ! -d "$CLIENT_DB_BACKUP_DIR" ]; then
    echo -e "${YELLOW}Warning: Client database backup directory '$CLIENT_DB_BACKUP_DIR' not found. Skipping client DB restore.${NC}"
fi


# Confirmation Prompt
echo -e "\n${YELLOW}WARNING: This will stop your n8n services, overwrite the current data, and restart the entire stack. This action is irreversible.${NC}"
read -p "Are you sure you want to proceed with the restore? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy1]$ ]]; then
    echo "Restore cancelled."
    exit 0
fi

# --- Restore Process ---
echo -e "\n--- Starting Restore Process ---"
# --- Step 1: Stop stack and destroy old volumes ---
echo
echo "🛑 Stopping n8n stack and removing existing volumes..."
# Change directory to the PROJECT_ROOT for volume/pod commands to work reliably
cd "${PROJECT_ROOT}"
# The simplest and safest way to ensure a clean state is to remove the Pod and related volumes.
podman pod stop "pod_$PROJECT_NAME" --ignore
podman pod rm "pod_$PROJECT_NAME" --force || true;
podman volume ls --format "{{.Name}}" | grep -E "${PROJECT_NAME}_" | xargs --no-run-if-empty podman volume rm -f
echo "✅ Stack stopped and volumes removed."

# --- Step 2: Restore n8n Data Volume ---
echo "Restoring n8n data to new volume '${N8N_DATA_VOLUME_NAME}'..."
podman volume create "${N8N_DATA_VOLUME_NAME}"

# Use a helper container to unpack the archive into the newly created volume
# NOTE: File paths must be absolute, which they are now.
podman run --rm \
    -v "${N8N_DATA_VOLUME_NAME}:/volume-data:z" \
    -v "${N8N_BACKUP_FILE}:/backup/archive.tar.gz:ro,z" \
    docker.io/alpine \
    tar -xzpf /backup/archive.tar.gz -C /volume-data
    
echo "✅ n8n data volume restore complete."

# --- Step 3: Restore n8n Database ---
echo "Step 3: Restoring n8n database..."
echo "Starting PostgreSQL service to receive data..."
# Use absolute COMPOSE_FILE path
podman-compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d "${POSTGRES_HOST}"

echo "Waiting for n8n PostgreSQL to be healthy..."
until podman inspect --format "{{.State.Health.Status}}" "n8n-${POSTGRES_HOST}" 2>/dev/null | grep -q "healthy"; do
    printf "."
    sleep 2
done
echo
echo "✅ n8n PostgreSQL is healthy."

echo "Importing n8n database from '${N8N_DB_BACKUP_FILE}'..."
# Pipe the backup file (absolute path) into 'podman exec'
gunzip < "$N8N_DB_BACKUP_FILE" | podman exec -i --user postgres \
  "n8n-${POSTGRES_HOST}" \
  pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --exit-on-error
echo "✅ n8n Database import complete."

# --- Step 3b: Restore Independent Client Databases (NEW) ---
if [ -d "$CLIENT_DB_BACKUP_DIR" ]; then
    echo -e "\nStep 3b: Restoring databases for independent container: ${POSTGRES_HOST_CD}..."

    # Check and wait for the client container to be running and healthy
    if ! podman container exists "$POSTGRES_HOST_CD" || ! podman inspect --format='{{.State.Running}}' "$POSTGRES_HOST_CD" | grep -q "true"; then
        echo "  -> ${RED}Error: Client DB container '$POSTGRES_HOST_CD' is not running. Skipping client DB restore.${NC}"
    else
        echo "  -> ${POSTGRES_HOST_CD} is running. Proceeding with restore."

        # Get the list of backup files (databases) from the client backup directory
        CLIENT_DB_FILES=$(find "$CLIENT_DB_BACKUP_DIR" -maxdepth 1 -type f -name "*.sql.gz" -printf "%f\n")

        if [ -z "$CLIENT_DB_FILES" ]; then
            echo "  -> ${YELLOW}Warning: No database dump files found in $CLIENT_DB_BACKUP_DIR. Skipping.${NC}"
        else
            for DB_FILE in $CLIENT_DB_FILES; do
                DB_NAME=$(basename "$DB_FILE" .sql.gz)
                DB_PATH="$CLIENT_DB_BACKUP_DIR/$DB_FILE"
                echo "  -> Restoring database: ${DB_NAME}"
                
                # Drop and recreate the database to ensure a clean restore target
                podman exec -i --user postgres "$POSTGRES_HOST_CD" psql -U postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\";"
                podman exec -i --user postgres "$POSTGRES_HOST_CD" psql -U postgres -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$POSTGRES_USER_CD\";"

                # Pipe the backup file into 'pg_restore'
                gunzip < "$DB_PATH" | podman exec -i --user postgres \
                    "$POSTGRES_HOST_CD" \
                    pg_restore -U "$POSTGRES_USER_CD" -d "$DB_NAME" --clean --if-exists --exit-on-error

                if [ $? -eq 0 ]; then
                    echo "    -> ${GREEN}Success: Database ${DB_NAME} restored.${NC}"
                else
                    echo "    -> ${RED}ERROR: Failed to restore database ${DB_NAME}.${NC}"
                fi
            done
        fi
    fi
    echo "✅ Independent database restore process finished."
fi

# --- Step 4: Restart the Full Stack ---
echo
echo "🚀 Starting the full n8n stack..."
# You can set N8N_WORKER_SCALE in your .env file or it will default to 2.
N8N_WORKER_SCALE=${N8N_WORKER_SCALE:-2}
podman-compose -p $PROJECT_NAME -f $COMPOSE_FILE up -d --scale n8n-worker=$N8N_WORKER_SCALE

echo -e "\n${GREEN}Restore successfully completed!${NC}"
echo "Your n8n instance is now running with the restored data."
echo -e "Access it here: ${GREEN}http://localhost:5678${NC}"