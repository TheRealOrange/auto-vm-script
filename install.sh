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

# Define the paths to the configuration templates
SUDOERS_TEMPLATE="sudoers.d/vm_users.template"
SSHD_TEMPLATE="sshd_config.vm_login.template"

# Define the path to the sudoers.d file
SUDOERS_FILE="/etc/sudoers.d/vm_users"

# Define the path to the SSHD config
SSHD_CONFIG="/etc/ssh/sshd_config"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
pushd "$SCRIPT_DIR" >/dev/null
trap 'popd >/dev/null' EXIT

# Source the configuration file
CONFIG_FILE="./config/auto_vm_config.sh"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "Configuration file $CONFIG_FILE not found. Exiting."
    exit 1
fi

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

# Function to append SSH configurations
append_sshd_config() {
    local sshd_template="$1"
    local sshd_config="$2"

    # Check if the sudoers template exists
    if [[ ! -f "$sshd_template" ]]; then
        echo_error "SSHD config template file '$sshd_template' not found."
        exit 1
    fi

    # Check if the configuration already exists to prevent duplication
    if grep -Fq "Match User ${USER_PREFIX}*" "$sshd_config"; then
        echo_info "SSH configuration for users with prefix '${USER_PREFIX}' already exists in $sshd_config. Skipping addition."
    else
        echo_info "Appending SSH configuration for users with prefix '${USER_PREFIX}' to $sshd_config..."
        # Substitute variables using sed
        echo_info "Configuring $sudoers_file..."
        sed -e "s|\${USER_PREFIX}|$USER_PREFIX|g" \
            "$sshd_template" >> "$sshd_config"
        echo_info "SSH configuration appended successfully."
    fi
}

# Function to create sudoers.d/vm_users
create_sudoers_file() {
    local sudoers_template="$1"
    local sudoers_file="$2"

    # Check if the sudoers template exists
    if [[ ! -f "$sudoers_template" ]]; then
        echo_error "Sudoers template file '$sudoers_template' not found."
        exit 1
    fi

    echo_info "QM_CMD: $QM_CMD"
    echo_info "CLOUD_LOCALDS_CMD: $CLOUD_LOCALDS_CMD"

    # Substitute variables using sed
    echo_info "Configuring $sudoers_file..."
    sed -e "s|\${QM_CMD}|$QM_CMD|g" \
        -e "s|\${CLOUD_LOCALDS_CMD}|$CLOUD_LOCALDS_CMD|g" \
        "$sudoers_template" > "$sudoers_file"

    # Set correct permissions
    chmod 440 "$sudoers_file"

    # Validate the sudoers file syntax
    if visudo -cf "$sudoers_file"; then
        echo_info "Sudoers configuration validated successfully."
    else
        echo_error "Sudoers configuration validation failed. Please check the file."
        exit 1
    fi

    echo_info "Sudoers configuration created successfully at $sudoers_file."
}

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
apt-get install -y jq lsof sudo

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


# ------------------------------
# Adding the Cron Job
# ------------------------------

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
mkdir -p "$LOG_DIR"
touch "$VM_CLEANUP_LOG"
chmod 644 "$VM_CLEANUP_LOG"

echo_info "Cron job setup completed successfully."


# ------------------------------
# Adding logrotate Configuration
# ------------------------------

echo_info "Setting up log rotation for VM management logs..."

# Define the logrotate configuration for logs
LOGROTATE_CONTENT="${LOG_DIR}/vm_management.log {
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

${LOG_DIR}/*.log {
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

# ------------------------------
# Configuring sudoers file
# ------------------------------

echo_info "Configuring $SUDOERS_FILE..."

create_sudoers_file "$SUDOERS_TEMPLATE" "$SUDOERS_FILE"

# ------------------------------
# Configuring SSHD
# ------------------------------

echo_info "Configuring SSHD to force vm_login.sh for users with prefix '${USER_PREFIX}'..."

append_sshd_config "$SSHD_TEMPLATE" "$SSHD_CONFIG"

echo_info "Installation completed successfully. Please restart SSHD to apply new configuration."

exit 0