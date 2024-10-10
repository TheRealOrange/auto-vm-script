#!/bin/bash

# Configuration Variables
LOCK_DIR="/var/lock/auto_vm"  # Directory to store lock and last active files
CLOUDINIT_DIR="/var/lib/vz/template/iso"
LOG_DIR="/var/log/auto_vm"
LOG_FILE="${LOG_DIR}/vm_management.log"

USERDATA_DIR="/tmp"
METADATA_DIR="/tmp"

# Function to display informational messages
echo_info() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\e[32m[INFO]\e[0m $1" >&2
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
    local USER="$2"
    local LOCK_FILE="${LOCK_DIR}/vm_${VMID}.lock"
    local VM_IP=""

    if [[ -f "$LOCK_FILE" ]]; then
        VM_IP=$(cat "$LOCK_FILE")
        echo_info "$USER: Retrieved VM IP from lock file: $VM_IP"
    else
        echo_info "$USER: Creating lock file for VM $VMID. Attempting to retrieve VM IP..."
        VM_IP=$(sudo /usr/sbin/qm guest exec "$VMID" -- ip -4 -o addr show | jq -r '.["out-data"]' | awk '!/ lo|127\.0\.0\.1 /{gsub(/\/.*/,"",$4); print $4; exit}')

        if [[ -n "$VM_IP" ]]; then
            echo "$VM_IP" > "$LOCK_FILE"
            chmod 600 "$LOCK_FILE"  # Secure the lock file
            echo_info "$USER: Lock file for VM $VMID created, IP address $VM_IP."
        else
            echo_error "$USER: Failed to retrieve VM IP for VM $VMID."
        fi
    fi

    echo "$VM_IP"
}

# Function to wait for the VM to start and become ready
wait_vm_start() {
    local VMID="$1"
    local USER="$2"
    local TOTAL_TIMEOUT=120  # Total timeout in seconds
    local SLEEP_INTERVAL=2   # Interval between checks in seconds
    local ELAPSED_TIME=0

    echo_info "$USER: Waiting for VM $VMID to become ready..."
    while [ "$ELAPSED_TIME" -lt "$TOTAL_TIMEOUT" ]; do
        if sudo /usr/sbin/qm status "$VMID" | grep -q "running"; then
            if sudo /usr/sbin/qm agent "$VMID" ping &>/dev/null; then
                echo_info "$USER: VM $VMID is up and Guest Agent is available."
                return 0
            else
                echo_info "$USER: Guest Agent for VM $VMID not yet available..."
            fi
        else
            echo_info "$USER: VM $VMID is not yet running..."
        fi

        sleep "$SLEEP_INTERVAL"
        ELAPSED_TIME=$((ELAPSED_TIME + SLEEP_INTERVAL))
    done

    echo_error "$USER: VM $VMID did not become ready within $TOTAL_TIMEOUT seconds."
    exit 1
}

# Validate username format
USER=$(whoami)
if [[ ! "$USER" =~ ^vm_user_[0-9]+$ ]]; then
    echo_error "Invalid user format. Expected format: vm_user_<number>"
    exit 1
fi

echo_info "Initiating connection process for user $USER..."

# Extract the numeric part of the username
USER_NUM=${USER##vm_user_}

# Define VMID based on the user number
VMID="2${USER_NUM}"

# Define VM Name (replace underscores with hyphens)
VM_NAME="user-vm-${VMID}"

# Define paths for lock and last active files
LOCK_FILE="${LOCK_DIR}/vm_${VMID}.lock"
LAST_ACTIVE_FILE="${LOCK_DIR}/vm_${VMID}.last_active"

# Function to create cloud-init configuration files
create_cloudinit_files() {
    local USER="$1"
    local VMID="$2"
    local VM_NAME="$3"
    local PUBKEY="$4"
    local CLOUDINIT_ISO="$5"
    local USERDATA_FILE="$6"
    local METADATA_FILE="$7"

    echo_info "$USER: Creating user-data and meta-data files for VM $VMID..."
    
    # Create user-data file in background
    cat > "$USERDATA_FILE" <<EOF &
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

    # Create meta-data file in background
    cat > "$METADATA_FILE" <<EOF &
instance-id: $VMID
local-hostname: $VM_NAME
EOF

    wait  # Ensure both background jobs are completed

    echo_info "$USER: Generating cloud-init ISO for VM $VMID..."
    sudo /usr/bin/cloud-localds "$CLOUDINIT_ISO" "$USERDATA_FILE" "$METADATA_FILE"
}

# Function to clone the VM template
clone_vm_template() {
    local TEMPLATEID="$1"
    local VMID="$2"
    local VM_NAME="$3"
    local USER="$4"

    echo_info "$USER: Cloning template ID $TEMPLATEID to VM ID $VMID with name $VM_NAME..."
    sudo /usr/sbin/qm clone "$TEMPLATEID" "$VMID" --name "$VM_NAME" --full 2>&1 | grep -v '^transferred'

    if [ $? -ne 0 ]; then
        echo_error "$USER: Failed to clone VM $VMID from template $TEMPLATEID."
        exit 1
    fi

    echo_info "$USER: Clone of VM $VMID completed successfully."
}

# Check if the lock file exists
if [[ -f "$LOCK_FILE" ]]; then
    echo_info "$USER: Lock file exists for VM $VMID. Assuming VM is running."
else
    # Lock file does not exist; check VM status
    echo_info "$USER: Lock file does not exist for VM $VMID. Checking VM status..."
    
    # Attempt to retrieve the VM status
    VM_STATUS=$(sudo /usr/sbin/qm status "$VMID" 2>/dev/null)
    STATUS_EXIT_CODE=$?
    
    if [ "$STATUS_EXIT_CODE" -ne 0 ]; then
        echo_info "$USER: VM $VMID does not exist. Proceeding to create a new VM."

        TEMPLATEID=9000

        # Retrieve the user's public key from the host
        PUBKEYFILE="/home/${USER}/.ssh/keys/${USER}_id.pub"
        if [[ ! -f "$PUBKEYFILE" ]]; then
            echo_error "$USER: No public key found for user $USER at $PUBKEYFILE"
            exit 1
        fi
        PUBKEY=$(<"$PUBKEYFILE")

        CLOUDINIT_ISO="${CLOUDINIT_DIR}/cloudinit_${VMID}.iso"
        USERDATA_FILE="${USERDATA_DIR}/userdata_${VMID}.cfg"
        METADATA_FILE="${METADATA_DIR}/metadata_${VMID}.cfg"

        # Create cloud-init files
        create_cloudinit_files "$USER" "$VMID" "$VM_NAME" "$PUBKEY" "$CLOUDINIT_ISO" "$USERDATA_FILE" "$METADATA_FILE"

        # Clone the VM template
        clone_vm_template "$TEMPLATEID" "$VMID" "$VM_NAME" "$USER"

        # Attach the cloud-init ISO to the VM
        echo_info "$USER: Attaching cloud-init ISO to VM $VMID..."
        sudo /usr/sbin/qm set "$VMID" --ide2 "local:iso/$(basename "$CLOUDINIT_ISO")",media=cdrom

        # Enable QEMU Guest Agent
        echo_info "$USER: Enabling QEMU Guest Agent for VM $VMID..."
        sudo /usr/sbin/qm set "$VMID" --agent enabled=1

        # Start the VM
        echo_info "$USER: Starting VM $VMID..."
        sudo /usr/sbin/qm start "$VMID"

        # Clean up temporary files
        rm -f "$USERDATA_FILE" "$METADATA_FILE"

        # Wait for the VM to start and become ready
        wait_vm_start "$VMID" "$USER"
    else
        # VM exists; check if it's running
        CURRENT_STATE=$(echo "$VM_STATUS" | awk '{print $2}')

        if [ "$CURRENT_STATE" != "running" ]; then
            echo_info "$USER: VM $VMID is not running. Starting VM..."
            sudo /usr/sbin/qm start "$VMID"

            # Wait for the VM to start and become ready
            wait_vm_start "$VMID" "$USER"
        fi
    fi
fi

# Retrieve VM IP from lock file
VM_IP="$(get_vm_ip "$VMID"  "$USER")"

if [[ -z "$VM_IP" ]]; then
    echo_error "$USER: Failed to retrieve VM IP."
    exit 1
fi

echo_info "$USER: VM $VMID has IP address $VM_IP."

# Wait until SSH is available on the VM
echo_info "$USER: Waiting for SSH to be available on VM $VMID at IP $VM_IP..."
TOTAL_TIMEOUT=60  # Total timeout in seconds
SLEEP_INTERVAL=1  # Interval between checks in seconds
ELAPSED_TIME=0

while ! nc -z $VM_IP 22; do
    if [ "$ELAPSED_TIME" -ge "$TOTAL_TIMEOUT" ]; then
        echo_error "$USER: SSH service not available on VM $VMID at IP $VM_IP within $TOTAL_TIMEOUT seconds."
        exit 1
    fi
    sleep "$SLEEP_INTERVAL"
    ELAPSED_TIME=$((ELAPSED_TIME + SLEEP_INTERVAL))
done

echo_info "$USER: SSH is available on VM $VMID at IP $VM_IP."

# Update last active time
touch "$LAST_ACTIVE_FILE"

exec nc -q0 $VM_IP 22
