#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
pushd "$SCRIPT_DIR" >/dev/null
trap 'popd >/dev/null' EXIT

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Scripts Installed to /usr/local/bin
SCRIPTS=(
    "add_new_user.sh"
    "remove_user.sh"
    "update_vm_template.sh"
    "vm_cleanup.sh"
    "vm_login.sh"
)

apt-get install -y jq netcat lsof

mkdir -p /etc/auto_vm/
cp ./config/auto_vm_config.sh /etc/auto_vm/
chmod +x /etc/auto_vm/auto_vm_config.sh

cp ./scripts/*.sh /usr/local/bin

for script in "${SCRIPTS[@]}"; do
    chmod +x "/usr/local/bin/$script"
done

ln -s /usr/local/bin/vm_login.sh /usr/bin/vm_login.sh

# Create the vmusers group if it does not exist
if ! getent group vmusers > /dev/null; then
    echo "\e[32m[INFO]\e[0m Creating group 'vmusers'..."
    groupadd vmusers
fi