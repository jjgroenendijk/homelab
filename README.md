# System Configuration Git Tracking

A minimal guide to track system configuration files using Git with automatic whitelist management.

## Setup Instructions

### 1. Initialize the Bare Git Repository

```bash
# Create the repository
sudo mkdir -p /srv/config
sudo git init --bare /srv/config
```

### 2. Create the Excludes File

```bash
# Create the directory for the excludes file
sudo mkdir -p /srv/config/info

# Create the excludes file with initial content
sudo tee /srv/config/info/excludes > /dev/null << 'EOF'
# Ignore everything by default
/*

# Files to track will be automatically added here
EOF

# Configure Git to use this excludes file
sudo git --git-dir=/srv/config --work-tree=/ config --local status.showUntrackedFiles no
sudo git --git-dir=/srv/config --work-tree=/ config --local core.excludesFile /srv/config/info/excludes
```

### 3. Create the Wrapper Script

```bash
# Create the wrapper script for automatic whitelisting
sudo tee /usr/local/bin/config > /dev/null << 'EOF'
#!/bin/bash

# Variables
GIT_DIR="/srv/config"
WORK_TREE="/"
EXCLUDES_FILE="/srv/config/info/excludes"

# Function to add path to excludes file
add_to_whitelist() {
    local path="$1"
    
    # Remove leading slash if present
    path=$(echo "$path" | sed 's|^/||')
    
    # Check if already whitelisted
    if ! grep -q "^!/$path$" "$EXCLUDES_FILE"; then
        echo "Adding /$path to whitelist..."
        echo "!/$path" | sudo tee -a "$EXCLUDES_FILE" > /dev/null
    fi
}

# Special handling for 'add' command
if [ "$1" = "add" ]; then
    shift
    for path in "$@"; do
        # Skip options (arguments starting with -)
        if [[ "$path" != -* ]]; then
            add_to_whitelist "$path"
        fi
    done
    
    # Call git with original arguments
    sudo git --git-dir="$GIT_DIR" --work-tree="$WORK_TREE" add "$@"
else
    # For all other git commands, pass through directly
    sudo git --git-dir="$GIT_DIR" --work-tree="$WORK_TREE" "$@"
fi
EOF

# Make it executable
sudo chmod +x /usr/local/bin/config
```

## Usage

### Track and Commit Files

```bash
# Add files to be tracked (automatically whitelisted)
config add /etc/snapraid.conf
config add /etc/systemd/system/snapraid-sync.service

# Commit changes
config commit -m "Add SnapRAID configuration"

# Check status
config status

# View history
config log
```

### View Whitelisted Files

```bash
# View the excludes file to see what's being tracked
cat /srv/config/info/excludes
```

### Normal Git Operations

```bash
# All standard Git commands work as expected
config pull
config push
config branch
config checkout -b new-config
```

## Migrating to a New System

```bash
# Clone the repository
sudo git clone --bare your-git-url /srv/config

# Create the wrapper script (repeat step 3 from setup)

# Check out the files
config checkout
```

This setup provides a clean way to track system files with Git, automatically whitelisting any files you add to the repository.
