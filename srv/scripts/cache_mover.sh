#!/bin/bash

# Configuration
SSD_UPPERDIR="/mnt/ssd_upperdir"
HDD_DRIVES=("/mnt/sda" "/mnt/sdb" "/mnt/sdc")
MAX_USAGE_PERCENT=90
FILE_AGE_DAYS=30
LOG_FILE="/var/log/ssd_to_hdd_mover.log"
LOCK_FILE="/var/lock/ssd_to_hdd_mover.lock"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Ensure we're not already running
if [ -e "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE")
    if ps -p "$pid" > /dev/null; then
        log_message "Script is already running with PID $pid. Exiting."
        exit 1
    else
        log_message "Removing stale lock file."
        rm -f "$LOCK_FILE"
    fi
fi

# Create lock file
echo $$ > "$LOCK_FILE"

# Cleanup function for proper exit
cleanup() {
    log_message "Cleaning up and exiting"
    rm -f "$LOCK_FILE"
    exit "${1:-0}"
}

# Trap signals for clean exit
trap 'cleanup 1' SIGINT SIGTERM

# Function to get disk usage percentage
get_disk_usage_percent() {
    local disk=$1
    local usage=$(df -h "$disk" | grep -v Filesystem | awk '{print $5}' | sed 's/%//')
    echo "$usage"
}

# Function to get available disk space in bytes
get_disk_available_space() {
    local disk=$1
    local available=$(df --output=avail "$disk" | grep -v Avail | tr -d ' ')
    echo "$available"
}

# Function to find files older than X days
find_old_files() {
    find "$SSD_UPPERDIR" -type f -mtime +"$FILE_AGE_DAYS" -print
}

# Function to handle file migration with proper OverlayFS handling using rsync
handle_file_migration() {
    local file=$1
    local target_hdd=$2
    
    # Create the relative path from the upperdir
    local rel_path="${file#$SSD_UPPERDIR/}"
    local target_path="$target_hdd/$rel_path"
    local target_dir=$(dirname "$target_path")
    
    # Get file size
    local file_size=$(stat -c %s "$file")
    
    # Check if there's enough space on the target disk
    local available_space=$(get_disk_available_space "$target_hdd")
    if [ "$available_space" -lt "$file_size" ]; then
        log_message "Not enough space on $target_hdd to move $file (Size: $file_size, Available: $available_space)"
        return 1
    fi
    
    # Create directory structure if it doesn't exist
    mkdir -p "$target_dir"
    
    # Use rsync to transfer the file and remove source on success
    if rsync -av --remove-source-files "$file" "$target_path" > /dev/null 2>&1; then
        log_message "Migrated: $file to $target_path (Size: $file_size bytes)"
        
        # Check for and remove empty directories in the upperdir
        local parent_dir=$(dirname "$file")
        if [ -d "$parent_dir" ] && [ "$parent_dir" != "$SSD_UPPERDIR" ]; then
            # Only remove if directory is empty
            if [ -z "$(ls -A "$parent_dir")" ]; then
                rmdir --ignore-fail-on-non-empty "$parent_dir"
                log_message "Removed empty directory: $parent_dir"
            fi
        fi
        
        return 0
    else
        log_message "ERROR: Failed to rsync $file to $target_path"
        return 1
    fi
}

# Main execution
log_message "Starting SSD to HDD file migration"

# Find files to move
log_message "Finding files older than $FILE_AGE_DAYS days in $SSD_UPPERDIR"
old_files=$(find_old_files)

if [ -z "$old_files" ]; then
    log_message "No files older than $FILE_AGE_DAYS days found. Nothing to do."
    cleanup 0
fi

# Count files to move
file_count=$(echo "$old_files" | wc -l)
log_message "Found $file_count files older than $FILE_AGE_DAYS days to move"

# Process each file
moved_files=0
moved_size=0
while IFS= read -r file; do
    # Skip if file no longer exists
    [ ! -f "$file" ] && continue
    
    file_size=$(stat -c %s "$file")
    moved=0
    
    # Try to move to each disk in order
    for hdd in "${HDD_DRIVES[@]}"; do
        usage=$(get_disk_usage_percent "$hdd")
        
        if [ "$usage" -lt "$MAX_USAGE_PERCENT" ]; then
            if handle_file_migration "$file" "$hdd"; then
                moved=1
                moved_files=$((moved_files + 1))
                moved_size=$((moved_size + file_size))
                break
            fi
        else
            log_message "Disk $hdd is at or above $MAX_USAGE_PERCENT% capacity ($usage%). Trying next disk."
        fi
    done
    
    if [ $moved -eq 0 ]; then
        log_message "WARNING: Could not move file $file. All disks are at or above $MAX_USAGE_PERCENT% capacity."
    fi
done <<< "$old_files"

log_message "File migration completed: Moved $moved_files files totaling $(numfmt --to=iec-i --suffix=B $moved_size)"

# Run SnapRAID sync if any files were moved
if [ $moved_files -gt 0 ]; then
    log_message "Starting SnapRAID sync operation"
    if snapraid sync; then
        log_message "SnapRAID sync completed successfully"
    else
        log_message "ERROR: SnapRAID sync failed with exit code $?"
    fi
else
    log_message "No files were moved, skipping SnapRAID sync"
fi

log_message "Script execution completed"
cleanup 0
