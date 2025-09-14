# This script provides a graceful backup of the n8n pod on Windows, correctly handling scaled workers.
# It should be run from the root directory of the toolkit.

# --- Configuration ---
$EnvFile = ".\.env"
$BackupDir = ".\backups"

# --- Pre-flight Checks ---
Write-Host "--- Running Pre-flight Checks ---" -ForegroundColor Cyan
if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
    Write-Host "Error: 'podman' not found." -ForegroundColor Red; exit 1
}
if (-not (Test-Path $EnvFile)) {
    Write-Host "Error: '$EnvFile' not found. Cannot proceed." -ForegroundColor Red; exit 1
}
if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir | Out-Null
}

# --- Dynamic Name Discovery ---
$ProjectName = (podman inspect n8n-main --format '{{ index (index . 0).Labels "com.docker.compose.project" }}' 2>$null)
if (-not $ProjectName) {
    Write-Host "Warning: Could not get project name from label. Falling back to name parsing." -ForegroundColor Yellow
    $WorkerName = (podman ps --format '{{.Names}}') | Where-Object { $_ -like "*_n8n-worker_*" } | Select-Object -First 1
    if (-not $WorkerName) {
        Write-Host "Error: Could not find a running n8n-worker container to determine project name. Is the pod running?" -ForegroundColor Red
        exit 1
    }
    $ProjectName = $WorkerName.Split('_')[0]
}

$NetworkName = "$($ProjectName)_n8n-stack"
$N8nDataVolume = "$($ProjectName)_n8n-data"
Write-Host "Discovered project '$($ProjectName)', network '$($NetworkName)', and volume '$($N8nDataVolume)'" -ForegroundColor Green

# --- Main Logic ---
Write-Host "`n--- Starting Graceful Backup: $(Get-Date) ---" -ForegroundColor Cyan
$envContent = Get-Content $EnvFile -Raw
$envVars = $envContent | ConvertFrom-StringData -Delimiter '='
$env:PGPASSWORD = $envVars.POSTGRES_PASSWORD
$postgresUser = if ($envVars.POSTGRES_USER) { $envVars.POSTGRES_USER } else { "n8n" }
$postgresDb = if ($envVars.POSTGRES_DB) { $envVars.POSTGRES_DB } else { "n8n" }
$retentionDays = if ($envVars.BACKUP_RETENTION_DAYS) { [int]$envVars.BACKUP_RETENTION_DAYS } else { 7 }

# 1. Dynamically find and gracefully stop all n8n services
Write-Host "`nStep 1: Discovering and stopping n8n services..." -ForegroundColor Yellow
$N8nContainers = (podman ps --filter "label=com.docker.compose.project=$($ProjectName)" --format '{{.ID}} {{.Names}}') | Where-Object { $_ -match "n8n-main" -or $_ -match "_n8n-worker" } | ForEach-Object { $_.Split(' ')[0] }
if (-not $N8nContainers) {
    Write-Host "Error: No running n8n-main or n8n-worker containers found for project '$($ProjectName)'." -ForegroundColor Red
    exit 1
}
Write-Host "Found n8n containers to stop:"
podman ps --filter "id=$($N8nContainers -join ",")" --format '{{.Names}}'
podman stop $N8nContainers | Out-Null

try {
    # 2. Create timestamped backup directory
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $currentBackupDir = Join-Path -Path $BackupDir -ChildPath "backup_$timestamp"
    New-Item -ItemType Directory -Path $currentBackupDir | Out-Null
    Write-Host "Created backup directory: $currentBackupDir"

    # 3. Backup PostgreSQL Database
    Write-Host "`nStep 2: Backing up PostgreSQL database..." -ForegroundColor Yellow
    $dbBackupFile = Join-Path -Path $currentBackupDir -ChildPath "n8n_db_backup.sql.gz"
    $pgDumpCommand = "podman run --rm --network `"$NetworkName`" -e PGPASSWORD=`"$($env:PGPASSWORD)`" docker.io/postgres:16 pg_dump -h postgres -U `"$postgresUser`" -d `"$postgresDb`" -F c -b -v"
    cmd /c "$pgDumpCommand | gzip > `"$dbBackupFile`""
    Write-Host "Database backup complete."

    # 4. Backup n8n Data Volume
    Write-Host "`nStep 3: Backing up n8n data volume..." -ForegroundColor Yellow
    $dataBackupFile = Join-Path -Path $currentBackupDir -ChildPath "n8n_data_volume.tar.gz"
    $tarCommand = "podman run --rm --user `"1000:1000`" -v `"$N8nDataVolume`:/n8n-data:ro`" docker.io/alpine:latest tar -czf - -C `"/n8n-data`" ."
    cmd /c "$tarCommand > `"$dataBackupFile`""
    Write-Host "Data volume backup complete."

    # 5. Prune Old Backups
    Write-Host "`nStep 4: Pruning backups older than $retentionDays days..." -ForegroundColor Yellow
    Get-ChildItem -Path $BackupDir -Directory -Filter "backup_*" | Where-Object { $_.CreationTime -lt (Get-Date).AddDays(-$retentionDays) } | ForEach-Object {
        Write-Host "Removing old backup: $($_.FullName)"; Remove-Item -Recurse -Force $_.FullName
    }
    Write-Host "Pruning complete."
}
finally {
    # Final step: Always restart n8n services
    Write-Host "`n--- Final Step: Restarting n8n services... ---" -ForegroundColor Yellow
    podman start $N8nContainers | Out-Null
    Write-Host "Backup process finished. Services are running." -ForegroundColor Green
    $env:PGPASSWORD = $null
}