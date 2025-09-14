#!/bin/bash

# This script creates a new n8n instance and imports workflows from the '/imports' directory.
# It should be run from the root directory of the toolkit.

# --- Configuration ---
COMPOSE_FILE="./fedora/podman-compose.yml";
ENV_FILE=".env";
IMPORTS_DIR="./imports";
CONTAINER_NAME="n8n-main";
PROJECT_NAME="n8n_stack";
GREEN='\033[0;32m';
YELLOW='\033[1;33m';
RED='\033[0;31m';
NC='\033[0m'; # No Color

# --- Pre-flight Checks ---
echo "--- Running Pre-flight Checks ---"
if ! command -v podman &> /dev/null || ! command -v podman-compose &> /dev/null; then
    echo -e "${RED}Error: 'podman' or 'podman-compose' not found.${NC}"; exit 1
fi
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}Warning: '$ENV_FILE' not found. Creating from template.${NC}"
    cp .env.template .env
    echo -e "${YELLOW}Please edit the '.env' file, then re-run this script.${NC}"; exit 1
fi
set -a; source "$ENV_FILE"; set +a
if [[ -z "$POSTGRES_PASSWORD" || "$POSTGRES_PASSWORD" == "YourSuperSecretPassword" ]]; then
    echo -e "${RED}Error: POSTGRES_PASSWORD is not set in the .env file.${NC}"; exit 1
fi
if [[ -z "$N8N_E_KEY" || "$N8N_E_KEY" == "YourGenerated32CharacterEncryptionKey" ]]; then
    echo -e "${RED}Error: N8N_E_KEY is not set in the .env file.${NC}"; exit 1
fi
if [ ! -d "$IMPORTS_DIR" ] || [ -z "$(find "$IMPORTS_DIR" -maxdepth 1 -name '*.json' -print -quit)" ]; then
    echo -e "${RED}Error: The '$IMPORTS_DIR' directory does not exist or contains no .json files.${NC}"; exit 1
fi
echo -e "${GREEN}Pre-flight checks passed!${NC}\n"

# --- Deployment ---
echo "--- Starting Deployment ---";
podman-compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" pull;
podman-compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d;
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Deployment failed.${NC}"; exit 1
fi
echo -e "${GREEN}Services started successfully.${NC}\n"

# --- Workflow Import ---
echo "--- Importing Workflows ---"
echo "Waiting for n8n container to be ready..."
sleep 15

echo "Copying workflows to container..."
podman cp "$IMPORTS_DIR" "${CONTAINER_NAME}:/home/node/.n8n/imports"

echo "Running import script inside the container..."
# --- CORRECTED: Using double quotes inside the command to allow for variable expansion ---
IMPORT_COMMAND="cd /home/node/.n8n/imports && for file in *.json; do echo \"Importing workflow: \$file\"; n8n import:workflow --input=\"\$file\"; done"
podman exec "$CONTAINER_NAME" sh -c "$IMPORT_COMMAND"

echo "Cleaning up import files from container..."
podman exec "$CONTAINER_NAME" rm -rf /home/node/.n8n/imports

echo -e "${GREEN}Workflow import process complete!${NC}\n"
echo "Your n8n instance is available at:"
echo -e "➡️  ${GREEN}http://localhost:5678${NC}\n"
echo -e "${YELLOW}IMPORTANT: You must now generate an API key in the n8n UI, add it to your .env file, and restart the stack to use the AI features. See README.md for details.${NC}"