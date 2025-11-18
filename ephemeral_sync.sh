#!/bin/bash

# Configuration
CONFIG_FILE="/workspace/.ephemeral_sync_config"
REPO_DIR="/workspace/.ephemeral_sync_repo"
LOG_FILE="/workspace/.ephemeral_sync.log"
PID_FILE="/workspace/.ephemeral_sync.pid"
COOLDOWN_SECONDS=30 # Default cooldown

# --- Utility Functions ---

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Function to check if another instance is running
check_instance() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p $PID > /dev/null; then
            echo "Another instance of ephemeral_sync is already running with PID $PID."
            echo "Do you want to stop it and start a new one? (y/n)"
            read -r response
            if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
                kill "$PID"
                rm -f "$PID_FILE"
                log "Stopped previous instance (PID: $PID)."
                return 0 # Proceed
            else
                echo "Operation cancelled. Exiting."
                exit 1
            fi
        else
            # Stale PID file
            rm -f "$PID_FILE"
            return 0 # Proceed
        fi
    fi
    return 0 # Proceed
}

# Function to parse the config file
parse_config() {
    WATCH_PATHS=()
    IGNORE_PATTERNS=()
    REMOTE_URL=""
    RESTORE_URL=""

    if [ ! -f "$CONFIG_FILE" ]; then
        log "Config file not found at $CONFIG_FILE. Creating a default one."
        cat << EOF > "$CONFIG_FILE"
# ephemeral_sync Configuration File
# Syntax: <action> <path>
# <action> can be 'watch', 'ignore', 'remote', or 'restore_url'
# Paths can use standard shell wildcards (*, ?, []) and are relative to the user's home directory.

# Files and directories to watch (e.g., configuration files in the home directory)
watch .bashrc
watch .zshrc
watch .gitconfig
watch .ssh/id_rsa
watch .ssh/config
watch .Claude/

# Paths to ignore (e.g., large caches or temporary files)
ignore .cache/*
ignore .npm/*
ignore .local/share/Trash/*

# Remote Git URL for synchronization (e.g., a private GitHub repository)
# remote git@github.com:user/ephemeral-config.git

# URL to restore from on first run (e.g., a zipped .git repo or a remote git URL)
# restore_url https://example.com/ephemeral-config-backup.zip
EOF
        echo "Default config file created at $CONFIG_FILE. Please edit it and run the script again."
        exit 0
    fi

    while IFS= read -r line; do
        # Remove leading/trailing whitespace and skip comments/empty lines
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -z "$line" || "$line" =~ ^# ]]; then
            continue
        fi

        action=$(echo "$line" | awk '{print $1}')
        path=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^[[:space:]]*//')

        case "$action" in
            watch)
                WATCH_PATHS+=("$path")
                ;;
            ignore)
                IGNORE_PATTERNS+=("$path")
                ;;
            remote)
                REMOTE_URL="$path"
                ;;
            restore_url)
                RESTORE_URL="$path"
                ;;
            cooldown)
                COOLDOWN_SECONDS="$path"
                ;;
            *)
                log "Warning: Unknown action '$action' in config file."
                ;;
        esac
    done < "$CONFIG_FILE"

    if [ -z "$REMOTE_URL" ]; then
        log "Error: 'remote' URL is not set in $CONFIG_FILE. Cannot proceed with sync."
        # Note: We will allow the script to run in 'restore' mode without a remote URL,
        # but for 'sync' mode, it's mandatory.
    fi
}

# Function to initialize the Git repository
init_repo() {
    if [ ! -d "$REPO_DIR" ]; then
        log "Initializing new Git repository in $REPO_DIR."
        mkdir -p "$REPO_DIR"
        cd "$REPO_DIR" || exit 1
        git init -b main
        # Add a .gitignore to the repo itself to ignore the log and pid files
        echo "*.log" > .gitignore
        echo "*.pid" >> .gitignore
        git add .gitignore
        git commit -m "Initial repository setup"
        cd - > /dev/null || exit 1
    fi

    cd "$REPO_DIR" || exit 1
    if [ -n "$REMOTE_URL" ] && ! git remote get-url origin > /dev/null 2>&1; then
        log "Setting remote origin to $REMOTE_URL."
        git remote add origin "$REMOTE_URL"
    fi
    cd - > /dev/null || exit 1
}

