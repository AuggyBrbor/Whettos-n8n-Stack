<#
.SYNOPSIS
A Windows PowerShell script to execute the Podman-based n8n and clientData
backup logic within WSL (Windows Subsystem for Linux).

.DESCRIPTION
This script finds the project root by navigating up two directories (from the
'windows' folder), translates the path, and executes the Linux-based 
'backup_wsl.sh' script in WSL.

.PARAMETER WslDistroName
Optional. The name of the WSL distribution to use (e.g., Ubuntu, Fedora-36).
Defaults to 'Ubuntu'.

.NOTES
Assumes structure: project root/windows/backup.ps1
#>
param(
    [string]$WslDistroName = "Ubuntu"
)

# Exit immediately if any command fails
$ErrorActionPreference = "Stop"

# --- Configuration ---
$BackupScriptName = "backup_wsl.sh" 
$WslDistro = $WslDistroName

# Get the directory of the currently executing PowerShell script (e.g., C:\ProjectRoot\windows)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Calculate ProjectRoot: Go up two levels (from 'windows' to 'project root')
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

# Check if the backup_wsl.sh file exists in the expected location
$BackupScriptPath = Join-Path -Path $ScriptDir -ChildPath $BackupScriptName
if (-not (Test-Path $BackupScriptPath)) {
    Write-Error "Error: The required Linux script '$BackupScriptName' was not found at '$BackupScriptPath'. Please ensure it is in the same directory as backup.ps1."
    exit 1
}

# Function to translate Windows paths to WSL (Linux) paths
function Get-WslPath {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )
    # Use wsl.exe wslpath for the most reliable conversion
    try {
        $wslPath = (wsl.exe wslpath -u $Path -d $WslDistro | Out-String).Trim()
        return $wslPath
    } catch {
        # Fallback for older systems or if wslpath fails
        Write-Warning "wslpath command failed. Falling back to manual path conversion."
        $driveLetter = $Path.Substring(0, 1).ToLower()
        $remainingPath = $Path.Substring(2).Replace(':', '').Replace('\', '/')
        $wslPath = "/mnt/$driveLetter$remainingPath"
        return $wslPath
    }
}

$WslProjectRoot = Get-WslPath -Path $ProjectRoot
# The shell script is located at $WslProjectRoot/windows/backup_wsl.sh
$WslBackupScript = Get-WslPath -Path $BackupScriptPath 
# Escape spaces in the path for safe execution in bash
$WslBackupScriptEscaped = $WslBackupScript.Replace(" ", "\ ")

# --- Main Logic ---
Write-Host "🚀 Starting Podman backup script execution inside WSL ($WslDistro)..."
Write-Host "Project Root (Windows): $ProjectRoot"
Write-Host "Project Root (WSL): $WslProjectRoot"
Write-Host ""

# 1. Ensure WSL is running
Write-Host "🔎 Ensuring WSL is running..."
try {
    wsl.exe -d $WslDistro -e true 
    Write-Host "✅ WSL is running."
} catch {
    Write-Error "Error starting WSL. Check your WSL installation and distro name: $($_.Exception.Message)"
    exit 1
}

# 2. Execute the Linux script inside WSL
Write-Host "`n⏳ Executing $BackupScriptName..."

try {
    # We cd to the project root first, but then execute the script using its absolute path.
    $command = "cd $WslProjectRoot; /bin/bash $WslBackupScriptEscaped"
    
    # Execute the command inside the WSL distribution
    wsl.exe -d $WslDistro -e bash -c $command
    
    # Check the last exit code from the WSL process
    if ($LASTEXITCODE -ne 0) {
        Write-Error "❌ Backup script failed inside WSL with exit code $LASTEXITCODE."
        exit 1
    }

    Write-Host "`n🎉 Backup process finished successfully inside WSL."
    Write-Host "Backup files are located at: $ProjectRoot\backups"

} catch {
    Write-Error "A PowerShell error occurred during WSL execution: $($_.Exception.Message)"
    exit 1
}