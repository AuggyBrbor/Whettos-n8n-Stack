<#
.SYNOPSIS
    A non-disruptive script to back up a running n8n podman stack on Windows.
.DESCRIPTION
    This script creates a full backup of the n8n PostgreSQL database, the n8n data volume,
    and all databases from an independent client data container. It also exports all workflows
    and credentials, applying custom modifications to the workflow files.
    It is intended to be run from the project root directory.
#>
[CmdletBinding()]
param()

# Exit immediately if a command exits with a non-zero status.
$ErrorActionPreference = "Stop"

# --- Configuration ---
# Correctly define the Project Root as the parent directory of the script's location.
$ProjectRoot = (Get-Item -Path $PSScriptRoot).Parent.FullName
$BackupDir = Join-Path -Path $ProjectRoot -ChildPath "backups"
$ComposeFile = Join-Path -Path $ProjectRoot -ChildPath "fedora\podman-compose.yml"
$EnvFile = Join-Path -Path $ProjectRoot -ChildPath ".env"

$ClientDbContainerName = "clientData"
$ClientDbUser = "admin"

# --- Pre-flight Checks ---
Write-Host "🚀 Running pre-flight checks..."

# More resilient check: Iterate through each path directory to find podman.exe
$podmanFound = $false
$pathDirectories = $env:PATH -split ';'

