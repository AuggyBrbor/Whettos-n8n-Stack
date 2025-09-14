# This script creates a new n8n instance and imports workflows from the '/imports' directory on Windows.
# It should be run from the root directory of the toolkit.

# --- Configuration ---
$ComposeFile = ".\windows\podman-compose.yml"
$EnvFile = ".\.env"
$EnvTemplate = ".\.env.template"
$ImportsDir = ".\imports"
$ContainerName = "n8n-main"

# --- Pre-flight Checks ---
Write-Host "--- Running Pre-flight Checks ---" -ForegroundColor Cyan

# Check for required commands
$podmanExists = Get-Command podman -ErrorAction SilentlyContinue
$podmanComposeExists = Get-Command podman-compose -ErrorAction SilentlyContinue
if (-not $podmanExists) {
    Write-Host "Error: 'podman' not found." -ForegroundColor Red; exit 1
}
if (-not $podmanComposeExists) {
    Write-Host "Error: 'podman-compose' not found." -ForegroundColor Red; exit 1
}

# Check for .env file
if (-not (Test-Path $EnvFile)) {
    Write-Host "Warning: '$EnvFile' not found. Copying from template." -ForegroundColor Yellow
    Copy-Item $EnvTemplate $EnvFile
    Write-Host "Please edit the '$EnvFile' file, then re-run this script." -ForegroundColor Yellow
    exit 1
}

# Check for required variables in .env
$envContent = Get-Content $EnvFile -Raw
$envVars = $envContent | ConvertFrom-StringData -Delimiter '='
if (-not $envVars.POSTGRES_PASSWORD -or $envVars.POSTGRES_PASSWORD -eq 'YourSuperSecretPassword') {
    Write-Host "Error: POSTGRES_PASSWORD not set in .env." -ForegroundColor Red; exit 1
}
if (-not $envVars.N8N_E_KEY -or $envVars.N8N_E_KEY -eq 'YourGenerated32CharacterEncryptionKey') {
    Write-Host "Error: N8N_E_KEY not set in .env." -ForegroundColor Red; exit 1
}

# Check if imports directory exists and has JSON files
if (-not (Test-Path $ImportsDir) -or -not (Get-ChildItem -Path $ImportsDir -Filter *.json)) {
    Write-Host "Error: The '$ImportsDir' directory does not exist or contains no .json files." -ForegroundColor Red
    Write-Host "Please add your workflow files to the '$ImportsDir' directory and try again."
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

if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Deployment failed. Check the output above." -ForegroundColor Red
    exit 1
}

Write-Host "Services started successfully." -ForegroundColor Green
Write-Host ""

# --- Workflow Import ---
Write-Host "--- Importing Workflows ---" -ForegroundColor Cyan
Write-Host "Waiting for n8n container to be ready..."
Start-Sleep -Seconds 15

Write-Host "Copying workflows to container..."
podman cp $ImportsDir "$($ContainerName):/home/node/.n8n/imports"

Write-Host "Running import script inside the container..."
$importCommand = "cd /home/node/.n8n/imports && for file in *.json; do echo 'Importing workflow: \$file' && n8n import:workflow --input=\"`$file`\"; done"
podman exec $ContainerName sh -c $importCommand

Write-Host "Cleaning up import files from container..."
podman exec $ContainerName rm -rf /home/node/.n8n/imports

Write-Host "Workflow import process complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Your n8n instance should be available at:"
Write-Host "➡️  http://localhost:5678" -ForegroundColor Green
Write-Host ""
Write-Host "Your Ollama API is available at:"
Write-Host "➡️  http://localhost:11434" -ForegroundColor Green
