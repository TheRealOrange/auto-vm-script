#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Define the path to the vm_cleanup cron file
CRON_FILE="/etc/cron.d/vm_cleanup"

# Define the path to the logrotate config file
LOGROTATE_CONFIG="/etc/logrotate.d/auto_vm"

# Function to display informational messages
echo_info() {
    local message="$1"
    echo -e "\e[32m[INFO]\e[0m $message"
}

# Function to display error messages
echo_error() {
    local message="$1"
    echo -e "\e[31m[ERROR]\e[0m $message" >&2
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
pushd "$SCRIPT_DIR" >/dev/null
trap 'popd >/dev/null' EXIT

# Scripts Installed to /usr/local/bin
SCRIPTS=(
    "add_new_user.sh"
    "remove_user.sh"
    "update_vm_template.sh"
    "vm_cleanup.sh"
    "vm_login.sh"
)
echo_info "Updating package lists..."
apt-get update -y

echo_info "Installing necessary dependencies..."
apt-get install -y jq lsof

echo_info "Creating configuration directory /etc/auto_vm/..."
mkdir -p /etc/auto_vm/

echo_info "Copying configuration file to /etc/auto_vm/..."
cp ./config/auto_vm_config.sh /etc/auto_vm/
chmod +x /etc/auto_vm/auto_vm_config.sh

echo_info "Copying scripts to /usr/local/bin/..."
cp ./scripts/*.sh /usr/local/bin/

for script in "${SCRIPTS[@]}"; do
    chmod +x "/usr/local/bin/$script"
done

echo_info "Setting executable permissions for the scripts..."
for script in "${SCRIPTS[@]}"; do
    chmod +x "/usr/local/bin/$script"
done

echo_info "Creating symbolic link for vm_login.sh..."
ln -sf /usr/local/bin/vm_login.sh /usr/bin/vm_login.sh

echo_info "Creating 'vmusers' group if it does not exist..."
if ! getent group vmusers > /dev/null; then
    groupadd vmusers
    echo_info "Group 'vmusers' created successfully."
else
    echo_info "Group 'vmusers' already exists. Skipping creation."
fi

# Now setup the cron job to run cleanup every minute
echo_info "Setting up cron job for vm_cleanup.sh to run every minute..."

# Define the cron job line
CRON_JOB="* * * * * root /usr/local/bin/vm_cleanup.sh"

# Check if the cron job already exists to prevent duplication
if [[ -f "$CRON_FILE" ]]; then
    if grep -Fxq "$CRON_JOB" "$CRON_FILE"; then
        echo_info "Cron job already exists in $CRON_FILE. Skipping addition."
    else
        echo_info "Adding cron job to existing $CRON_FILE..."
        echo "$CRON_JOB" >> "$CRON_FILE"
        echo_info "Cron job added successfully."
    fi
else
    echo_info "Creating new cron file at $CRON_FILE..."
    echo "$CRON_JOB" > "$CRON_FILE"
    echo_info "Cron job created successfully."
fi

# Set appropriate permissions for the cron file
chmod 644 "$CRON_FILE"

# Ensure the vm_cleanup.log file exists and has appropriate permissions
LOG_DIR="/var/log/auto_vm"
mkdir -p "$LOG_DIR"
touch "$LOG_DIR/vm_cleanup.log"
chmod 644 "$LOG_DIR/vm_cleanup.log"

echo_info "Cron job setup completed successfully."

# Now, set up log rotation for the log files
echo_info "Setting up log rotation for VM management logs..."

# Define the logrotate configuration for logs
LOGROTATE_CONTENT="/var/log/auto_vm/vm_management.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    delaycompress
    create 664 root vmusers
    sharedscripts
    postrotate
        # Reload services if necessary
        # systemctl reload your_service_name > /dev/null 2>&1 || true
    endscript
}

/var/log/auto_vm/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    delaycompress
    create 644 root vmusers
    sharedscripts
    postrotate
        # Reload services if necessary
        # systemctl reload your_service_name > /dev/null 2>&1 || true
    endscript
}" 

# Create or append the logrotate configuration for vm_management.log
if [[ -f "$LOGROTATE_CONFIG" ]]; then
    echo_info "Logrotate configuration for already exists at $LOGROTATE_CONFIG. Skipping addition."
else
    echo_info "Creating logrotate configuration at /etc/logrotate.d/auto_vm..."
    echo "$LOGROTATE_CONTENT" > /etc/logrotate.d/auto_vm
    chmod 644 /etc/logrotate.d/auto_vm
    echo_info "Logrotate configuration created successfully."
fi

echo_info "Log rotation setup completed successfully."

echo_info "Installation completed successfully."

exit 0