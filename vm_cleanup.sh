#!/bin/bash

# vm_cleanup.sh
# This script is intended to be run every minute via a cron job.
# It manages VM lock files by ensuring they reflect the current state of VMs.

# Configuration Variables
LOCK_DIR="/var/lock/auto_vm"  # Directory to store lock and last active files
LOG_DIR="/var/log/auto_vm"
LOG_FILE="${LOG_DIR}/vm_cleanup.log"
INACTIVITY_THRESHOLD=20          # Inactivity threshold in minutes

# Ensure LOCK_DIR exists with proper permissions
mkdir -p $LOCK_DIR
chown root:vmusers "$LOCK_DIR"
chmod 774 "$LOCK_DIR"

# Ensure LOG_FILE exists with proper permissions
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

# Function to display informational messages
echo_info() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\e[32m[INFO]\e[0m $1"
    flock -w 5 "$LOG_FILE" -c "echo '[$timestamp][INFO] $1' >> \"$LOG_FILE\""
}

# Function to display error messages
echo_error() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\e[31m[ERROR]\e[0m $1" >&2
    flock -w 5 "$LOG_FILE" -c "echo '[$timestamp][ERROR] $1' >> \"$LOG_FILE\""
}

# Function to retrieve the VM's IP address
get_vm_ip() {
    local VMID="$1"
    local VM_IP=""

    # Attempt to retrieve IP via qm guest exec
    VM_IP=$(sudo /usr/sbin/qm guest exec "$VMID" -- ip -4 -o addr show | jq -r '.["out-data"]' | awk '!/ lo|127\.0\.0\.1 /{gsub(/\/.*/,"",$4); print $4; exit}')

    echo "$VM_IP"
}

# Prevent concurrent executions
LOCKFILE="${LOCK_DIR}/cleanup.lock"

if [ -e "$LOCKFILE" ] && kill -0 "$(cat "$LOCKFILE")" 2>/dev/null; then
    echo_info "vm_cleanup.sh is already running. Exiting."
    exit 0
fi

echo $$ > "$LOCKFILE"

# Ensure the lock file is removed upon script exit
trap 'rm -f "$LOCKFILE"; exit' EXIT

# Clean Up Orphaned Lock Files
echo_info "Checking lock files..."

for LOCK_FILE in "$LOCK_DIR"/vm_*.lock; do
    # Check if any lock files exist
    if [ ! -e "$LOCK_FILE" ]; then
        break
    fi

    # Extract VMID from the filename
    VMID=$(basename "$LOCK_FILE" | sed 's/vm_\([0-9]\+\)\.lock/\1/')

    # Check if the VM exists and is running
    VM_STATUS=$(sudo /usr/sbin/qm status "$VMID" 2>/dev/null || true)

    if echo "$VM_STATUS" | grep -q "running"; then
        echo_info "VM $VMID is running. Lock file exists."
        # No action needed
    else
        echo_info "VM $VMID is not running or does not exist. Deleting orphaned lock file."
        rm -f "$LOCK_FILE"
    fi
done

# Iterate Over All Lock Files to Manage VM States
echo_info "Managing VM states based on inactivity."

for LOCK_FILE in "$LOCK_DIR"/vm_*.lock; do
    # Check if any lock files exist
    if [ ! -e "$LOCK_FILE" ]; then
        echo_info "No lock files found in $LOCK_DIR."
        break
    fi

    # Extract VMID from the filename
    VMID=$(basename "$LOCK_FILE" | sed 's/vm_\([0-9]\+\)\.lock/\1/')

    # Define the corresponding last active file
    LAST_ACTIVE_FILE="$LOCK_DIR/vm_${VMID}.last_active"

    # Get the associated username
    USER_NUM=${VMID#2}
    USER="vm_user_${USER_NUM}"

    # Check if the user has any active SSH sessions
    if /usr/bin/lsof -i -n | grep -E "sshd.*$USER.*(ESTABLISHED)" > /dev/null; then
        # User is currently logged in
        echo_info "User $USER is logged in; VM $VMID remains running."
        # Update last active time
        touch "$LAST_ACTIVE_FILE"
        chown $USER:$USER "$LAST_ACTIVE_FILE"
        continue
    fi

    # Check if the last active file exists
    if [[ ! -f "$LAST_ACTIVE_FILE" ]]; then
        echo_error "Last active file $LAST_ACTIVE_FILE does not exist for VM $VMID. Creating it."
        touch "$LAST_ACTIVE_FILE"
        chown $USER:$USER "$LAST_ACTIVE_FILE"
    fi

    # Calculate inactivity duration
    LAST_ACTIVE_TIME=$(stat -c %Y "$LAST_ACTIVE_FILE")
    CURRENT_TIME=$(date +%s)
    INACTIVITY_TIME=$(( (CURRENT_TIME - LAST_ACTIVE_TIME) / 60 ))  # Convert to minutes

    if [ "$INACTIVITY_TIME" -ge "$INACTIVITY_THRESHOLD" ]; then
        # Inactivity threshold exceeded; shut down VM if running
        echo_info "VM $VMID has been inactive for $INACTIVITY_TIME minutes. Initiating shutdown."

        # Attempt to gracefully shut down the VM in the background
        (
            sudo /usr/sbin/qm shutdown "$VMID" && echo_info "Shutdown command issued for VM $VMID."

            # Wait for the VM to shut down gracefully
            SHUTDOWN_TIMEOUT=60  # seconds
            SLEEP_INTERVAL=5
            ELAPSED=0

            while sudo /usr/sbin/qm status "$VMID" | grep -q "running"; do
                if [ "$ELAPSED" -ge "$SHUTDOWN_TIMEOUT" ]; then
                    echo_error "VM $VMID did not shut down within $SHUTDOWN_TIMEOUT seconds. Forcing shutdown."
                    sudo /usr/sbin/qm stop "$VMID"
                    break
                fi
                sleep "$SLEEP_INTERVAL"
                ELAPSED=$((ELAPSED + SLEEP_INTERVAL))
            done

            # Verify shutdown
            if sudo /usr/sbin/qm status "$VMID" | grep -q "running"; then
                echo_error "Failed to shut down VM $VMID."
            else
                echo_info "VM $VMID has been shut down successfully."

                # Remove the lock file and last active file
                rm -f "$LOCK_FILE" "$LAST_ACTIVE_FILE"
                echo_info "Lock file and last active file for VM $VMID have been removed."
            fi
        ) &  # Run the shutdown process in the background
    else
        echo_info "User $USER has been inactive for $INACTIVITY_TIME minutes; VM $VMID remains running."
    fi
done

echo_info "vm_cleanup.sh execution completed."
