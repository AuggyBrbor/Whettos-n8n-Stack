# This script restores the n8n instance from a selected backup on Windows.
# WARNING: This is a destructive operation and will remove existing data.
# It should be run from the root directory of the toolkit.

# --- Configuration ---
$ComposeFile = ".\windows\podman-compose.yml"
$BackupDir = ".\backups"
$EnvFile = ".\.env"
$DbContainer = "n8n-postgres"
$DbServiceName = "postgres"
# --- UPDATED: Volume name is now constructed dynamically from the project folder name ---
$ProjectName = (Get-Item -Path .).Name
$N8nDataVolume = "$($ProjectName)_n8n-data"

# --- Pre-flight Checks ---
Write-Host "--- Running Pre-flight Checks ---" -ForegroundColor Cyan
if (-not (Get-Command podman -ErrorAction SilentlyContinue) -or -not (Get-Command podman-compose -ErrorAction SilentlyContinue)) {
    Write-Host "Error: 'podman' or 'podman-compose' not found." -ForegroundColor Red; exit 1
}
if (-not (Test-Path $BackupDir) -or -not (Get-ChildItem -Path $BackupDir)) {
    Write-Host "Error: Backup directory '$BackupDir' not found or is empty." -ForegroundColor Red; exit 1
}
if (-not (Test-Path $EnvFile)) {
    Write-Host "Error: '$EnvFile' not found. Cannot proceed." -ForegroundColor Red; exit 1
}

# --- User Interaction ---
Write-Host "--- Selecting a Backup to Restore ---" -ForegroundColor Cyan
$backupFolders = Get-ChildItem -Path $BackupDir -Directory | Where-Object { $_.Name -like "backup_*" }
if ($backupFolders.Count -eq 0) {
    Write-Host "Error: No valid backup folders found in '$BackupDir'." -ForegroundColor Red; exit 1
}
for ($i = 0; $i -lt $backupFolders.Count; $i++) {
    Write-Host "[$($i+1)] $($backupFolders[$i].Name)"
}
$choice = Read-Host -Prompt "Enter the number of the backup to restore"
$index = 0
if (-not ([System.Int32]::TryParse($choice, [ref]$index)) -or $index -lt 1 -or $index -gt $backupFolders.Count) {
    Write-Host "Error: Invalid selection." -ForegroundColor Red; exit 1
}
$selectedBackupDir = $backupFolders[$index - 1].FullName
Write-Host "You have selected: $($backupFolders[$index - 1].Name)" -ForegroundColor Green
$dbBackupFile = Join-Path -Path $selectedBackupDir -ChildPath "n8n_db_backup.sql.gz"
$dataBackupFile = Join-Path -Path $selectedBackupDir -ChildPath "n8n_data_volume.tar.gz"
if (-not (Test-Path $dbBackupFile) -or -not (Test-Path $dataBackupFile)) {
    Write-Host "Error: Backup is incomplete. Missing database or data file." -ForegroundColor Red; exit 1
}

# Confirmation Prompt
Write-Host "`nWARNING: This will completely destroy the current n8n instance. This is irreversible." -ForegroundColor Yellow
$confirmation = Read-Host -Prompt "Are you sure you want to proceed? (y/n)"
if ($confirmation -ne 'y') {
    Write-Host "Restore cancelled."; exit 0
}

# --- Restore Process ---
Write-Host "`n--- Starting Restore Process ---" -ForegroundColor Cyan

# 1. Tear down existing environment
Write-Host "Stopping and removing existing containers and volumes..."
podman-compose -f $ComposeFile down -v

# 2. Restore n8n data volume
Write-Host "Creating and restoring n8n data volume ($($N8nDataVolume))..."
podman volume create $N8nDataVolume | Out-Null
cmd /c "gzip -d -c `"$dataBackupFile`" | podman volume import $N8nDataVolume -"

# 3. Start database and restore data
Write-Host "Starting PostgreSQL service..."
podman-compose -f $ComposeFile up -d $DbServiceName
Write-Host "Waiting for database to initialize (20 seconds)..."
Start-Sleep -Seconds 20
Write-Host "Restoring database from backup..."
$envContent = Get-Content $EnvFile -Raw
$envVars = $envContent | ConvertFrom-StringData -Delimiter '='
$postgresUser = if ($envVars.POSTGRES_USER) { $envVars.POSTGRES_USER } else { "n8n" }
$postgresDb = if ($envVars.POSTGRES_DB) { $envVars.POSTGRES_DB } else { "n8n" }
$ENV:PGPASSWORD = $envVars.POSTGRES_PASSWORD
cmd /c "gzip -d -c `"$dbBackupFile`" | podman exec -i $DbContainer pg_restore -U $postgresUser -d $postgresDb"
$ENV:PGPASSWORD = $null

# 4. Start all other services
Write-Host "Starting all remaining services..."
podman-compose -f $ComposeFile up -d

Write-Host "`nRestore successfully completed!" -ForegroundColor Green
Write-Host "Access your restored n8n instance at: http://localhost:5678" -ForegroundColor Green