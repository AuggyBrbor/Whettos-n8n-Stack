<#
.SYNOPSIS
    Restores an n8n instance from a selected backup using a hot-swap method on Windows.
.DESCRIPTION
    This script handles the full restoration of an n8n podman stack, including the n8n data volume,
    the primary n8n PostgreSQL database, and all databases for an independent 'clientData' PostgreSQL container.
    It is a destructive operation that will stop the stack, remove old volumes, and restart services.
.WARNING
    This is a destructive operation. Run this script from the root directory of your toolkit project.
    To run, open PowerShell, navigate to this script's directory, and execute: .\restore.ps1
#>
[CmdletBinding()]
param()

# Exit on any unhandled error, similar to 'set -e' in Bash.
$ErrorActionPreference = "Stop"

# --- Configuration ---
# --- DYNAMIC PATHING & CONFIGURATION ---
$ScriptDir = $PSScriptRoot
$ProjectRoot = (Get-Item -Path $ScriptDir).Parent.FullName
$ComposeFile = Join-Path -Path $ProjectRoot -ChildPath "fedora\podman-compose.yml"
$BackupDir = Join-Path -Path $ProjectRoot -ChildPath "backups"
$EnvFile = Join-Path -Path $ProjectRoot -ChildPath ".env"

# The project name is used for volumes, pods, and compose operations.
$ProjectName = "n8n_stack"
$N8nDataVolumeName = "${ProjectName}_n8n-data"
$PodName = "pod_${ProjectName}"

# Configuration for the independent client database container
$PostgresHostCd = "clientData"
$PostgresUserCd = "admin" # Must match the user used for dumping

# --- Pre-flight Checks ---
Write-Host "--- Running Pre-flight Checks ---"

# More resilient check: Iterate through each path directory to find podman.exe
$podmanFound = $false
$pathDirectories = $env:PATH -split ';'

foreach ($dir in $pathDirectories) {
    # Skip empty entries that can result from extra semicolons
    if ([string]::IsNullOrWhiteSpace($dir)) {
        continue
    }
    # Trim whitespace and construct the full path to the potential executable
    $potentialPath = Join-Path -Path $dir.Trim() -ChildPath "podman.exe"

    # Check if the file actually exists and is a file
    if (Test-Path -Path $potentialPath -PathType Leaf) {
        $podmanFound = $true
        break # Exit the loop as soon as we find it
    }
}

if ($podmanFound) {
    Write-Host -ForegroundColor Green "✅ Podman executable found."
}
else {
    Write-Host -ForegroundColor Red "Error: 'podman.exe' could not be found after checking all directories in your PATH."
    Write-Host -ForegroundColor Yellow "Please ensure Podman Desktop is running and its installation directory is in your system's PATH."
    Write-Host "`n"
    Write-Host -ForegroundColor Cyan "For debugging, here is the PATH as seen by this script (each entry is on a new line):"
    Write-Host $env:PATH.Replace(';', "`n")
    exit 1
}


# Check that the backup directory exists and is not empty
if (-not (Test-Path -Path $BackupDir -PathType Container) -or (Get-ChildItem -Path $BackupDir).Count -eq 0) {
    Write-Host -ForegroundColor Red "Error: Backup directory '$BackupDir' not found or is empty."
    exit 1
}

# Load variables from .env file
if (Test-Path -Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^\s*([^#\s=]+)\s*=\s*"?([^"]*)"?\s*$') {
            $key = $Matches[1]
            $value = $Matches[2]
            [System.Environment]::SetEnvironmentVariable($key, $value, 'Process')
        }
    }
}
else {
    Write-Host -ForegroundColor Red "❌ Error: .env file not found at '$EnvFile'"
    exit 1
}

# Set variables from environment, using defaults if not present
$PostgresHost = if ($env:POSTGRES_HOST) { $env:POSTGRES_HOST } else { "postgres" }
$PostgresDb = if ($env:POSTGRES_DB) { $env:POSTGRES_DB } else { "n8n" }
$PostgresUser = if ($env:POSTGRES_USER) { $env:POSTGRES_USER } else { "n8n" }


