#!/bin/bash
# Core logic for n8n and clientData backup, designed to be executed via a 
# Windows PowerShell wrapper (backup.ps1).

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration (Dynamic Pathing) ---
# Resolve the script's actual location (e.g., /mnt/c/project/windows)
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
# PROJECT_ROOT is two directories up (e.g., /mnt/c/project)
PROJECT_ROOT=$(dirname $(dirname "$SCRIPT_DIR"))

# Set paths using the calculated PROJECT_ROOT
BACKUP_DIR="${PROJECT_ROOT}/backups"
# COMPOSE_FILE is in the 'fedora' subdirectory
COMPOSE_FILE="${PROJECT_ROOT}/fedora/podman-compose.yml"
# ENV_FILE is in the project root
ENV_FILE="${PROJECT_ROOT}/.env"

# Independent Database Configuration
CLIENT_DB_CONTAINER_NAME="clientData"
CLIENT_DB_USER="admin"

# --- Pre-flight Checks ---
echo "🚀 Running pre-flight checks..."
if ! command -v podman &> /dev/null || ! command -v podman-compose &> /dev/null; then
    echo "❌ Error: 'podman' or 'podman-compose' not found. Please install them." >&2; exit 1;
fi
if ! command -v jq &> /dev/null; then
    echo "❌ Error: 'jq' is not installed, which is required for JSON modifications." >&2; exit 1;
fi
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "❌ Error: Compose file not found at: $COMPOSE_FILE" >&2; exit 1;
fi
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: '$ENV_FILE' not found. Cannot proceed without credentials." >&2; exit 1;
fi
# Use the absolute path for mkdir
mkdir -p "$BACKUP_DIR"

# --- Main Logic ---
echo -e "\n--- Starting Live Backup: $(date) ---"

# Source environment variables from the project root
set -a
# shellcheck source=../.env
source "$ENV_FILE"
set +a

# Validate required variables
if [[ -z "$POSTGRES_USER" || -z "$POSTGRES_DB" ]]; then
    echo "❌ Error: Required database variables (POSTGRES_USER, POSTGRES_DB) are not set in the .env file." >&2; exit 1;
fi
RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-7}
# Set default for the copyright name if not provided in .env
COPYRIGHT_NAME=${COPYRIGHT_NAME:-"Auggy Brbor"}

# 1. Ensure n8n services are running for the backup
echo "🔎 Verifying that core n8n containers are running..."
for C in "n8n-postgres" "n8n-main"; do
    if ! podman container exists "$C" || ! podman inspect --format='{{.State.Running}}' "$C" | grep -q "true"; then
        echo "⚠️ Container '$C' not found or not running. Starting the stack..."
        # NOTE: Using the absolute COMPOSE_FILE path
        podman-compose -f "$COMPOSE_FILE" up -d
        echo "Waiting for services to initialize..."
        sleep 15
        break # Exit loop after starting stack
    fi
done
echo "✅ Core n8n containers are running."

# 2. Create timestamped backup directory
TIMESTAMP=$(date +"%Y%m%d-%H%M%S");
CURRENT_BACKUP_DIR="$BACKUP_DIR/backup_$TIMESTAMP";
N8N_DB_BACKUP_FILE="$CURRENT_BACKUP_DIR/n8n_database.sql.gz";
N8N_BACKUP_FILE="$CURRENT_BACKUP_DIR/n8n_files.tar.gz";
CLIENT_DB_BACKUP_DIR="$CURRENT_BACKUP_DIR/client_databases";
WORKFLOW_DIR="$CURRENT_BACKUP_DIR/workflows"; 
CREDS_DIR="$CURRENT_BACKUP_DIR/creds";       
mkdir -p "$CLIENT_DB_BACKUP_DIR";
mkdir -p "$WORKFLOW_DIR";
mkdir -p "$CREDS_DIR";

# 3. Backup n8n PostgreSQL Database
echo -e "\n⏳ Backing up n8n PostgreSQL database..."
# Execute as the 'postgres' user inside the container to simplify authentication.
podman exec --user postgres n8n-postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -F c | gzip > "$N8N_DB_BACKUP_FILE"

echo "✅ n8n Database backup complete: $N8N_DB_BACKUP_FILE"


# 3b. Backup Independent Client Databases
echo -e "\n⏳ Backing up all databases in independent container: $CLIENT_DB_CONTAINER_NAME..."

# Check if the independent container is running
if ! podman container exists "$CLIENT_DB_CONTAINER_NAME" || ! podman inspect --format='{{.State.Running}}' "$CLIENT_DB_CONTAINER_NAME" | grep -q "true"; then
    echo "  -> ❌ Error: Independent database container '$CLIENT_DB_CONTAINER_NAME' not found or not running. Skipping this backup."
