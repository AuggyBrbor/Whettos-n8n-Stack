#!/bin/bash

# This script creates a new, empty n8n instance using Podman.
# It should be run from the root directory of the toolkit.

# --- Configuration ---
COMPOSE_FILE="./fedora/podman-compose.yml";
PROJECT_NAME="n8n_stack";
ENV_FILE=".env";
ENV_TEMPLATE=".env.template";
GREEN='\033[0;32m';
YELLOW='\033[1;33m';
RED='\033[0;31m';
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

echo -e "${GREEN}Pre-flight checks passed!${NC}"
echo ""

# --- Deployment ---
echo "--- Starting Deployment ---"
echo "Pulling the latest container images..."
podman-compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" pull

echo "Starting the services... (This may take a moment)"
podman-compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d

if [ $? -eq 0 ]; then
    echo -e "${GREEN}Deployment successful!${NC}"
    echo ""
    echo "Your n8n instance should be available at:"
    echo -e "➡️  ${GREEN}http://localhost:5678${NC}"
    echo ""
    echo "Your Ollama API is available at:"
    echo -e "➡️  ${GREEN}http://localhost:11434${NC}"
else
    echo -e "${RED}Error: Deployment failed. Check the output above for details.${NC}"
    echo "You can view logs using: podman-compose -f $COMPOSE_FILE logs"
fi