# --- User Interaction ---
Write-Host "Please select a backup to restore from:"
$BackupFolders = Get-ChildItem -Path $BackupDir -Directory | Sort-Object Name -Descending
if ($BackupFolders.Count -eq 0) {
    Write-Host -ForegroundColor Red "No valid backup folders found in '$BackupDir'."
    exit 1
}

for ($i = 0; $i -lt $BackupFolders.Count; $i++) {
    Write-Host ("{0,3}: {1}" -f ($i + 1), $BackupFolders[$i].Name)
}

$selection = 0
while ($selection -lt 1 -or $selection -gt $BackupFolders.Count) {
    try {
        $input = Read-Host "Enter the number of the backup"
        $selection = [int]$input
        if ($selection -lt 1 -or $selection -gt $BackupFolders.Count) {
            Write-Host -ForegroundColor Yellow "Invalid selection. Please try again."
        }
    }
    catch {
        Write-Host -ForegroundColor Yellow "Invalid input. Please enter a number."
        $selection = 0
    }
}

$SelectedBackupFolder = $BackupFolders[$selection - 1]
$SelectedBackupDir = $SelectedBackupFolder.FullName
Write-Host -ForegroundColor Green "You have selected: $($SelectedBackupFolder.Name)"

$N8nDbBackupFile = Join-Path -Path $SelectedBackupDir -ChildPath "n8n_database.sql.gz"
$N8nBackupFile = Join-Path -Path $SelectedBackupDir -ChildPath "n8n_files.tar.gz"
$ClientDbBackupDir = Join-Path -Path $SelectedBackupDir -ChildPath "client_databases"

Write-Host "Checking for required files in $($SelectedBackupFolder.Name)..."
if (-not (Test-Path -Path $N8nDbBackupFile -PathType Leaf) -or -not (Test-Path -Path $N8nBackupFile -PathType Leaf)) {
    Write-Host -ForegroundColor Red "Error: n8n backup is incomplete. Missing database or data file in $SelectedBackupDir"
    exit 1
}
if (-not (Test-Path -Path $ClientDbBackupDir -PathType Container)) {
    Write-Host -ForegroundColor Yellow "Warning: Client database backup directory '$ClientDbBackupDir' not found. Skipping client DB restore."
}

# Confirmation Prompt
Write-Host "`n"
Write-Host -ForegroundColor Yellow "WARNING: This will stop your n8n services, overwrite the current data, and restart the entire stack. This action is irreversible."
$confirmation = Read-Host "Are you sure you want to proceed with the restore? (y/n)"
if ($confirmation -notmatch '^[Yy1]') {
    Write-Host "Restore cancelled."
    exit 0
}

# --- Restore Process ---
Write-Host "`n--- Starting Restore Process ---"
Set-Location -Path $ProjectRoot

# --- Step 1: Stop stack and destroy old volumes ---
Write-Host "`n🛑 Stopping n8n stack and removing existing volumes..."
podman pod stop $PodName --ignore -ErrorAction Ignore
podman pod rm $PodName --force -ErrorAction Ignore

$volumesToRemove = podman volume ls --format "{{.Name}}" | Where-Object { $_ -match "${ProjectName}_" }
if ($null -ne $volumesToRemove) {
    $volumesToRemove | ForEach-Object {
        Write-Host "   -> Removing volume $_"
        podman volume rm -f $_
    }
}
Write-Host "✅ Stack stopped and volumes removed."

# --- Step 2: Restore n8n Data Volume ---
Write-Host "`nRestoring n8n data to new volume '$N8nDataVolumeName'..."
podman volume create $N8nDataVolumeName

podman run --rm `
    -v "${N8nDataVolumeName}:/volume-data:z" `
    -v "${N8nBackupFile}:/backup/archive.tar.gz:ro,z" `
    docker.io/alpine `
    tar -xzpf /backup/archive.tar.gz -C /volume-data

Write-Host "✅ n8n data volume restore complete."

# --- Step 3: Restore n8n Database ---
Write-Host "`nStep 3: Restoring n8n database..."
Write-Host "Starting PostgreSQL service to receive data..."
podman compose -p $ProjectName -f $ComposeFile up -d $PostgresHost

