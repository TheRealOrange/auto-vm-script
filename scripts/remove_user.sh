#!/bin/bash

# Script to remove a vm_user_xx user and any associated VMs

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Source the configuration file
CONFIG_FILE="/etc/auto_vm/auto_vm_config.sh"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "Configuration file $CONFIG_FILE not found. Exiting."
    exit 1
fi

# Ensure LOG_DIR exists
mkdir -p $LOG_DIR

LOG_FILE="${VM_USER_LOG}"

# Ensure log files exists with proper permissions
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 username"
    exit 1
fi

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

USERNAME=$1

# Validate username format
if [[ ! "$USERNAME" =~ ^${USER_PREFIX}[0-9]{2}$ ]]; then
    echo_error "Invalid username format. Username must be in the format ${USER_PREFIX}xx, where xx is a number"
    exit 1
fi

# Check if the user exists
if ! id "$USERNAME" &>/dev/null; then
    echo_error "User $USERNAME does not exist."
    exit 1
fi

# Extract the numeric part of the username
USER_NUM=${USERNAME##${USER_PREFIX}}

# Define VMID based on the user number
VMID="${VM_ID_START}${USER_NUM}"

# Confirm deletion
echo_info "WARNING: This action will permanently DELETE user '$USERNAME' and VM '$VMID'."
read -p "Type 'yes' to confirm and proceed: " CONFIRM

if [[ "${CONFIRM,,}" != "yes" ]]; then
    echo_info "Operation canceled."
    exit 0
fi

echo_info "Proceeding with deletion..."

# Terminate any processes owned by the user
pkill -u "$USERNAME" 2>/dev/null

# Remove the user and their home directory
USERDEL_OUTPUT=$(userdel -r "$USERNAME" 2>&1)
if [[ $? -eq 0 ]]; then
    echo_info "User $USERNAME has been deleted along with their home directory."
else
    echo_error "Failed to delete user $USERNAME. Error: $USERDEL_OUTPUT"
    exit 1
fi

# Check if the VM exists
if "$QM_CMD" status "$VMID" &>/dev/null; then
    # Stop the VM if it is not already stopped
    VM_STATUS=$("$QM_CMD" status "$VMID" | awk '{print $2}')
    if [[ "$VM_STATUS" != "stopped" && "$VM_STATUS" != "unknown" ]]; then
        echo_info "Stopping VM $VMID (current state: $VM_STATUS)..."
        "$QM_CMD" shutdown "$VMID"
        # Wait for the VM to shut down gracefully
        TIMEOUT="$TOTAL_TIMEOUT_SHUTDOWN"  # seconds
        SLEEP_INTERVAL="$SLEEP_INTERVAL_SHUTDOWN"
        ELAPSED_TIME=0

        while "$QM_CMD" status "$VMID" | grep -qv "stopped"; do
            sleep $SLEEP_INTERVAL
            ELAPSED_TIME=$((ELAPSED_TIME + SLEEP_INTERVAL))
            if [[ $ELAPSED_TIME -ge $TIMEOUT ]]; then
                echo_info "VM did not shut down gracefully. Forcing shutdown..."
                "$QM_CMD" stop "$VMID"
                # Wait for the VM to stop
                sleep 5
                break
            fi
        done
    fi

    # Destroy the VM
    echo_info "Destroying VM $VMID..."
    "$QM_CMD" destroy "$VMID" --purge
    if [[ $? -eq 0 ]]; then
        echo_info "VM $VMID has been destroyed."
    else
        echo_error "Failed to destroy VM $VMID."
        exit 1
    fi
else
    echo_info "VM $VMID does not exist."
fi

# Remove temporary files associated with the VM
LAST_ACTIVE_FILE="${LOCK_DIR}/vm_${VMID}.last_active"
if [[ -f "$LAST_ACTIVE_FILE" ]]; then
    rm "$LAST_ACTIVE_FILE"
    if [[ $? -eq 0 ]]; then
        echo_info "Removed last active file $LAST_ACTIVE_FILE."
    else
        echo_error "Failed to remove last active file $LAST_ACTIVE_FILE."
    fi
fi

LOCK_FILE="${LOCK_DIR}/vm_${VMID}.lock"
if [[ -f "$LOCK_FILE" ]]; then
    rm -f "$LOCK_FILE"
    echo_info "Removed lock file $LOCK_FILE."
fi

CLOUDINIT_ISO="${CLOUDINIT_DIR}/cloudinit_${VMID}.iso"
if [[ -f "$CLOUDINIT_ISO" ]]; then
    rm "$CLOUDINIT_ISO"
    if [[ $? -eq 0 ]]; then
        echo_info "Removed Cloud-Init ISO $CLOUDINIT_ISO."
    else
        echo_error "Failed to remove Cloud-Init ISO $CLOUDINIT_ISO."
    fi
fi

echo_info "Cleanup completed for user $USERNAME and VM $VMID."

# Optional: Generate a report of any remaining files owned by the user
find / -path /proc -prune -o -user "$USERNAME" -ls > "/root/${USERNAME}_files.txt" 2>/dev/null
echo_info "Generated report of files previously owned by $USERNAME at /root/${USERNAME}_files.txt"
