#!/bin/bash

# This script creates a new n8n instance and imports workflows from the '/imports' directory.
# It should be run from the root directory of the toolkit.

# --- Configuration ---
COMPOSE_FILE="./fedora/podman-compose.yml"
ENV_FILE=".env"
ENV_TEMPLATE=".env.template"
IMPORTS_DIR="./imports"
CONTAINER_NAME="n8n-main"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Helper Functions ---
function check_command() {
    if ! command -v $1 &> /dev/null; then
        echo -e "${RED}Error: Command '$1' not found. Please install it and try again.${NC}"
        exit 1
    fi
}

# --- Pre-flight Checks ---
echo "--- Running Pre-flight Checks ---"
check_command podman
check_command podman-compose

# Check for .env file
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}Warning: '$ENV_FILE' not found.${NC}"
    echo "Copying from '$ENV_TEMPLATE'..."
    cp "$ENV_TEMPLATE" "$ENV_FILE"
    echo -e "${YELLOW}Please edit the '$ENV_FILE' file with your credentials, then re-run this script.${NC}"
    exit 1
fi

# Source .env file to check for required variables
set -a
source "$ENV_FILE"
set +a

if [[ -z "$POSTGRES_PASSWORD" || "$POSTGRES_PASSWORD" == "YourSuperSecretPassword" ]]; then
    echo -e "${RED}Error: POSTGRES_PASSWORD is not set in the .env file. Please update it.${NC}"
    exit 1
fi

if [[ -z "$N8N_E_KEY" || "$N8N_E_KEY" == "YourGenerated32CharacterEncryptionKey" ]]; then
    echo -e "${RED}Error: N8N_E_KEY is not set in the .env file. Please update it.${NC}"
    exit 1
fi

# Check if imports directory exists and has JSON files
if [ ! -d "$IMPORTS_DIR" ] || [ -z "$(find "$IMPORTS_DIR" -maxdepth 1 -name '*.json' -print -quit)" ]; then
    echo -e "${RED}Error: The '$IMPORTS_DIR' directory does not exist or contains no .json files.${NC}"
    echo "Please add your workflow files to the '$IMPORTS_DIR' directory and try again."
    exit 1
fi

echo -e "${GREEN}Pre-flight checks passed!${NC}"
echo ""

# --- Deployment ---
echo "--- Starting Deployment ---"
echo "Pulling the latest container images..."
podman-compose -f "$COMPOSE_FILE" pull

echo "Starting the services... (This may take a moment)"
podman-compose -f "$COMPOSE_FILE" up -d

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Deployment failed. Check the output above for details.${NC}"
    exit 1
fi

echo -e "${GREEN}Services started successfully.${NC}"
echo ""

# --- Workflow Import ---
echo "--- Importing Workflows ---"
echo "Waiting for n8n container to be ready..."
sleep 15 # Give the container a moment to initialize

echo "Copying workflows to container..."
podman cp "$IMPORTS_DIR" "${CONTAINER_NAME}:/home/node/.n8n/imports"

echo "Running import script inside the container..."
IMPORT_COMMAND="cd /home/node/.n8n/imports && for file in *.json; do echo 'Importing workflow: \$file' && n8n import:workflow --input=\"\$file\"; done"
podman exec "$CONTAINER_NAME" sh -c "$IMPORT_COMMAND"

echo "Cleaning up import files from container..."
podman exec "$CONTAINER_NAME" rm -rf /home/node/.n8n/imports

echo -e "${GREEN}Workflow import process complete!${NC}"
echo ""
echo "Your n8n instance should be available at:"
echo -e "➡️  ${GREEN}http://localhost:5678${NC}"
echo ""
echo "Your Ollama API is available at:"
echo -e "➡️  ${GREEN}http://localhost:11434${NC}"