$containerName = "n8n-${PostgresHost}"
Write-Host "Waiting for n8n PostgreSQL ('$containerName') to be healthy..."
$timeoutSeconds = 120
$startTime = Get-Date

while ($true) {
    if ((Get-Date) - $startTime -gt [TimeSpan]::FromSeconds($timeoutSeconds)) {
        Write-Host -ForegroundColor Red "`nTimeout reached. PostgreSQL container '$containerName' did not become healthy."
        exit 1
    }

    $status = podman inspect --format "{{.State.Health.Status}}" $containerName -ErrorAction SilentlyContinue
    if ($status -eq "healthy") {
        Write-Host "`n✅ n8n PostgreSQL is healthy."
        break
    }
    
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 2
}

Write-Host "Importing n8n database from '$N8nDbBackupFile'..."

podman run --rm -i -v "${N8nDbBackupFile}:/backup.sql.gz:ro" docker.io/alpine sh -c "gunzip -c /backup.sql.gz" | `
    podman exec -i --user postgres `
    $containerName `
    pg_restore -U $PostgresUser -d $PostgresDb --clean --if-exists --exit-on-error

Write-Host "✅ n8n Database import complete."

# --- Step 3b: Restore Independent Client Databases ---
if (Test-Path -Path $ClientDbBackupDir -PathType Container) {
    Write-Host "`nStep 3b: Restoring databases for independent container: '$PostgresHostCd'..."
    
    $clientContainerName = $PostgresHostCd
    $isRunning = $false
    try {
        if (podman container exists $clientContainerName) {
            $isRunning = (podman inspect --format '{{.State.Running}}' $clientContainerName) -eq 'true'
        }
    }
    catch {
        $isRunning = $false
    }

    if (-not $isRunning) {
        Write-Host -ForegroundColor Red "  -> Error: Client DB container '$clientContainerName' is not running. Skipping client DB restore."
    }
    else {
        Write-Host "  -> '$clientContainerName' is running. Proceeding with restore."
        $ClientDbFiles = Get-ChildItem -Path $ClientDbBackupDir -Filter "*.sql.gz" -File
        
        if ($ClientDbFiles.Count -eq 0) {
            Write-Host -ForegroundColor Yellow "  -> Warning: No database dump files found in '$ClientDbBackupDir'. Skipping."
        }
        else {
            foreach ($DbFile in $ClientDbFiles) {
                $DbName = $DbFile.Name.Replace('.sql.gz', '')
                $DbPath = $DbFile.FullName
                Write-Host "  -> Restoring database: '$DbName'"

                "DROP DATABASE IF EXISTS `"$DbName`";" | podman exec -i --user postgres $clientContainerName psql -U postgres
                "CREATE DATABASE `"$DbName`" OWNER `"$PostgresUserCd`";" | podman exec -i --user postgres $clientContainerName psql -U postgres

                try {
                    podman run --rm -i -v "${DbPath}:/backup.sql.gz:ro" docker.io/alpine sh -c "gunzip -c /backup.sql.gz" | `
                        podman exec -i --user postgres `
                        $clientContainerName `
                        pg_restore -U $PostgresUserCd -d $DbName --clean --if-exists --exit-on-error
                    Write-Host -ForegroundColor Green "    -> Success: Database '$DbName' restored."
                }
                catch {
                    Write-Host -ForegroundColor Red "    -> ERROR: Failed to restore database '$DbName'."
                }
            }
        }
    }
    Write-Host "✅ Independent database restore process finished."
}

# --- Step 4: Restart the Full Stack ---
Write-Host "`n🚀 Starting the full n8n stack..."

$N8nWorkerScale = if ($env:N8N_WORKER_SCALE -and ($env:N8N_WORKER_SCALE -as [int])) {
    [int]$env:N8N_WORKER_SCALE
}
else {
    2
}

podman compose -p $ProjectName -f $ComposeFile up -d --scale n8n-worker=$N8nWorkerScale

Write-Host "`n"
Write-Host -ForegroundColor Green "Restore successfully completed!"
Write-Host "Your n8n instance is now running with the restored data."
Write-Host -ForegroundColor Green "Access it here: http://localhost:5678"