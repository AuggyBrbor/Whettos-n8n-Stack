#!/bin/bash

# This script restores the n8n instance from a selected backup using a hot-swap method.
# WARNING: This is a destructive operation and will restart your n8n pod.
# It should be run from the root directory of the toolkit.

set -e # Exit on any error

# --- Configuration ---
# --- DYNAMIC PATHING & CONFIGURATION ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
COMPOSE_FILE="${PROJECT_ROOT}/fedora/podman-compose-basic_b.yml"
BACKUP_DIR="${PROJECT_ROOT}/backups"
ENV_FILE="${PROJECT_ROOT}/.env"

# The project name is used for volumes, pods, and compose operations.
PROJECT_NAME="n8n_stack"
N8N_DATA_VOLUME_NAME="${PROJECT_NAME}_n8n-data"
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

if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "❌ Error: .env file not found at ${PROJECT_ROOT}/.env"
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

N8N_BACKUP_FILE="$SELECTED_BACKUP_DIR/n8n_data_and_db.tar.gz"
echo "${N8N_BACKUP_FILE}"
if [ ! -f "$N8N_BACKUP_FILE" ]; then
    echo -e "${RED}Error: Backup is incomplete. Missing database or data file in $SELECTED_BACKUP_DIR${NC}"
    exit 1
fi

# Confirmation Prompt
echo -e "\n${YELLOW}WARNING: This will stop your n8n services, overwrite the current data with the selected backup, and restart the entire stack. This action is irreversible.${NC}"
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
cd "${PROJECT_ROOT}"
podman pod stop "pod_$PROJECT_NAME" --ignore
podman pod rm "pod_$PROJECT_NAME" --force || true;
podman volume ls --format "{{.Name}}" | grep -E "${PROJECT_NAME}_" | xargs --no-run-if-empty podman volume rm -f
# # We add '|| true' to prevent the script from exiting if a container is already stopped.
# podman pod ps -f="name=pod_$PROJECT_NAME" --format="{{.ContainerNames}}" --ctr-names | tr ',' '\n' | grep -vE 'postgres$|^ollama' | xargs podman container stop || true
echo "✅ Stack stopped and volumes removed."

echo "Restoring n8n data to new volume '${N8N_DATA_VOLUME_NAME}'..."
podman volume create "${N8N_DATA_VOLUME_NAME}"

# Use a helper container to unpack the archive into the newly created volume
podman run --rm \
    -v "${N8N_DATA_VOLUME_NAME}:/volume-data:z" \
    -v "${N8N_BACKUP_FILE}:/backup/archive.tar.gz:ro,z" \
    docker.io/alpine \
    tar -xzpf /backup/archive.tar.gz -C /volume-data
    
echo "✅ n8n data restore complete."

# --- Step 4: Restart the Full Stack ---
echo
echo "🚀 Starting the full n8n stack..."
podman-compose -p $PROJECT_NAME -f $COMPOSE_FILE up -d

echo -e "\n${GREEN}Restore successfully completed!${NC}"
echo "Your n8n instance is now running with the restored data."
echo -e "Access it here: ${GREEN}http://localhost:5678${NC}"