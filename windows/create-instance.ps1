# This script creates a new, empty n8n instance using Podman on Windows.
# It should be run from the root directory of the toolkit.

# --- Configuration ---
$ComposeFile = ".\windows\podman-compose.yml"
$EnvFile = ".\.env"
$EnvTemplate = ".\.env.template"

# --- Pre-flight Checks ---
Write-Host "--- Running Pre-flight Checks ---" -ForegroundColor Cyan

# Check for required commands
$podmanExists = Get-Command podman -ErrorAction SilentlyContinue
$podmanComposeExists = Get-Command podman-compose -ErrorAction SilentlyContinue

if (-not $podmanExists) {
    Write-Host "Error: Command 'podman' not found. Please install it and ensure it's in your PATH." -ForegroundColor Red
    exit 1
}
if (-not $podmanComposeExists) {
    Write-Host "Error: Command 'podman-compose' not found. Please install it." -ForegroundColor Red
    exit 1
}

# Check for .env file
if (-not (Test-Path $EnvFile)) {
    Write-Host "Warning: '$EnvFile' not found." -ForegroundColor Yellow
    Write-Host "Copying from '$EnvTemplate'..."
    Copy-Item $EnvTemplate $EnvFile
    Write-Host "Please edit the '$EnvFile' file with your credentials, then re-run this script." -ForegroundColor Yellow
    exit 1
}

# Check for required variables in .env
$envContent = Get-Content $EnvFile -Raw
$envVars = $envContent | ConvertFrom-StringData -Delimiter '='

if (-not $envVars.POSTGRES_PASSWORD -or $envVars.POSTGRES_PASSWORD -eq 'YourSuperSecretPassword') {
    Write-Host "Error: POSTGRES_PASSWORD is not set in the .env file. Please update it." -ForegroundColor Red
    exit 1
}
if (-not $envVars.N8N_E_KEY -or $envVars.N8N_E_KEY -eq 'YourGenerated32CharacterEncryptionKey') {
    Write-Host "Error: N8N_E_KEY is not set in the .env file. Please update it." -ForegroundColor Red
    exit 1
}

Write-Host "Pre-flight checks passed!" -ForegroundColor Green
Write-Host ""

# --- Deployment ---
Write-Host "--- Starting Deployment ---" -ForegroundColor Cyan
Write-Host "Pulling the latest container images..."
podman-compose -f $ComposeFile pull

Write-Host "Starting the services... (This may take a moment)"
podman-compose -f $ComposeFile up -d

if ($LASTEXITCODE -eq 0) {
    Write-Host "Deployment successful!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Your n8n instance should be available at:"
    Write-Host "➡️  http://localhost:5678" -ForegroundColor Green
    Write-Host ""
    Write-Host "Your Ollama API is available at:"
    Write-Host "➡️  http://localhost:11434" -ForegroundColor Green
} else {
    Write-Host "Error: Deployment failed. Check the output above for details." -ForegroundColor Red
    Write-Host "You can view logs using: podman-compose -f $ComposeFile logs"
}
