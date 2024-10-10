#!/bin/bash

# Script to add a new vm_user_xx user and generate/set up SSH access

# Exit immediately if a command exits with a non-zero status
set -e

LOCK_DIR="/var/lock/auto_vm"  # Directory to store lock and last active files
LOG_DIR="/var/log/auto_vm"
USER_LOG_FILE="${LOG_DIR}/user.log"
LOGIN_LOG_FILE="${LOG_DIR}/vm_management.log"

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "\e[31m[ERROR]\e[0m Please run as root."
    exit 1
fi

# Create the vmusers group if it does not exist
if ! getent group vmusers > /dev/null; then
    echo "\e[32m[INFO]\e[0m Creating group 'vmusers'..."
    groupadd vmusers
fi

# Ensure LOG_DIR exists
mkdir -p $LOG_DIR

# Ensure log files exists with proper permissions
touch "$USER_LOG_FILE"
chmod 640 "$USER_LOG_FILE"

touch "$LOGIN_LOG_FILE"
chown root:vmusers "$LOGIN_LOG_FILE"
chmod 660 "$LOGIN_LOG_FILE"

# Ensure LOCK_DIR exists with proper permissions
mkdir -p $LOCK_DIR
chown root:vmusers "$LOCK_DIR"
chmod 774 "$LOCK_DIR"

# Function to display informational messages
echo_info() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\e[32m[INFO]\e[0m $1"
    flock -w 5 "$USER_LOG_FILE" -c "echo '[$timestamp][INFO] $1' >> \"$USER_LOG_FILE\""
}

# Function to display error messages
echo_error() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "\e[31m[ERROR]\e[0m $1" >&2
    flock -w 5 "$USER_LOG_FILE" -c "echo '[$timestamp][ERROR] $1' >> \"$USER_LOG_FILE\""
}

# Function to display usage information
usage() {
    echo "Usage: $0 username 'ssh-public-key'"
    echo "Example: $0 vm_user_00 'ssh-ed25519 AA...'"
    exit 1
}

# Check if the correct number of arguments is provided
if [[ $# -ne 2 ]]; then
    usage
fi

USERNAME=$1
PUBKEY=$2

# Validate username format
if [[ ! "$USERNAME" =~ ^vm_user_[0-9]{2}$ ]]; then
    echo_error "Invalid username format. Username must be in the format vm_user_xx, where xx is a number 00-99."
    exit 1
fi

# Check if the user already exists
if id "$USERNAME" &>/dev/null; then
    echo_error "User $USERNAME already exists."
    exit 1
fi

# Create the user with no password, set the shell to /bin/bash, and add to vmusers group
echo_info "Creating user $USERNAME..."
useradd -m -s /bin/bash -G vmusers "$USERNAME"

# Define the .ssh directory inside the user's home
USER_SSH_DIR="/home/${USERNAME}/.ssh"

# Create the .ssh directory for the user
mkdir -p "$USER_SSH_DIR"

# Define the directory to store SSH keys
SSH_KEYS_DIR="$USER_SSH_DIR"/keys
PUBLIC_KEY_PATH="${SSH_KEYS_DIR}/${USERNAME}_id.pub"

# Create the directory for SSH keys if it doesn't exist
mkdir -p "$SSH_KEYS_DIR"

# Add the public key to authorized_keys
echo "$PUBKEY" > "$USER_SSH_DIR"/authorized_keys

# Store the public key for importing into the VM
touch $PUBLIC_KEY_PATH
echo "$PUBKEY" > "$PUBLIC_KEY_PATH"

# Set the appropriate permissions
chown -R "$USERNAME":"$USERNAME" "$USER_SSH_DIR"
chmod 700 "$USER_SSH_DIR"
chmod 600 "$USER_SSH_DIR"/authorized_keys

# Set appropriate permissions for the SSH keys
chmod 700 "$SSH_KEYS_DIR"
chmod 644 "$PUBLIC_KEY_PATH"

# Change ownership of the SSH keys directory
chown -R "$USERNAME":"$USERNAME" "$SSH_KEYS_DIR"

# Provide the public key path for cloud-init integration
echo_info "Public key for $USERNAME is available at $PUBLIC_KEY_PATH"

exit 0
