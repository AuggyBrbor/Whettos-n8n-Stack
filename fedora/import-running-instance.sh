#!/bin/bash

# This script imports workflows from the '/imports' directory into a running n8n instance.
# It should be run from the root directory of the toolkit.

# --- Configuration ---
IMPORTS_DIR="./imports"
CONTAINER_NAME="n8n-main"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Pre-flight Checks ---
echo "--- Running Pre-flight Checks ---"

# Check if the container is running
if ! podman container exists "$CONTAINER_NAME" || ! [[ "$(podman inspect -f '{{.State.Status}}' "$CONTAINER_NAME")" == "running" ]]; then
    echo -e "${RED}Error: The '$CONTAINER_NAME' container is not running.${NC}"
    echo "Please start the pod before running this script."
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

# --- Workflow Import ---
echo "--- Importing Workflows ---"

echo "Copying workflows to container..."
podman cp "$IMPORTS_DIR" "${CONTAINER_NAME}:/home/node/.n8n/imports"

echo "Running import script inside the container..."
# --- CORRECTED: Using double quotes inside the command to allow for variable expansion ---
IMPORT_COMMAND="cd /home/node/.n8n/imports && for file in *.json; do echo \"Importing workflow: \$file\"; n8n import:workflow --input=\"\$file\"; done"
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