# Function to restore files from a remote source
restore_files() {
    if [ -z "$RESTORE_URL" ]; then
        log "No restore_url specified. Skipping restore."
        return 0
    fi

    log "Attempting to restore from $RESTORE_URL."

    # Simple check for Git URL vs. Zip file (heuristic)
    if [[ "$RESTORE_URL" == *".git"* ]]; then
        # Assume it's a Git repository
        log "Restoring from Git URL: $RESTORE_URL"
        if [ -d "$REPO_DIR" ]; then
            log "Existing repo found. Pulling latest changes."
            cd "$REPO_DIR" || exit 1
            git pull origin main
            cd - > /dev/null || exit 1
        else
            log "Cloning repository to $REPO_DIR."
            git clone "$RESTORE_URL" "$REPO_DIR"
        fi

        # Checkout files from the repo to their original location (HOME)
        log "Checking out files to HOME directory."
        cd "$REPO_DIR" || exit 1
        # Use git checkout -- . to restore all tracked files to the working directory (which is HOME in this context)
        # We need to ensure the files are checked out to the correct location.
        # A simple way is to use 'git checkout' with a temporary index, but that's complex for pure bash.
        # The simplest approach is to copy the files from the repo to HOME, which requires knowing the file list.
        # Since we don't know the file list yet, we'll assume the repo contains the files relative to HOME.
        # A better approach is to use 'git checkout' with a working tree, but that's not standard in all bash environments.
        # For simplicity, we'll use a temporary directory and copy.

        TEMP_RESTORE_DIR=$(mktemp -d)
        log "Using temporary directory $TEMP_RESTORE_DIR for file extraction."

        # The core problem is that the files in the repo are relative to the repo root, but they need to be restored
        # relative to the user's HOME. The simplest way is to assume the repo *is* the HOME directory structure.
        # We will copy all files from the repo (excluding .git) to HOME.
        rsync -a --exclude='.git' "$REPO_DIR/" "$HOME/"
        log "Files restored from $REPO_DIR to $HOME."
        rm -rf "$TEMP_RESTORE_DIR"

        cd - > /dev/null || exit 1

    elif [[ "$RESTORE_URL" == *".zip"* ]]; then
        # Assume it's a zipped .git repository
        log "Restoring from zipped file: $RESTORE_URL"
        TEMP_ZIP_FILE=$(mktemp)
        if wget -O "$TEMP_ZIP_FILE" "$RESTORE_URL"; then
            log "Downloaded zip file."
            # Unzip the contents to the REPO_DIR
            unzip -o "$TEMP_ZIP_FILE" -d "$REPO_DIR"
            log "Unzipped contents to $REPO_DIR."
            rm "$TEMP_ZIP_FILE"
            # Now that the repo is restored, we can proceed with file checkout (same logic as above)
            rsync -a --exclude='.git' "$REPO_DIR/" "$HOME/"
            log "Files restored from $REPO_DIR to $HOME."
        else
            log "Error: Failed to download zip file from $RESTORE_URL."
            return 1
        fi
    else
        log "Error: Unsupported restore_url format. Must be a Git URL or a .zip file."
        return 1
    fi

    log "Restore complete."
    return 0
}

