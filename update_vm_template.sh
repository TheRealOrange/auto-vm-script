#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

LOG_DIR="/var/log/auto_vm"
LOG_FILE="${LOG_DIR}/vm_update.log"

# Ensure LOG_DIR exists
mkdir -p $LOG_DIR

# Ensure log files exists with proper permissions
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

# Variables
TEMPLATE_ID=9000
TEMPLATE_NAME="debian-docker-template"
TEMP_VM_ID=9999  # Temporary VM ID for updating
TEMP_VM_NAME="template-update-vm"

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

# Check if the temporary VM already exists and remove it
if qm status "$TEMP_VM_ID" &>/dev/null; then
    echo_info "Removing existing temporary VM (ID: $TEMP_VM_ID)..."
    qm stop "$TEMP_VM_ID" || true
    qm destroy "$TEMP_VM_ID" --purge || true
    echo_info "Temporary VM removed."
fi

# Clone the template to a temporary VM
echo_info "Cloning template (ID: $TEMPLATE_ID) to temporary VM (ID: $TEMP_VM_ID)..."
qm clone "$TEMPLATE_ID" "$TEMP_VM_ID" --name "$TEMP_VM_NAME" --full 2>&1 | grep -v '^transferred'
echo_info "Clone completed."

# Enable QEMU Guest Agent
echo_info "Enabling QEMU Guest Agent for temporary VM (ID: $TEMP_VM_ID)..."
qm set "$TEMP_VM_ID" --agent enabled=1

# Start the temporary VM
echo_info "Starting temporary VM (ID: $TEMP_VM_ID)..."
qm start "$TEMP_VM_ID"

# Wait for the VM to boot and Guest Agent to be available
echo_info "Waiting for temporary VM to become ready..."
TOTAL_TIMEOUT=120  # Total timeout in seconds
SLEEP_INTERVAL=5   # Interval between checks in seconds
ELAPSED_TIME=0

while [ $ELAPSED_TIME -lt $TOTAL_TIMEOUT ]; do
    VM_STATUS=$(qm status "$TEMP_VM_ID" | awk '{print $2}')
    if [ "$VM_STATUS" == "running" ]; then
        if qm agent "$TEMP_VM_ID" ping &>/dev/null; then
            echo_info "Temporary VM is up and Guest Agent is available."
            break
        else
            echo_info "Guest Agent not yet available..."
        fi
    else
        echo_info "Temporary VM is not yet running..."
    fi

    sleep "$SLEEP_INTERVAL"
    ELAPSED_TIME=$((ELAPSED_TIME + SLEEP_INTERVAL))
done

# Check if timeout was reached
if [ $ELAPSED_TIME -ge $TOTAL_TIMEOUT ]; then
    echo_error "Temporary VM did not become ready within $TOTAL_TIMEOUT seconds."
    exit 1
fi

# Define the commands to update the VM, including GRUB timeout adjustment
echo_info "Updating the temporary VM (ID: $TEMP_VM_ID)..."

# Commands to run inside the VM
UPDATE_COMMANDS=$(cat <<'EOF'
# Update package lists and upgrade installed packages
apt update && apt upgrade -y

# Install Docker components
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Clean up unused packages and caches
apt autoremove -y && apt clean

# Remove SSH host keys
rm -f /etc/ssh/ssh_host_*

# Reset machine-id
rm /etc/machine-id && touch /etc/machine-id

# Truncate log files
find /var/log -type f -exec truncate -s 0 {} \;

# Clear shell history
history -c && rm -f ~/.bash_history

# Clean cloud-init data
cloud-init clean

# Automate GRUB timeout adjustment
# Replace GRUB_TIMEOUT value with 1, or append if not present
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' /etc/default/grub || echo "GRUB_TIMEOUT=1" >> /etc/default/grub

# Update GRUB to apply changes
update-grub
EOF
)

# Execute the update commands inside the VM
qm guest exec "$TEMP_VM_ID" -- bash -c "$UPDATE_COMMANDS"

echo_info "Update commands executed successfully."

# Shut down the temporary VM
echo_info "Shutting down temporary VM (ID: $TEMP_VM_ID)..."
qm shutdown "$TEMP_VM_ID"

# Wait for the VM to shut down
TOTAL_TIMEOUT_SHUTDOWN=60  # Total timeout in seconds
ELAPSED_TIME_SHUTDOWN=0

while qm status "$TEMP_VM_ID" | grep -q "running"; do
    echo_info "Temporary VM is still running..."
    sleep 5
    ELAPSED_TIME_SHUTDOWN=$((ELAPSED_TIME_SHUTDOWN + 5))
    if [ $ELAPSED_TIME_SHUTDOWN -ge $TOTAL_TIMEOUT_SHUTDOWN ]; then
        echo_error "Temporary VM did not shut down in time."
        exit 1
    fi
done

echo_info "Temporary VM has been shut down."

# Convert the updated VM back into a template
echo_info "Converting updated VM back into the template (ID: $TEMPLATE_ID)..."

# Destroy the old template
echo_info "Destroying old template (ID: $TEMPLATE_ID)..."
qm destroy "$TEMPLATE_ID" --purge || true

# Clone the updated VM to the template ID
echo_info "Cloning the updated VM (ID: $TEMP_VM_ID) to template ID $TEMPLATE_ID..."
qm clone "$TEMP_VM_ID" "$TEMPLATE_ID" --name "$TEMPLATE_NAME" --full 2>&1 | grep -v '^transferred'
echo_info "Clone to template completed."

# Convert the new VM to a template
echo_info "Converting VM (ID: $TEMPLATE_ID) to a template..."
qm template "$TEMPLATE_ID"

# Destroy the temporary VM
echo_info "Destroying temporary VM (ID: $TEMP_VM_ID)..."
qm destroy "$TEMP_VM_ID" --purge

echo_info "Template '$TEMPLATE_NAME' (ID: $TEMPLATE_ID) has been successfully updated with GRUB timeout set to 2 seconds."
