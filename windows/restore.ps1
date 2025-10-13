<#
.SYNOPSIS
A Windows PowerShell script to execute the Podman-based n8n and clientData
restore logic within WSL (Windows Subsystem for Linux).

.DESCRIPTION
This script finds the project root by navigating up two directories (from the
'windows' folder), translates the path, and executes the Linux-based 
'restore_wsl.sh' script in WSL, ensuring all file paths are correctly mapped.

.PARAMETER WslDistroName
Optional. The name of the WSL distribution to use (e.g., Ubuntu, Fedora-36).
Defaults to 'Ubuntu'.

.NOTES
Assumes structure: project root/windows/restore.ps1
#>
param(
    [string]$WslDistroName = "Ubuntu"
)

# Exit immediately if any command fails
$ErrorActionPreference = "Stop"

# --- Configuration ---
$RestoreScriptName = "restore_wsl.sh" 
$WslDistro = $WslDistroName

# Get the directory of the currently executing PowerShell script (e.g., C:\ProjectRoot\windows)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Calculate ProjectRoot: Go up two levels (from 'windows' to 'project root')
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)

# Check if the restore_wsl.sh file exists in the expected location
$RestoreScriptPath = Join-Path -Path $ScriptDir -ChildPath $RestoreScriptName
if (-not (Test-Path $RestoreScriptPath)) {
    Write-Error "Error: The required Linux script '$RestoreScriptName' was not found at '$RestoreScriptPath'. Please ensure it is in the same directory as restore.ps1."
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
# The shell script is located at $WslProjectRoot/windows/restore_wsl.sh
$WslRestoreScript = Get-WslPath -Path $RestoreScriptPath 
# Escape spaces in the path for safe execution in bash
$WslRestoreScriptEscaped = $WslRestoreScript.Replace(" ", "\ ")

# --- Main Logic ---
Write-Host "🚀 Starting Podman restore script execution inside WSL ($WslDistro)..."
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
Write-Host "`n⏳ Executing $RestoreScriptName..."

try {
    # Navigate to the project root in the WSL terminal and then execute the script using its absolute path.
    # This setup ensures the script's internal logic correctly resolves all files.
    $command = "cd $WslProjectRoot; /bin/bash $WslRestoreScriptEscaped"
    
    # Execute the command inside the WSL distribution
    wsl.exe -d $WslDistro -e bash -c $command
    
    # Check the last exit code from the WSL process
    if ($LASTEXITCODE -ne 0) {
        Write-Error "❌ Restore script failed inside WSL with exit code $LASTEXITCODE."
        exit 1
    }

    Write-Host "`n🎉 Restore process finished successfully inside WSL."

} catch {
    Write-Error "A PowerShell error occurred during WSL execution: $($_.Exception.Message)"
    exit 1
}