else
    # Get a list of all database names, excluding the template databases, using the provided user.
    echo "  -> Listing user databases in $CLIENT_DB_CONTAINER_NAME..."
    # The 'postgres' user is used for psql -l to ensure listing all dbs, and then -U $CLIENT_DB_USER is used for pg_dump
    DATABASES=$(podman exec --user postgres "$CLIENT_DB_CONTAINER_NAME" psql -U postgres -l -t | cut -d'|' -f1 | sed -e 's/ //g' -e '/^$/d' | grep -vE 'template[01]|postgres')

    # Check if any databases were found.
    if [ -z "$DATABASES" ]; then
        echo "  -> ⚠️ No user databases found to export from $CLIENT_DB_CONTAINER_NAME. Skipping."
    else
        echo "  -> The following databases will be exported:"
        echo "$DATABASES"
        
        # Loop through each database name and create a dump file for it.
        for DB in $DATABASES; do
            FILENAME="$CLIENT_DB_BACKUP_DIR/$DB.sql.gz"
            echo "  -> Dumping database: $DB to $FILENAME"

            # Use podman exec to run pg_dump inside the container.
            # Use the configured user for the dump.
            podman exec "$CLIENT_DB_CONTAINER_NAME" pg_dump -U "$CLIENT_DB_USER" -d "$DB" -F c | gzip > "$FILENAME"

            # Check if the dump was successful.
            if [ $? -eq 0 ]; then
                echo "    -> Success."
            else
                echo "    -> ERROR: Failed to dump database $DB. Check if user '$CLIENT_DB_USER' has access."
            fi
        done
        echo "✅ All client database backups complete: $CLIENT_DB_BACKUP_DIR"
    fi
fi


# 4. Backup n8n Data Volume and Export Workflows/Credentials
echo -e "\n⏳ Backing up n8n data volume and exporting assets..."
podman exec n8n-main tar -czpf - -C /home/node/.n8n . > "$N8N_BACKUP_FILE"
echo "✅ Data volume backup complete: $N8N_BACKUP_FILE"

# Export workflows and credentials from the container
podman exec -u node -it n8n-main n8n export:workflow --backup --output=backups/latest/workflows
# NOTE: The path inside the container is relative, but the copy to the host uses the absolute path
podman cp n8n-main:/home/node/backups/latest/workflows/. "$WORKFLOW_DIR"
podman exec -u node -it n8n-main rm -rf ./backups/latest/workflows

podman exec -u node -it n8n-main n8n export:credentials --backup --output=backups/latest/creds
podman cp n8n-main:/home/node/backups/latest/creds/. "$CREDS_DIR"
podman exec -u node -it n8n-main rm -rf ./backups/latest/creds
echo "✅ Workflows and credentials exported."

# 5. Restore SELinux Contexts (Important for Fedora/RHEL)
echo -e "\n⏳ Restoring SELinux contexts for backup files..."
if command -v restorecon &> /dev/null; then
    restorecon -R "$CURRENT_BACKUP_DIR"
    echo "✅ SELinux contexts restored."
else
    echo "⚠️ 'restorecon' not found. Skipping SELinux context restoration."
fi


# 5. Apply Custom Modifications to Workflow JSONs
echo -e "\n🔧 Applying modifications to workflow JSON files..."
# Prepare copyright strings for use in the function
COPYRIGHT_HOLDER="© ${COPYRIGHT_NAME}"
# Replace spaces with nothing for the ID prefix to match original format
ID_PREFIX_NAME=$(echo "$COPYRIGHT_NAME" | tr -d ' ')
ID_PREFIX="©${ID_PREFIX_NAME}-"
# 5.1. Define the raw text content separately in a heredoc for readability.
note_content="&nbsp;
&nbsp;
&nbsp;
&nbsp;
&nbsp;
&nbsp;
&nbsp;
# Well, hello there! Your workflow has arrived.

Looks like you've beamed in a shiny new n8n workflow, teleported straight out of someone's instance courtesy of the export tool by **Auggy Brbor**. Before you unleash its automated power upon the world, let's go through a quick pre-flight check to ensure a smooth takeoff.

### **Pre-Flight Checklist: 3 Simple Steps**

To avoid any awkward I can't connect moments, please follow these steps in order:

1.  **Credential Check-up:** First things first! Before you get click-happy and open any nodes, head over to your credentials list. Ensure that all the necessary authorizations (like API keys, OAuth tokens, etc.) this workflow depends on are present, correct, and ready for action.

2.  **The Grand Re-introduction:** Once you've confirmed your credentials are in place, it's time for the nodes to meet their new keys. Go ahead and open each node that requires a credential. This isn't just for fun; this step is crucial for re-associating the node with the correct, freshly-checked credential in your system.

3.  **Flip the Switch:** This workflow might have arrived in inactive mode. If it was active before its journey here, and you want it to be active now, don't forget to toggle the switch to **Active** in the top right corner. Give it the green light!

> **A Quick Legal Note**
> 
> Please be aware that this workflow is provided as-is. The original copyright, if almost certainly applicable, remains with its original creator. This import tool facilitates transfer, not ownership. **Use this workflow** responsibly and **in accordance with any license or terms of use that accompanied the original**.

Happy automating!";

# 5.2. Use jq to safely build the final JSON object. This handles all necessary escaping.
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
    exit 1 # Propagate the failure
fi


if [ ! -d "$WORKFLOW_DIR" ]; then
    echo "  -> Warning: Target directory for JSON modification does not exist: $WORKFLOW_DIR"
    exit 0 # Non-critical failure
fi
# Check if directory is empty
if [ -z "$(ls -A "$WORKFLOW_DIR")" ]; then
    echo "  -> Skipping: No workflow files were found in the backup directory."
    exit 0 # Non-critical failure
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

# 6. Prune Old Backups
echo -e "\n🧹 Pruning backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -type d -name "backup_*" -mtime +"$RETENTION_DAYS" -exec echo "  - Removing old backup: {}" \; -exec rm -rf {} \;
echo "✅ Pruning complete."

echo -e "\n🎉 Backup process finished successfully!"