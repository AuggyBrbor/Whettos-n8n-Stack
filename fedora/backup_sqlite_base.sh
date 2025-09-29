#!/bin/bash
# A non-disruptive script to back up a running n8n podman-compose stack.
# This script is intended to be run from the project root directory.

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
BACKUP_DIR="./backups"
COMPOSE_FILE="./fedora/podman-compose-basic_b.yml"
ENV_FILE="./.env"


# --- Pre-flight Checks ---
echo "🚀 Running pre-flight checks..."
if ! command -v podman &> /dev/null || ! command -v podman-compose &> /dev/null; then
    echo "❌ Error: 'podman' or 'podman-compose' not found." >&2; exit 1;
fi
if ! command -v jq &> /dev/null; then
    echo "❌ Error: 'jq' is not installed, which is required for JSON modifications." >&2; exit 1;
fi
if ! command -v curl &> /dev/null; then
    echo "❌ Error: 'curl' is not installed, which is required for the health check." >&2; exit 1;
fi
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "❌ Error: Compose file not found. Please run this script from your project's root directory." >&2; exit 1;
fi
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: '$ENV_FILE' not found in the project root. Cannot proceed." >&2; exit 1;
fi
mkdir -p "$BACKUP_DIR"

# --- Main Logic ---
echo -e "\n--- Starting Live Backup: $(date) ---"

# Source environment variables from the project root
set -a
# shellcheck source=../.env
source "$ENV_FILE"
set +a

# Set default for retention and copyright if not provided in .env
RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-7}
# Set default for the copyright name if not provided in .env
COPYRIGHT_NAME=${COPYRIGHT_NAME:-"Auggy Brbor"}
# Get n8n port from environment or use default for the health check
N8N_PORT=${N8N_PORT:-5678}


# --- Backup Steps ---

# 2. Create timestamped backup directory
TIMESTAMP=$(date +"%Y%m%d-%H%M%S");
CURRENT_BACKUP_DIR="$BACKUP_DIR/backup_$TIMESTAMP";
N8N_BACKUP_FILE="$CURRENT_BACKUP_DIR/n8n_data_and_db.tar.gz"; # Renamed for clarity
WORKFLOW_DIR="$CURRENT_BACKUP_DIR/workflows";
CREDS_DIR="$CURRENT_BACKUP_DIR/creds";
mkdir -p "$WORKFLOW_DIR";
mkdir -p "$CREDS_DIR";

# 3. Stop n8n, then create a complete and consistent backup of the data volume
echo -e "\n⏳ Stopping n8n service for a safe backup..."
podman-compose -p "n8n_stack" -f "$COMPOSE_FILE" stop n8n-main

echo "  -> Waiting for container to stop..."
while [[ "$(podman inspect --format='{{.State.Status}}' n8n-main 2>/dev/null)" != "exited" ]]; do
    sleep 1
done
echo "  -> Container successfully stopped."

echo "  -> Copying data from stopped container and creating archive..."
TEMP_DATA_DIR=$(mktemp -d)
podman cp n8n-main:/home/node/.n8n "$TEMP_DATA_DIR/data"
tar -czpf "$N8N_BACKUP_FILE" -C "$TEMP_DATA_DIR" .
rm -rf "$TEMP_DATA_DIR" # Clean up temporary directory
echo "✅ Complete data volume backup created: $N8N_BACKUP_FILE"

# 4. Restart n8n, then export specific assets
echo -e "\n⏳ Restarting n8n service..."
podman-compose -p "n8n_stack" -f "$COMPOSE_FILE" start n8n-main
echo -n "  -> Waiting for service to become healthy..."
HEALTHCHECK_URL="http://localhost:${N8N_PORT}/healthz"
max_wait=120
wait_time=0
until $(curl --output /dev/null --silent --head --fail "$HEALTHCHECK_URL"); do
    printf '.'
    sleep 5
    wait_time=$((wait_time+5))
    if [ $wait_time -ge $max_wait ]; then
        echo "\n❌ Error: n8n service did not become healthy after ${max_wait} seconds." >&2
        echo "    Please check the container logs with 'podman logs n8n-main' to diagnose." >&2
        exit 1
    fi
done
echo -e "\n✅ Service is healthy and ready."

echo -e "\n⏳ Exporting workflows and credentials from running service..."
podman exec -u node -it n8n-main n8n export:workflow --backup --output=backups/latest/workflows || true
podman cp n8n-main:/home/node/backups/latest/workflows/. "$WORKFLOW_DIR" || true
podman exec -u node -it n8n-main rm -rf ./backups/latest/workflows || true

podman exec -u node -it n8n-main n8n export:credentials --backup --output=backups/latest/creds || true
podman cp n8n-main:/home/node/backups/latest/creds/. "$CREDS_DIR" || true
podman exec -u node -it n8n-main rm -rf ./backups/latest/creds || true
echo "✅ Export process finished."

# 5. Restore SELinux Contexts (Important for Fedora/RHEL)
echo -e "\n⏳ Restoring SELinux contexts for backup files..."
if command -v restorecon &> /dev/null; then
    restorecon -R "$CURRENT_BACKUP_DIR"
    echo "✅ SELinux contexts restored."
