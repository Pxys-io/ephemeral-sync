# Ephemeral Sync: Persistent Configuration for Ephemeral Machines

**Ephemeral Sync** is a lightweight, pure Bash script designed to solve the problem of losing configuration and settings on ephemeral machines. It runs in the background, watches specified files and directories, and automatically commits and pushes changes to a remote Git repository, allowing for easy restoration and quick setup on a new machine instance.

## Key Changes for Persistence

To ensure persistence across machine resets, all state files are now stored in the persistent `/workspace` directory:

| File | New Location (Persistent) | Purpose |
| :--- | :--- | :--- |
| **Configuration** | `/workspace/.ephemeral_sync_config` | Defines watch/ignore paths and remote URL. |
| **Git Repository** | `/workspace/.ephemeral_sync_repo` | Local clone of your configuration repository. |
| **Log File** | `/workspace/.ephemeral_sync.log` | Records all daemon activity and errors. |
| **PID File** | `/workspace/.ephemeral_sync.pid` | Tracks the running daemon process ID. |

## Features

*   **Pure Bash:** No external dependencies beyond standard Linux utilities.
*   **Background Daemon:** Runs silently in the background.
*   **Git-based Tracking:** Uses a local Git repository in `/workspace` to track changes.
*   **Configurable Watch/Ignore:** Uses `/workspace/.ephemeral_sync_config` for file patterns.
*   **First-Run Restoration:** Can automatically restore configurations from a remote Git repository or a zipped `.git` backup.
*   **Simplified Deployment:** The main script now handles the entire deployment process with a single command.

## Prerequisites

1.  **Git:** Must be installed and configured.
2.  **SSH Key:** If using a private remote repository, your SSH key must be added to the machine's SSH agent and authorized on the Git service.
3.  **Standard Utilities:** `rsync`, `wget`, `unzip`.

## Installation and First Run

### Step 1: Initial Setup (One-Time)

This step is to create your remote repository and commit the `ephemeral_sync.sh` script to it.

1.  **Save the Script:** Save the attached `ephemeral_sync.sh` script to your home directory.
    ```bash
    chmod +x ~/ephemeral_sync.sh
    ```

2.  **Configure:** Run the script once to create the default config file in the persistent workspace.
    ```bash
    ~/ephemeral_sync.sh status
    ```
    Now, **edit the configuration file** at `/workspace/.ephemeral_sync_config` to set your **remote Git URL** and define your `watch` paths (e.g., `.Claude/`).

3.  **Start & Push:** Run `~/ephemeral_sync.sh start`. This will initialize the Git repository in `/workspace/.ephemeral_sync_repo`, copy the script itself into the repo, commit, and push everything to your remote.

### Step 2: Quick Deployment on a New Machine (`curl | bash`)

Once the `ephemeral_sync.sh` script is in your remote repository, you can use the `deploy` command to set up any new ephemeral machine instantly.

1.  **Find the Raw URL:** Get the raw URL for the **`ephemeral_sync.sh`** file from your Git hosting service (e.g., GitHub, GitLab).
2.  **Execute the Deployment:**
    ```bash
    # Replace <RAW_URL_TO_ephemeral_sync.sh> with the actual raw URL
    # Replace <YOUR_REMOTE_URL> with the SSH or HTTPS URL of your Git repository
    curl -sL <RAW_URL_TO_ephemeral_sync.sh> | bash -s -- deploy <YOUR_REMOTE_URL>
    ```
    This single command will:
    *   Execute the script in `deploy` mode.
    *   Clone your configuration repository to `/workspace/.ephemeral_sync_repo`.
    *   Install the main `ephemeral_sync.sh` script to `/usr/local/bin/ephemeral_sync`.
    *   Restore all your tracked files to your home directory (`~`).
    *   Create the configuration file at `/workspace/.ephemeral_sync_config` with the remote URL hardcoded.
    *   Start the synchronization daemon automatically.

## Usage

The script supports five main commands, which you can run using the installed path (`ephemeral_sync`):

| Command | Description |
| :--- | :--- |
| `ephemeral_sync start` | Starts the daemon in the background. |
| `ephemeral_sync stop` | Stops the running daemon process. |
| `ephemeral_sync status` | Checks and reports the PID of the running daemon. |
| `ephemeral_sync restore` | Manually triggers the restoration process from the `restore_url` in the config file. |
| `ephemeral_sync deploy <URL>` | **For new machines.** Clones the repo, installs the script, restores files, and starts the daemon. |

### Logging

All actions are logged to `/workspace/.ephemeral_sync.log`.