# Function to copy watched files into the repository
sync_files_to_repo() {
    log "Starting file synchronization to repository."
    local file_count=0

    # 1. Clear the repo of old files (except .git and .gitignore)
    # This is crucial to handle deleted files correctly.
    find "$REPO_DIR" -mindepth 1 -maxdepth 1 -not -name ".git" -not -name ".gitignore" -exec rm -rf {} +

    # 2. Copy watched files/directories from HOME to REPO_DIR
    for path_pattern in "${WATCH_PATHS[@]}"; do
        # Resolve the pattern relative to HOME
        # We use a subshell to change directory temporarily
        (
            cd "$HOME" || exit 1
            # The 'shopt -s dotglob' is important to include dotfiles in the glob expansion
            shopt -s dotglob
            for item in $path_pattern; do
                # Check if the item should be ignored
                local is_ignored=0
                for ignore_pattern in "${IGNORE_PATTERNS[@]}"; do
                    # Use a temporary file to check if the item matches the ignore pattern
                    # This is a complex check in pure bash, so we'll simplify:
                    # If the item starts with the ignore pattern, we ignore it.
                    # A proper glob/gitignore matching is much more complex.
                    # For a light script, we'll use a simple string match.
                    if [[ "$item" == "$ignore_pattern"* ]]; then
                        is_ignored=1
                        break
                    fi
                done

                if [ "$is_ignored" -eq 0 ]; then
                    # Copy the item to the repo, preserving structure
                    # Use rsync for efficiency and handling of directories
                    rsync -a "$item" "$REPO_DIR/"
                    file_count=$((file_count + 1))
                else
                    log "Ignoring $item due to pattern match."
                fi
            done
        )
    done

    log "Finished copying $file_count items to repository."
}

# Function to commit and push changes
commit_and_push() {
    if [ -z "$REMOTE_URL" ]; then
        log "Warning: Remote URL is not set. Skipping commit and push."
        return 0
    fi

    cd "$REPO_DIR" || exit 1

    # Check for changes
    git add -A
    if git diff --cached --quiet; then
        log "No changes detected. Skipping commit."
        cd - > /dev/null || exit 1
        return 0
    fi

    # Commit
    COMMIT_MESSAGE="Ephemeral sync: $(date '+%Y-%m-%d %H:%M:%S')"
    git commit -m "$COMMIT_MESSAGE"
    log "Committed changes: $COMMIT_MESSAGE"

    # Push
    log "Pushing changes to remote..."
    if git push origin main; then
        log "Push successful."
    else
        log "Error: Push failed. Check your Git configuration and network connection."
    fi

    cd - > /dev/null || exit 1
}

# --- Main Logic ---

run_daemon() {
    # Check if another instance is running and handle it
    check_instance

    # Parse configuration
    parse_config

    # If this is the first run and a restore URL is provided, restore files
    if [ ! -d "$REPO_DIR" ] && [ -n "$RESTORE_URL" ]; then
        restore_files
    fi

    # Initialize the repository (will also set remote if needed)
    init_repo

    # Write PID file
    echo $$ > "$PID_FILE"
    log "Daemon started with PID $$."

    # Main loop
    while true; do
        sync_files_to_repo
        commit_and_push
        log "Sleeping for $COOLDOWN_SECONDS seconds."
        sleep "$COOLDOWN_SECONDS"
    done
}

stop_daemon() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p $PID > /dev/null; then
            kill "$PID"
            rm -f "$PID_FILE"
            echo "ephemeral_sync daemon (PID: $PID) stopped."
            log "Daemon stopped by user request."
        else
            echo "Stale PID file found. Removing it."
            rm -f "$PID_FILE"
        fi
    else
        echo "ephemeral_sync daemon is not running."
    fi
}

# --- Command Line Interface ---

