# n8n Podman Toolkit

This toolkit provides a complete set of scripts and configuration files to deploy, manage, and back up a scalable n8n instance using Podman and podman-compose. It includes tailored configurations for both **Windows 11 (with WSL2)** and **Fedora 42 Workstation**.

The stack includes:
- **n8n Main**: The primary n8n service for the UI, API, and workflow management.
- **n8n Worker**: A scalable worker service for executing workflows.
- **PostgreSQL**: The database for persisting n8n data.
- **Redis**: A message broker for queuing workflow executions.
- **Ollama**: A service for running local large language models.
- **ollama-setup**: A one-time setup service to automatically download a default LLM.
- **n8n-mcp**: A Model Control Plane server that uses an LLM to manage your n8n instance via its API.


## File Structure
```
. [ Project root folder ]
├── .env.template                        # Template for environment variables
├── backups/                             # Backup files will be stored here
├── fedora/
│   ├── backup.sh                        # run from root project directory via ./fedora/backup.sh
│   ├── create-instance.sh               # run from root project directory via ./fedora/create-instance.sh
│   ├── create-instance-with-imports.sh  # run from root project directory via ./fedora/create-instance-with-imports.sh
│   ├── restore.sh                       # run from root project directory via ./fedora/restore.sh
│   └── podman-compose.yml               # spun up from root project directory by copying there and using podman-compose up -d --scale n8n-worker=2
├── imports/
│   └── sample_workflow.json             # Place workflow .json files here for import script(s) to pull from
├── README.md                            # This documentation file
└── windows/
    ├── backup.ps1
    ├── create-instance.ps1
    ├── create-instance-with-imports.ps1
    ├── restore.ps1
    └── podman-compose.yml
```

---

- **`/fedora`**: Contains the `podman-compose.yml` and management scripts specifically for a Fedora 42 environment. These use SELinux labels and Linux-style commands.
- **`/windows`**: Contains the `podman-compose.yml` and management scripts for a Windows 11 environment. These are written in PowerShell and are adapted for a Podman setup using WSL2.
- **`/imports`**: A directory where you should place any workflow `.json` files that you wish to import automatically upon instance creation (with the appropriate script).
- **`.env.template`**: A template file for your secret credentials and configuration.

## 1. Prerequisites

Before you begin, ensure you have the following installed on your system:

-   **Podman**: The container engine.
-   **podman-compose**: The Compose tool for Podman.

---

## 1. Initial Setup (Required)

You must configure your environment variables and generate an n8n API key before running any scripts.

1.  **Create your `.env` file**: In the root directory of the toolkit, make a copy of the `.env.template` file and name it `.env`.

    -   **Windows (PowerShell):**
        ```powershell
        Copy-Item .env.template .env
        ```
    -   **Fedora (Bash):**
        ```bash
        cp .env.template .env
        ```

2.  **Edit the `.env` file**: Open the new `.env` file and fill in the required values. At a minimum, you **must** set `POSTGRES_PASSWORD` and `N8N_E_KEY`. The `N8N_API_KEY` can be left blank for now; you will generate it in the next step.

3.  **Generate and Add the n8n API Key**:

    a. Launch the n8n stack for the first time by running the appropriate `create-instance` script from the root directory (e.g., `./fedora/create-instance.sh`).

    b. Open your browser and go to **`http://localhost:5678`**.

    c. Complete the initial n8n owner account setup.

    d. In the n8n UI, go to **Settings -> API**.

    e. Click **"Add API key"**. Give it a name (e.g., "mcp-key") and click **"Create"**.

    f. **Immediately copy the generated API key**.

    g. Open your `.env` file and paste the copied key as the value for the `N8N_API_KEY` variable.

    h. Restart the entire stack to apply the new environment variable:
       
       ```bash
       # Example for Fedora. Use the appropriate compose file for your OS.
       podman-compose -f ./fedora/podman-compose.yml down && podman-compose -f ./fedora/podman-compose.yml up -d
       ```

---

## 2. How to Use the Toolkit

All scripts should be run from the project root directory (`n8n-podman/`).

### AI-Powered Workflow Management (n8n-mcp)

This stack is configured to use the **n8n-mcp** server. You can give it natural language commands, and it will use a local LLM to create, modify, or describe workflows on your behalf.

