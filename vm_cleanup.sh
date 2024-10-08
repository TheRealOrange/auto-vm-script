#!/bin/bash

# Threshold for inactivity in minutes
INACTIVITY_THRESHOLD=15 # Adjust as needed

CURRENT_TIME=$(date +%s)

# Function to display messages
function echo_info {
    echo -e "\e[32m[INFO]\e[0m $1"
}

function echo_error {
    echo -e "\e[31m[ERROR]\e[0m $1" >&2
}

shopt -s nullglob
# Iterate over all VMs that have last active files
for LAST_ACTIVE_FILE in /tmp/vm_*.last_active; do
    # Extract VMID from the filename
    VMID=$(basename "$LAST_ACTIVE_FILE" | sed 's/vm_\([0-9]\+\)\.last_active/\1/')
    
    # Get the associated username
    USER_NUM=${VMID#1}
    USER="vm_user_${USER_NUM}"
    
    # Check if the user has any active SSH sessions
    if lsof -i -n | grep -E "sshd.*ESTABLISHED.*$USER" > /dev/null; then
        # User is currently logged in
        echo_info "User $USER is logged in; VM $VMID remains running."
        # Update last active time
        touch "$LAST_ACTIVE_FILE"
        continue
    fi
    
    # User is not logged in; check inactivity duration
    LAST_ACTIVE_TIME=$(stat -c %Y "$LAST_ACTIVE_FILE")
    INACTIVITY_TIME=$(( (CURRENT_TIME - LAST_ACTIVE_TIME) / 60 ))  # Convert to minutes
    
    if [ "$INACTIVITY_TIME" -ge "$INACTIVITY_THRESHOLD" ]; then
        # Inactivity threshold exceeded; shut down VM if running
        VM_STATUS=$(qm status "$VMID" | awk '{print $2}')
        if [ "$VM_STATUS" = "running" ]; then
            echo_info "Shutting down VM $VMID for user $USER due to $INACTIVITY_TIME minutes of inactivity."
            qm shutdown "$VMID"
            # Optional: Check if shutdown was successful
            sleep 5
            if qm status "$VMID" | grep -q "running"; then
                echo_error "VM $VMID did not shut down properly."
            else
                echo_info "VM $VMID has been shut down."
            fi
        fi
    else
        echo_info "User $USER has been inactive for $INACTIVITY_TIME minutes; VM $VMID remains running."
    fi
done
shopt -u nullglob