foreach ($dir in $pathDirectories) {
    if ([string]::IsNullOrWhiteSpace($dir)) {
        continue
    }
    $potentialPath = Join-Path -Path $dir.Trim() -ChildPath "podman.exe"
    if (Test-Path -Path $potentialPath -PathType Leaf) {
        $podmanFound = $true
        break
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

# Check for required files
if (-not (Test-Path -Path $ComposeFile -PathType Leaf)) {
    Write-Host -ForegroundColor Red "❌ Error: Compose file not found at '$ComposeFile'. Please ensure the script is in a subdirectory of the project root."
    exit 1
}
if (-not (Test-Path -Path $EnvFile -PathType Leaf)) {
    Write-Host -ForegroundColor Red "❌ Error: '$EnvFile' not found in the project root. Cannot proceed without credentials."
    exit 1
}
New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null
Write-Host "✅ Pre-flight checks passed."


# --- Main Logic ---
Write-Host "`n--- Starting Live Backup: $(Get-Date) ---"

# Source environment variables from the .env file
if (Test-Path -Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^\s*([^#\s=]+)\s*=\s*"?([^"]*)"?\s*$') {
            [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
}

# Validate required variables
if ([string]::IsNullOrWhiteSpace($env:POSTGRES_USER) -or [string]::IsNullOrWhiteSpace($env:POSTGRES_DB)) {
    Write-Host -ForegroundColor Red "❌ Error: Required database variables (POSTGRES_USER, POSTGRES_DB) are not set in the .env file."
    exit 1
}
# Set defaults
$RetentionDays = if ($env:BACKUP_RETENTION_DAYS) { [int]$env:BACKUP_RETENTION_DAYS } else { 7 }
$CopyrightName = if ($env:COPYRIGHT_NAME) { $env:COPYRIGHT_NAME } else { "Auggy Brbor" }

# 1. Ensure n8n services are running for the backup
Write-Host "`n🔎 Verifying that core n8n containers are running..."
$containersToCheck = @("n8n-postgres", "n8n-main")
$stackIsRunning = $true
foreach ($c in $containersToCheck) {
    try {
        if ((podman inspect --format '{{.State.Running}}' $c) -ne 'true') {
            $stackIsRunning = $false; break
        }
    }
    catch {
        $stackIsRunning = $false; break
    }
}

if (-not $stackIsRunning) {
    Write-Host "⚠️ A core container not found or not running. Starting the stack..."
    podman compose -f $ComposeFile up -d
    Write-Host "Waiting for services to initialize..."
    Start-Sleep -Seconds 15
}
Write-Host "✅ Core n8n containers are running."

# 2. Create timestamped backup directory
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$CurrentBackupDir = Join-Path -Path $BackupDir -ChildPath "backup_$Timestamp"
$N8nDbBackupFile = Join-Path -Path $CurrentBackupDir -ChildPath "n8n_database.sql.gz"
$N8nBackupFile = Join-Path -Path $CurrentBackupDir -ChildPath "n8n_files.tar.gz"
$ClientDbBackupDir = Join-Path -Path $CurrentBackupDir -ChildPath "client_databases"
$WorkflowDir = Join-Path -Path $CurrentBackupDir -ChildPath "workflows"
$CredsDir = Join-Path -Path $CurrentBackupDir -ChildPath "creds"
New-Item -Path $ClientDbBackupDir -ItemType Directory -Force | Out-Null
New-Item -Path $WorkflowDir -ItemType Directory -Force | Out-Null
New-Item -Path $CredsDir -ItemType Directory -Force | Out-Null

# 3. Backup n8n PostgreSQL Database
Write-Host "`n⏳ Backing up n8n PostgreSQL database..."
# FIX: Use double-double quotes to ensure the path is correctly quoted for cmd.exe
$dbDumpCommand = "podman exec --user postgres n8n-postgres pg_dump -U $($env:POSTGRES_USER) -d $($env:POSTGRES_DB) -F c | podman run --rm -i docker.io/alpine gzip > ""$N8nDbBackupFile"""
cmd /c $dbDumpCommand
Write-Host "✅ n8n Database backup complete: $N8nDbBackupFile"

# 3b. Backup Independent Client Databases
Write-Host "`n⏳ Backing up all databases in independent container: $ClientDbContainerName..."
# FIX: Use the more robust try/catch block to check if the container is running
$clientDbIsRunning = $true
try {
    if ((podman inspect --format '{{.State.Running}}' $ClientDbContainerName) -ne 'true') {
        $clientDbIsRunning = $false
    }
}
catch {
    $clientDbIsRunning = $false
}

if (-not $clientDbIsRunning) {
    Write-Host -ForegroundColor Red "  -> ❌ Error: Independent database container '$ClientDbContainerName' not found or not running. Skipping this backup."
}
else {
    Write-Host "  -> Listing user databases in $ClientDbContainerName..."
    $databases = podman exec --user postgres $ClientDbContainerName psql -U postgres -l -t | ForEach-Object {
        $dbName = ($_ -split '\|')[0].Trim()
        if ($dbName -and $dbName -notmatch '^(template[01]|postgres)$') {
            $dbName
        }
    }

    if (-not $databases) {
        Write-Host -ForegroundColor Yellow "  -> ⚠️ No user databases found to export from $ClientDbContainerName. Skipping."
    }
    else {
        Write-Host "  -> The following databases will be exported:"
        $databases | ForEach-Object { Write-Host "     $_" }

        foreach ($db in $databases) {
            $fileName = Join-Path -Path $ClientDbBackupDir -ChildPath "$db.sql.gz"
            Write-Host "  -> Dumping database: $db to $fileName"
            try {
                # FIX: Use double-double quotes here as well
                $clientDumpCommand = "podman exec $ClientDbContainerName pg_dump -U $ClientDbUser -d $db -F c | podman run --rm -i docker.io/alpine gzip > ""$fileName"""
                cmd /c $clientDumpCommand
                Write-Host "    -> Success."
            }
            catch {
                Write-Host -ForegroundColor Red "    -> ERROR: Failed to dump database $db. Check if user '$ClientDbUser' has access."
            }
        }
        Write-Host "✅ All client database backups complete: $ClientDbBackupDir"
    }
}

# 4. Backup n8n Data Volume and Export Workflows/Credentials
Write-Host "`n⏳ Backing up n8n data volume and exporting assets..."
# FIX: Use double-double quotes here as well
$volumeDumpCommand = "podman exec n8n-main tar -czpf - -C /home/node/.n8n . > ""$N8nBackupFile"""
cmd /c $volumeDumpCommand
Write-Host "✅ Data volume backup complete: $N8nBackupFile"

# Export workflows and credentials from the container
# FIX: Removed unnecessary -it flags
podman exec -u node n8n-main n8n export:workflow --backup --output=backups/latest/workflows
podman cp "n8n-main:/home/node/backups/latest/workflows/." "$WorkflowDir"
podman exec -u node n8n-main rm -rf ./backups/latest/workflows

podman exec -u node n8n-main n8n export:credentials --backup --output=backups/latest/creds
podman cp "n8n-main:/home/node/backups/latest/creds/." "$CredsDir"
podman exec -u node n8n-main rm -rf ./backups/latest/creds
Write-Host "✅ Workflows and credentials exported."

# 5. Skip SELinux on non-Linux
Write-Host "`n⏳ Restoring SELinux contexts for backup files..."
Write-Host "   -> Skipped: 'restorecon' is a Linux-specific command."

# 6. Apply Custom Modifications to Workflow JSONs
Write-Host "`n🔧 Applying modifications to workflow JSON files..."
$CopyrightHolder = "© ${CopyrightName}"
$note_content = @"
&nbsp;
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

Happy automating!
"@

$noteNode = [PSCustomObject]@{
    parameters  = [PSCustomObject]@{
        content = "${note_content}-${CopyrightName}"
        height  = 1328
        width   = 320
        color   = 6
    }
    type        = "n8n-nodes-base.stickyNote"
    position    = @(80, 80)
    typeVersion = 1
    id          = "1a6be635-d047-4687-be08-1c30d0a6c2f1"
    name        = $CopyrightHolder
}

$workflowFiles = Get-ChildItem -Path $WorkflowDir -Filter "*.json" -File -Recurse
if (-not $workflowFiles) {
    Write-Host "  -> Skipping: No workflow files were found in the backup directory."
}
else {
    Write-Host "  -> Scanning for .json files in $WorkflowDir..."
    foreach ($file in $workflowFiles) {
        Write-Host "    - Processing: $($file.FullName)"
        try {
            # Use -Encoding UTF8 to prevent issues with special characters in workflows
            $workflow = Get-Content -Path $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            
            if ($null -eq $workflow.id -or $null -eq $workflow.nodes -or -not $workflow.nodes.GetType().IsArray) {
                Write-Host -ForegroundColor Yellow "      -> Skipping: File does not have the required structure."
                continue
            }

            $noteExists = $false
            foreach ($node in $workflow.nodes) {
                if ($node.name -eq $CopyrightHolder) {
                    $noteExists = $true
                    break
                }
            }

            if (-not $noteExists) {
                $workflow.nodes = @($noteNode) + $workflow.nodes
                $workflow | ConvertTo-Json -Depth 10 | Set-Content -Path $file.FullName -Encoding UTF8
                Write-Host "      -> Success: File has been modified."
            }
            else {
                Write-Host "      -> Skipping: Copyright note already exists."
            }
        }
        catch {
            Write-Host -ForegroundColor Red "      -> Error: Failed to process JSON in this file. Original remains untouched."
        }
    }
}
Write-Host "✅ JSON modifications complete."

# 7. Prune Old Backups
Write-Host "`n🧹 Pruning backups older than $RetentionDays days..."
Get-ChildItem -Path $BackupDir -Directory -Filter "backup_*" | Where-Object {
    $_.CreationTime -lt (Get-Date).AddDays(-$RetentionDays)
} | ForEach-Object {
    Write-Host "  - Removing old backup: $_"
    Remove-Item -Path $_.FullName -Recurse -Force
}
Write-Host "✅ Pruning complete."

Write-Host "`n🎉 Backup process finished successfully!"