-   **Automatic Setup**: When you launch the stack, the `ollama-setup` service automatically downloads a powerful default model. The `n8n-mcp` service will start and connect to both Ollama and your n8n API.
-   **How to Use**: You interact with the `n8n-mcp` server by sending `POST` requests to its API endpoint at `http://localhost:8000/agent/invoke`.

    **Example: Creating a new workflow using `curl`**
    
    Open a terminal and run the following command to ask the agent to create a simple webhook-based workflow:
    ```bash
    curl -X POST http://localhost:8000/agent/invoke \
    -H "Content-Type: application/json" \
    -d '{
        "input": "Create a new workflow. The workflow should be triggered by a webhook. The webhook should respond with a message that says ''hello world''",
        "config": {},
        "kwargs": {}
    }'
    ```

    After a few moments, the LLM will process this, and you will see a new workflow appear in your n8n UI.

#### Connecting to Ollama in an n8n Node

You can also connect directly to the Ollama service from within an n8n workflow, which is useful for community nodes like `n8n-nodes-ollama` or for making direct HTTP requests.

-   **How it Works**: Because all services are on the same container network, they can communicate using their service names.
-   **Ollama Base URL**: When configuring a node inside n8n, use the following URL to connect to the Ollama service:
    ```
    http://ollama:11434
    ```
    This provides a simple way to send prompts to your local LLM as part of any automation.

### Creating, Importing, and Restoring

The scripts for creating a new instance, importing workflows from the `/imports` folder, and restoring from a backup function as described below. Always ensure your `.env` file is correctly configured before running them.

#### **Creating a New n8n Instance**

These scripts will set up a fresh n8n instance, including all AI and backup services.

-   **On Windows:**
    ```powershell
    .\windows\create-instance.ps1
    ```
-   **On Fedora:**
    ```bash
    chmod +x ./fedora/*.sh
    ./fedora/create-instance.sh
    ```

#### **Creating an Instance with Workflow Imports**

These scripts will create a new instance and automatically import all `.json` files found in the `/imports` directory.

1.  Place your workflow `.json` files into the `/imports` directory.
2.  Run the appropriate script for your OS:

-   **On Windows:**
    ```powershell
    .\windows\create-instance-with-imports.ps1
    ```

-   **On Fedora:**
    ```bash
    chmod +x ./fedora/*.sh
    ./fedora/create-instance-with-imports.sh
    ```

#### **Graceful Backups (Manual & Automated)**

**How it Works**: The `n8n-backup` script gracefully stops the n8n service(s) and saves a complete backup of your database and n8n data volume to the `./backups` directory and then resumes the stopped service(s).
-   A full SQL dump of the PostgreSQL database.
-   A compressed archive of the n8n data volume (containing workflows, credentials, etc.).

**Manual Backup**: Trigger a backup anytime with the command:

-   **On Windows:**
    ```powershell
    .\windows\backup.ps1
    ```
-   **On Fedora:**
    ```bash
    chmod +x ./fedora/*.sh
    ./fedora/backup.sh
    ```

**Automated Backup**: You can automate this process using your host system's scheduler (e.g., cron on Fedora, Task Scheduler on Windows) by pointing it to the appropriate backup script.

#### **Restoring from a Backup**

The restore scripts allow you to completely restore your n8n instance from a previously created backup.
> **WARNING:** This is a destructive action that will erase the current instance.

-   **On Windows:**
    ```powershell
    .\windows\restore.ps1
    ```
-   **On Fedora:**
    ```bash
    ./fedora/restore.sh
    ```

### Managing the Services

You can manage the services directly using standard `podman-compose` commands. Be sure to specify the correct compose file for your OS.

-   **Start/Stop Services:**

    -   **Windows:**
        ```powershell
        podman-compose -f .\windows\podman-compose.yml up -d
        ```

    -   **Fedora:**
        ```bash
        podman-compose -f ./fedora/podman-compose.yml up -d
        ```
    _Use `down` to stop and remove the containers._

-   **View Logs:**

    -   **Windows:**
        ```powershell
        podman-compose -f .\windows\podman-compose.yml logs -f n8n-main
        ```

    -   **Fedora:**
        ```bash
        podman-compose -f ./fedora/podman-compose.yml logs -f n8n-main
        ```

-   **Scale Workers:**

    -   **Windows:**
        ```powershell
        podman-compose -f .\windows\podman-compose.yml up -d --scale n8n-worker=3
        ```

    -   **Fedora:**
        ```bash
        podman-compose -f ./fedora/podman-compose.yml up -d --scale n8n-worker=3
        ```