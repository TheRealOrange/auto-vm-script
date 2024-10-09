#!/bin/bash

USER=$(whoami)

# Function to display messages
function echo_info {
    echo -e "\e[32m[INFO]\e[0m $1"
}

function echo_error {
    echo -e "\e[31m[ERROR]\e[0m $1" >&2
}

function wait_vm_start {
    # Wait for the VM to boot and get its IP address
    # Initialize timeout variables
    TOTAL_TIMEOUT=120  # Total timeout in seconds
    SLEEP_INTERVAL=5   # Interval between checks in seconds
    ELAPSED_TIME=0

    echo_info "Waiting for VM..."
    # Loop until the VM is running or timeout is reached
    while [ $ELAPSED_TIME -lt $TOTAL_TIMEOUT ]; do
        # Check if the VM is running
        if sudo /usr/sbin/qm status $1 | grep -q "running"; then
            # Check if the Guest Agent is connected
            if sudo /usr/sbin/qm agent $1 ping &>/dev/null; then
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
}

# Validate username format
if [[ ! "$USER" =~ ^vm_user_[0-9]+$ ]]; then
    echo_error "Invalid user"
    exit 1
fi

echo_info "Connecting to VM..."

# Extract the numeric part of the username
USER_NUM=${USER##vm_user_}

# Define VMID based on the user number
VMID="2${USER_NUM}"

# Define VM Name (replace underscores with hyphens)
VM_NAME="user-vm-${VMID}"

# Check if the VM exists
if ! sudo /usr/sbin/qm status $VMID &>/dev/null; then
    echo_info "Spinning up new VM..."
    TEMPLATEID=9000

    # Retrieve the user's public key from the host
    PUBKEYFILE="/home/${USER}/.ssh/keys/${USER}_id.pub"
    if [[ ! -f "$PUBKEYFILE" ]]; then
        echo_error "No public key found for user $USER at $PUBKEYFILE"
        exit 1
    fi
    PUBKEY=$(<"$PUBKEYFILE")

    CLOUDINIT_ISO="/var/lib/vz/template/iso/cloudinit_${VMID}.iso"
    USERDATA_FILE="/tmp/userdata_${VMID}.cfg"
    METADATA_FILE="/tmp/metadata_${VMID}.cfg"

    # Create user-data and meta-data in parallel
    {
        cat > "$USERDATA_FILE" <<EOF
#cloud-config
hostname: $VM_NAME
fqdn: $VM_NAME.localdomain
manage_etc_hosts: true
users:
  - name: $USER
    groups: docker
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh-authorized-keys:
      - $PUBKEY
    lock-passwd: true
    shell: /bin/bash
ssh_pwauth: False
disable_root: True
ssh:
  allow_tcp_forwarding: true
EOF
    } &

    {
        cat > "$METADATA_FILE" <<EOF
instance-id: $VMID
local-hostname: $VM_NAME
EOF
    } &

    wait  # Ensure both tasks are done before continuing

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

    wait_vm_start $VMID
else
    echo_info "Checking if VM is running..."
    # Check if the VM is running; start it if necessary
    VM_STATUS=$(sudo /usr/sbin/qm status "$VMID" | awk '{print $2}')
    if [ "$VM_STATUS" != "running" ]; then
        echo_info "Starting VM $VMID for user $USER..."
        sudo /usr/sbin/qm start "$VMID"

        wait_vm_start $VMID
    fi
fi

# Wait for the VM to boot and get its IP address
TOTAL_TIMEOUT=60  # Wait a max of 60 seconds for boot
SLEEP_INTERVAL=1  # Keep checking every 2 seconds

echo_info "Waiting for VM IP to become available..."
for ((i=0; i<$TOTAL_TIMEOUT; i+=$SLEEP_INTERVAL)); do
    VM_IP=$(sudo /usr/sbin/qm guest exec "$VMID" -- ip -4 -o addr show | jq -r '.["out-data"]' | awk '!/ lo|127\.0\.0\.1 /{gsub(/\/.*/,"",$4); print $4; exit}')
    if [[ -n "$VM_IP" ]]; then
        echo_info "VM is up with IP $VM_IP."
        break
    fi
    sleep $SLEEP_INTERVAL
done

if [[ -z "$VM_IP" ]]; then
    echo_error "Failed to retrieve VM IP."
    exit 1
fi

# Wait until SSH is available on the VM
echo_info "Waiting for SSH to be available..."
TOTAL_TIMEOUT=60  # Total timeout in seconds
SLEEP_INTERVAL=1   # Interval between checks in seconds
ELAPSED_TIME=0
while ! nc -z $VM_IP 22; do
    if [[ $ELAPSED_TIME -ge $TOTAL_TIMEOUT ]]; then
        echo_error "SSH service not available on the VM"
        exit 1
    fi
    sleep $SLEEP_INTERVAL
    ELAPSED_TIME=$((ELAPSED_TIME + SLEEP_INTERVAL))
done

# Define the path to the last active file
LAST_ACTIVE_FILE="/tmp/vm_${VMID}.last_active"

# Update last active time
touch "$LAST_ACTIVE_FILE"

exec nc -q0 $VM_IP 22