deploy() {
    local REMOTE_URL_ARG="$1"
    local SCRIPT_PATH="/usr/local/bin/ephemeral_sync" # Install location

    if [ -z "$REMOTE_URL_ARG" ]; then
        echo "Error: Remote URL is required for deployment."
        echo "Usage: curl ... | bash -s -- <REMOTE_URL>"
        exit 1
    fi

    echo "Starting ephemeral_sync deployment from: $REMOTE_URL_ARG"

    # 1. Clone the repository to the persistent workspace
    if [ ! -d "$REPO_DIR" ]; then
        echo "Cloning configuration repository to $REPO_DIR..."
        mkdir -p "$REPO_DIR"
        if ! git clone "$REMOTE_URL_ARG" "$REPO_DIR"; then
            echo "Error: Failed to clone repository. Check your SSH key or URL."
            exit 1
        fi
    else
        echo "Repository already exists at $REPO_DIR. Pulling latest changes."
        cd "$REPO_DIR" || exit 1
        git pull origin main
        cd - > /dev/null || exit 1
    fi

    # 2. Install the main script
    echo "Installing main script to $SCRIPT_PATH..."
    # The script is executed via curl | bash, so we need to save the running script to the install path
    # This relies on the script being executed via 'bash -s' which preserves $0 as the script name
    # However, since we are executing it directly, we can't rely on that.
    # The simplest way is to assume the user will save the script first, but for curl|bash, we need a trick.
    # The trick is to use 'cat' to get the content of the script that is being executed, but that's unreliable.
    # The most reliable way for a curl|bash is to have the script content itself be the source.
    # Since the user wants the script to be committed to the repo, we will copy it from the repo.

    if [ -f "$REPO_DIR/ephemeral_sync.sh" ]; then
        cp "$REPO_DIR/ephemeral_sync.sh" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
    else
        echo "Warning: ephemeral_sync.sh not found in the repository. Skipping script installation."
    fi

    # 3. Restore files to HOME directory
    echo "Restoring files to home directory..."
    rsync -a --exclude='.git' "$REPO_DIR/" "$HOME/"

    # 4. Create the config file with the hardcoded remote URL
    echo "Creating configuration file at $CONFIG_FILE with remote URL."
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat << EOF > "$CONFIG_FILE"
# ephemeral_sync Configuration File (Auto-generated by deploy)
remote $REMOTE_URL_ARG

# Files and directories to watch (edit this file to customize)
watch .bashrc
watch .zshrc
watch .gitconfig
watch .ssh/id_rsa
watch .ssh/config
watch .Claude/

# Paths to ignore
ignore .cache/*
ignore .npm/*
ignore .local/share/Trash/*
EOF

    # 5. Start the synchronization daemon
    echo "Starting the ephemeral_sync daemon..."
    if [ -x "$SCRIPT_PATH" ]; then
        "$SCRIPT_PATH" start
    else
        echo "Error: Main script not executable at $SCRIPT_PATH. Cannot start daemon."
    fi

    echo "Deployment complete. Run 'ephemeral_sync status' to check the daemon."
}


# --- Interactive Menu ---

main_menu() {
    PS3="Select an action: "
    options=("Start Daemon" "Stop Daemon" "Status Check" "Restore Files" "Deploy (First Run)" "Exit")
    select opt in "${options[@]}"
    do
        case "$opt" in
            "Start Daemon")
                # Run in background
                run_daemon &
                echo "ephemeral_sync daemon started in the background. Check $LOG_FILE for details."
                break
                ;;
            "Stop Daemon")
                stop_daemon
                break
                ;;
            "Status Check")
                if [ -f "$PID_FILE" ]; then
                    PID=$(cat "$PID_FILE")
                    if ps -p $PID > /dev/null; then
                        echo "ephemeral_sync daemon is running with PID $PID."
                    else
                        echo "ephemeral_sync daemon is not running (stale PID file found)."
                    fi
                else
                    echo "ephemeral_sync daemon is not running."
                fi
                break
                ;;
            "Restore Files")
                parse_config
                restore_files
                break
                ;;
            "Deploy (First Run)")
                echo "Enter the remote Git URL (e.g., git@github.com:user/repo.git):"
                read -r remote_url
                deploy "$remote_url"
                break
                ;;
            "Exit")
                echo "Exiting."
                exit 0
                ;;
            *) echo "Invalid option $REPLY";;
        esac
    done
}

# --- Main Execution ---

# If no arguments are passed, show the interactive menu
if [ -z "$1" ]; then
    main_menu
else
    # Allow non-interactive execution for deploy command via curl | bash
    case "$1" in
        deploy)
            deploy "$2"
            ;;
        *)
            echo "Error: Only 'deploy <REMOTE_URL>' is supported for non-interactive mode."
            echo "Run without arguments for the interactive menu."
            exit 1
            ;;
    esac
fi

# Ensure the script is executable
chmod +x /home/ubuntu/ephemeral_sync.sh
