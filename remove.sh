#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

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

# Check if the script is run as root
if [[ "$EUID" -ne 0 ]]; then
    echo "Please run as root."
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

# Path to the vm_cleanup cron file
CRON_FILE="/etc/cron.d/vm_cleanup"

# Define the path to the logrotate config file
LOGROTATE_CONFIG="/etc/logrotate.d/auto_vm"

# Path to the sudoers.d file
SUDOERS_FILE="/etc/sudoers.d/vm_users"

# Path to the SSHD config
SSHD_CONFIG="/etc/ssh/sshd_config"

# Function to remove a file if it exists
remove_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        rm -f "$file" && echo_info "Removed file: $file"
    else
        echo_info "File not found, skipping: $file"
    fi
}

# Function to remove a directory if it exists and is empty
remove_dir_if_empty() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        if [[ -z "$(ls -A "$dir")" ]]; then
            rmdir "$dir" && echo_info "Removed empty directory: $dir"
        else
            echo_info "Directory not empty, skipping removal: $dir"
        fi
    else
        echo_info "Directory not found, skipping: $dir"
    fi
}

# Function to remove a directory and its contents
remove_dir_recursive() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        rm -rf "$dir" && echo_info "Removed directory and contents: $dir"
    else
        echo_info "Directory not found, skipping: $dir"
    fi
}

# Function to remove a group if it exists and is empty
remove_group_if_empty() {
    local group="$1"
    if getent group "$group" >/dev/null; then
        local group_members
        group_members=$(getent group "$group" | awk -F: '{print $4}')
        if [[ -z "$group_members" ]]; then
            groupdel "$group" && echo_info "Removed group: $group"
        else
            echo_info "Group '$group' is not empty, skipping removal."
        fi
    else
        echo_info "Group '$group' does not exist, skipping."
    fi
}

# Function to remove the cron job
remove_cron_job() {
    local cron_file="$1"
    if [[ -f "$cron_file" ]]; then
        rm -f "$cron_file" && echo_info "Removed cron job file: $cron_file"
    else
        echo_info "Cron job file not found, skipping: $cron_file"
    fi
}

# Function to remove the logrotate configuration
remove_logrotate_config() {
    local logrotate_config="$1"
    if [[ -f "$logrotate_config" ]]; then
        rm -f "$logrotate_config" && echo_info "Removed logrotate configuration file: $logrotate_config"
    else
        echo_info "Logrotate configuration file not found, skipping: $logrotate_config"
    fi
}

# Function to remove the sudoers file
remove_sudoers_file() {
    local sudoers_file="$1"
    if [[ -f "$sudoers_file" ]]; then
        rm -f "$sudoers_file" && echo_info "Removed sudoers file: $sudoers_file"
    else
        echo_info "Sudoers file not found, skipping: $sudoers_file"
    fi
}

# Function to remove SSH configurations using the template
remove_sshd_config() {
    local sshd_config="$1"

    # Check if the configuration block exists in sshd_config
    if grep -Fq "Match User ${USER_PREFIX}*" "$sshd_config"; then
        echo_info "Removing SSH configuration for users with prefix '${USER_PREFIX}' from $sshd_config..."
        # Use awk to remove the block between the marker comment and the last line
        awk -v prefix="Match User ${USER_PREFIX}*" '
            /# VM Management SSH Configuration block \(DO NOT EDIT\)/ {flag=1; next}
            flag && $0 ~ prefix {next}
            flag && $0 ~ /# End of VM Management SSH Configuration block/ {flag=0; next}
            !flag
            ' "$sshd_config" > "${sshd_config}.tmp" && mv "${sshd_config}.tmp" "$sshd_config"
        echo_info "SSH configuration removed successfully."
    else
        echo_info "SSH configuration for users with prefix '${USER_PREFIX}' not found in $sshd_config. Skipping removal."
    fi
}

echo_info "Starting uninstallation of VM management scripts..."

# Remove sudoers.d/vm_users
echo_info "Removing sudoers configuration for vm_users..."
remove_sudoers_file "$SUDOERS_FILE"

# Remove SSH configurations using the template
echo_info "Removing SSH configurations..."
remove_sshd_config "$SSHD_CONFIG"

# Remove logrotate configurations
echo_info "Removing logrotate configuration..."
remove_logrotate_config "$LOGROTATE_CONFIG"

# Remove cron job
echo_info "Removing cron job for vm_cleanup.sh..."
remove_cron_job "$CRON_FILE"

# Scripts Installed to /usr/local/bin
SCRIPTS=(
    "add_new_user.sh"
    "remove_user.sh"
    "update_vm_template.sh"
    "vm_cleanup.sh"
    "vm_login.sh"
)

# Path to the remove_user.sh script
REMOVE_USER_SCRIPT="/usr/local/bin/remove_user.sh"

# Check if remove_user.sh exists and is executable
if [[ ! -x "$REMOVE_USER_SCRIPT" ]]; then
    echo "remove_user.sh script not found or not executable at $REMOVE_USER_SCRIPT. Exiting."
    exit 1
fi

echo_info "Starting removal of all managed users, prefix: ${USER_PREFIX}..."

# Iterate over all users matching the naming convention
getent passwd | grep -E "^${USER_PREFIX}[0-9]{2}:" | cut -d: -f1 | while read -r USERNAME; do
    if [[ -n "$USERNAME" ]]; then
        echo_info "Removing user: $USERNAME"
        # Run remove_user.sh in force mode to bypass confirmation
        "$REMOVE_USER_SCRIPT" -f "$USERNAME"
    fi
done

echo_info "All managed users have been removed."

# Remove symbolic links
echo_info "Removing symbolic links..."
remove_file /usr/bin/vm_login.sh

# Remove installed scripts from /usr/local/bin
echo_info "Removing installed scripts from /usr/local/bin..."
for script in "${SCRIPTS[@]}"; do
    remove_file "/usr/local/bin/$script"
done

# Remove log directories and files
echo_info "Removing log directories and files..."
remove_dir_recursive "$LOG_DIR"

# Remove lock directories and files
echo_info "Removing lock directories and files..."
remove_dir_recursive "$LOCK_DIR"

# Remove configuration files from /etc/auto_vm/
echo_info "Removing configuration files..."
remove_file "/etc/auto_vm/auto_vm_config.sh"

# Remove /etc/auto_vm/ directory if empty
echo_info "Removing /etc/auto_vm/ directory if empty..."
remove_dir_if_empty "/etc/auto_vm"

# Remove the vmusers group if it exists and is empty
echo_info "Removing group vmusers if it's empty..."
remove_group_if_empty vmusers

echo_info "Uninstallation of VM management scripts completed successfully. Please restart SSHD to apply changes."

exit 0