else
    echo "⚠️ 'restorecon' not found. Skipping SELinux context restoration."
fi

# 6. Apply Custom Modifications to Workflow JSONs
echo -e "\n🔧 Applying modifications to workflow JSON files..."
# Prepare copyright strings for use in the function
COPYRIGHT_HOLDER="© ${COPYRIGHT_NAME}"
# Replace spaces with nothing for the ID prefix to match original format
ID_PREFIX_NAME=$(echo "$COPYRIGHT_NAME" | tr -d ' ')
ID_PREFIX="©${ID_PREFIX_NAME}-"
# 1. Define the raw text content separately in a heredoc for readability.
note_content="&nbsp;
&nbsp;
&nbsp;
&nbsp;
&nbsp;
&nbsp;
&nbsp;
# Well, hello there! Your workflow has arrived.

Looks like you've just beamed in a shiny new n8n workflow, teleported straight out of someone's instance courtesy of the export tool by **Auggy Brbor**. Before you unleash its automated power upon the world, let's go through a quick pre-flight check to ensure a smooth takeoff.

### **Pre-Flight Checklist: 3 Simple Steps**

To avoid any awkward I can't connect moments, please follow these steps in order:

1.  **Credential Check-up:** First things first! Before you get click-happy and open any nodes, head over to your credentials list. Ensure that all the necessary authorizations (like API keys, OAuth tokens, etc.) this workflow depends on are present, correct, and ready for action.

2.  **The Grand Re-introduction:** Once you've confirmed your credentials are in place, it's time for the nodes to meet their new keys. Go ahead and open each node that requires a credential. This isn't just for fun; this step is crucial for re-associating the node with the correct, freshly-checked credential in your system.

3.  **Flip the Switch:** This workflow might have arrived in inactive mode. If it was active before its journey here, and you want it to be active now, don't forget to toggle the switch to **Active** in the top right corner. Give it the green light!

> **A Quick Legal Note**
> 
> Please be aware that this workflow is provided as-is. The original copyright, if almost certainly applicable, remains with its original creator. This import tool facilitates transfer, not ownership. **Use this workflow** responsibly and **in accordance with any license or terms of use that accompanied the original**.

Happy automating!";

# 2. Use jq to safely build the final JSON object. This handles all necessary escaping.
# Temporarily disable exit-on-error to handle potential jq failure gracefully.
set +e
NOTE_NODE_JSON=$(jq -n \
    --arg content "${note_content}-${COPYRIGHT_NAME}" \
    --arg name "$COPYRIGHT_HOLDER" \
    '{
        "parameters": {
            "content": $content,
            "height": 1328,
            "width": 320,
            "color": 6
        },
        "type": "n8n-nodes-base.stickyNote",
        "position": [80, 80],
        "typeVersion": 1,
        "id": "1a6be635-d047-4687-be08-1c30d0a6c2f1",
        "name": $name
    }')
jq_exit_code=$?
# Re-enable exit-on-error immediately after.
set -e

# Check if the jq command failed and provide a clear error instead of silently exiting.
if [ $jq_exit_code -ne 0 ]; then
    echo "  -> ❌ Error: Failed to build the note JSON object with jq (exit code: $jq_exit_code)." >&2
    echo "  -> This can happen with special characters. Aborting modifications." >&2
    return 1 # Propagate the failure
fi


if [ ! -d "$WORKFLOW_DIR" ]; then
    echo "  -> Warning: Target directory for JSON modification does not exist: $WORKFLOW_DIR"
    return
fi
# Check if directory is empty
if [ -z "$(ls -A "$WORKFLOW_DIR")" ]; then
    echo "  -> Skipping: No workflow files were found in the backup directory."
    return
fi

echo "  -> Scanning for .json files in $WORKFLOW_DIR..."

find "$WORKFLOW_DIR" -type f -name "*.json" -print0 | while IFS= read -r -d '' file; do
    echo "    - Processing: ${file}"
    if ! jq -e 'has("id") and (.id | type == "string") and has("nodes") and (.nodes | type == "array")' "$file" > /dev/null 2>&1; then
        echo "      -> Skipping: File does not have the required structure."
        continue
    fi
    
    tmpfile=$(mktemp)
    jq --argjson note "$NOTE_NODE_JSON" --arg holder "$COPYRIGHT_HOLDER" --arg prefix "$ID_PREFIX" '
        (if (.id | startswith($prefix) | not) then .id = $prefix + .id else . end) |
        (if (any(.nodes[]; .name == $holder) | not) then .nodes = [$note] + .nodes else . end)
    ' "$file" > "$tmpfile"
    
    if [ -s "$tmpfile" ]; then
        mv "$tmpfile" "$file"
        echo "      -> Success: File has been modified."
    else
        echo "      -> Error: jq processing failed for this file. Original remains untouched." >&2
        rm -f "$tmpfile"
    fi
done
echo "✅ JSON modifications complete."

# 7. Prune Old Backups
echo -e "\n🧹 Pruning backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -type d -name "backup_*" -mtime +"$RETENTION_DAYS" -exec echo "  - Removing old backup: {}" \; -exec rm -rf {} \;
echo "✅ Pruning complete."

echo -e "\n🎉 Backup process finished successfully!"
