#!/bin/bash

USER=$(whoami)

# Function to display messages
function echo_info {
    echo -e "\e[32m[INFO]\e[0m $1"
}

function echo_error {
    echo -e "\e[31m[ERROR]\e[0m $1" >&2
}

# Validate username format
if [[ ! "$USER" =~ ^vm_user_[0-9]+$ ]]; then
    echo_error "Invalid user"
    exit 1
fi

# Extract the numeric part of the username
USER_NUM=${USER##vm_user_}

# Define VMID based on the user number
VMID="2${USER_NUM}"

# Define VM Name (replace underscores with hyphens)
VM_NAME="user-vm-${VMID}"

USER_SSH_DIR="/home/${USER}/.ssh"
# Retrieve the user's private key from the host
PRIVKEYFILE="$USER_SSH_DIR/keys/${USER}_id"
if [[ ! -f "$PRIVKEYFILE" ]]; then
    echo_error "No private key found for user $USER"
    exit 1
fi

# Check if the VM exists
if ! sudo /usr/sbin/qm status $VMID &>/dev/null; then
    TEMPLATEID=9000  # VM Template ID
    
    # Retrieve the user's public key from the host
    PUBKEYFILE="$USER_SSH_DIR/keys/${USER}_id.pub"
    if [[ -f "$PUBKEYFILE" ]]; then
        PUBKEY=$(cat "$PUBKEYFILE")
    else
        echo_error "No public key found for user $USER at $PUBKEYFILE"
        exit 1
    fi

    # Create Cloud-Init user data for the VM
    CLOUDINIT_ISO="/var/lib/vz/template/iso/cloudinit_${VMID}.iso"
    USERDATA_FILE="/tmp/userdata_${VMID}.cfg"
    METADATA_FILE="/tmp/metadata_${VMID}.cfg"

    # Create user-data file
    cat > "$USERDATA_FILE" <<EOF
#cloud-config
hostname: $VM_NAME
users:
  - name: $USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh-authorized-keys:
      - $PUBKEY
    lock-passwd: true
ssh_pwauth: False
disable_root: True
EOF

    # Create meta-data file
    cat > "$METADATA_FILE" <<EOF
instance-id: $VMID
local-hostname: $VM_NAME
EOF

    # Generate the cloud-init ISO
    sudo /usr/bin/cloud-localds "$CLOUDINIT_ISO" "$USERDATA_FILE" "$METADATA_FILE"

    # Clone the template
    echo_info "Cloning template ID $TEMPLATEID to VM ID $VMID with name $VM_NAME... (This may take a while...)"
    sudo /usr/sbin/qm clone $TEMPLATEID $VMID --name $VM_NAME --full 2>&1 | grep -v '^transferred'

    # Check if clone was successful
    if [ $? -ne 0 ]; then
        echo_error "Failed to clone VM. Please check the template ID and storage configuration."
        exit 1
    fi
    echo_info "Clone completed."

    # Attach the cloud-init ISO to the VM
    echo_info "Attaching cloud-init ISO to VM $VMID..."
    sudo /usr/sbin/qm set $VMID --ide2 local:iso/cloudinit_${VMID}.iso,media=cdrom

    # Enable QEMU Guest Agent
    echo_info "Enabling QEMU Guest Agent for VM $VMID..."
    sudo /usr/sbin/qm set $VMID --agent enabled=1

    # Start the VM
    echo_info "Starting VM $VMID..."
    sudo /usr/sbin/qm start $VMID

    # Clean up temporary files
    rm "$USERDATA_FILE" "$METADATA_FILE"
else
    # Check if the VM is running; start it if necessary
    VM_STATUS=$(sudo /usr/sbin/qm status "$VMID" | awk '{print $2}')
    if [ "$VM_STATUS" != "running" ]; then
        echo_error "Starting VM $VMID for user $USER..."
        sudo /usr/sbin/qm start "$VMID"
    fi
fi

# Wait for the VM to boot and get its IP address
# Initialize timeout variables
TOTAL_TIMEOUT=120  # Total timeout in seconds
SLEEP_INTERVAL=5   # Interval between checks in seconds
ELAPSED_TIME=0

# Loop until the VM is running or timeout is reached
while [ $ELAPSED_TIME -lt $TOTAL_TIMEOUT ]; do
    # Check if the VM is running
    if sudo /usr/sbin/qm status $VMID | grep -q "running"; then
        # Check if the Guest Agent is connected
        if sudo /usr/sbin/qm agent $VMID ping &>/dev/null; then
            echo_info "VM is up and Guest Agent is available."
            break
        else
            echo_info "Guest Agent not yet available..."
        fi
    else
        echo_info "VM is not yet running..."
    fi

    # Sleep before the next check
    sleep $SLEEP_INTERVAL
    ELAPSED_TIME=$((ELAPSED_TIME + SLEEP_INTERVAL))
done

# Check if timeout was reached
if [ $ELAPSED_TIME -ge $TOTAL_TIMEOUT ]; then
    echo_error "VM did not become ready within $TOTAL_TIMEOUT seconds."
    exit 1
fi

# Attempt to retrieve the VM's IP address using jq
echo_info "Retrieving VM IP address..."
VM_IP=$(sudo /usr/sbin/qm guest exec "$VMID" -- ip -4 -o addr show | jq -r '.["out-data"]' | awk '!/ lo|127\.0\.0\.1 /{gsub(/\/.*/,"",$4); print $4; exit}')

if [[ -z "$VM_IP" ]]; then
    echo_error "Failed to retrieve VM IP"
    exit 1
fi

# Wait until SSH is available on the VM
echo_info "Waiting for SSH to be available..."
TOTAL_TIMEOUT=60  # Total timeout in seconds
SLEEP_INTERVAL=2   # Interval between checks in seconds
ELAPSED_TIME=0
while ! nc -z $VM_IP 22; do
    sleep $SLEEP_INTERVAL
    ELAPSED_TIME=$((ELAPSED_TIME + SLEEP_INTERVAL))
    if [[ $ELAPSED_TIME -ge $TOTAL_TIMEOUT ]]; then
        echo_error "SSH service not available on the VM"
        exit 1
    fi
done

# Define the path to the last active file
LAST_ACTIVE_FILE="/tmp/vm_${VMID}.last_active"

# Update last active time
touch "$LAST_ACTIVE_FILE"

exec ssh -i $PRIVKEYFILE  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $USER@$VM_IP $SSH_ORIGINAL_COMMAND
