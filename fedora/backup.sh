#!/bin/bash
# A non-disruptive script to back up a running n8n podman-compose stack.
# This script is intended to be run from the project root directory.

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
BACKUP_DIR="./backups"
COMPOSE_FILE="./fedora/podman-compose.yml"
ENV_FILE="./.env"

# --- Pre-flight Checks ---
echo "🚀 Running pre-flight checks..."
if ! command -v podman &> /dev/null || ! command -v podman-compose &> /dev/null; then
    echo "❌ Error: 'podman' or 'podman-compose' not found." >&2; exit 1;
fi
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "❌ Error: Compose file not found. Please run this script from your project's root directory." >&2; exit 1;
fi
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Error: '$ENV_FILE' not found in the project root. Cannot proceed without credentials." >&2; exit 1;
fi
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

# 1. Ensure services are running for the backup
echo "🔎 Verifying that core containers are running..."
for C in "n8n-postgres" "n8n-main"; do
    if ! podman container exists "$C" || ! podman inspect --format='{{.State.Running}}' "$C" | grep -q "true"; then
        echo "⚠️ Container '$C' not found or not running. Starting the stack..."
        podman-compose -f "$COMPOSE_FILE" up -d
        echo "Waiting for services to initialize..."
        sleep 15
        break # Exit loop after starting stack
    fi
done
echo "✅ Core containers are running."

# 2. Create timestamped backup directory
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
CURRENT_BACKUP_DIR="$BACKUP_DIR/backup_$TIMESTAMP"
DB_BACKUP_FILE="$CURRENT_BACKUP_DIR/n8n_database.sql.gz"
N8N_BACKUP_FILE="$CURRENT_BACKUP_DIR/n8n_files.tar.gz"
mkdir -p "$CURRENT_BACKUP_DIR"

# 3. Backup PostgreSQL Database
echo -e "\n⏳ Backing up PostgreSQL database..."
# Execute as the 'postgres' user inside the container to simplify authentication.
podman exec --user postgres n8n-postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -F c > gzip "$DB_BACKUP_FILE"

echo "✅ Database backup complete: $DB_BACKUP_FILE"

# 4. Backup n8n Data Volume
echo -e "\n⏳ Backing up n8n data volume..."
# --- FINAL FIX ---
# Execute 'tar' directly inside the 'n8n-main' container.
# This container runs as the correct user and has guaranteed access to its volume data.
# The '-' tells tar to send the archive to stdout, which we redirect to our host file.
podman exec n8n-main \
  tar -czpf - -C /home/node/.n8n . > "$N8N_BACKUP_FILE"

echo "✅ Data volume backup complete: $N8N_BACKUP_FILE"

# 5. Prune Old Backups
echo -e "\n🧹 Pruning backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -type d -name "backup_*" -mtime +"$RETENTION_DAYS" -exec echo "  - Removing old backup: {}" \; -exec rm -rf {} \;
echo "✅ Pruning complete."

echo -e "\n🎉 Backup process finished successfully!"