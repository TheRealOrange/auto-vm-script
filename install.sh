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

apt-get install -y jq netcat lsof

mkdir -p /etc/auto_vm/
cp ./config/auto_vm_config.sh /etc/auto_vm/
chmod +x /etc/auto_vm/auto_vm_config.sh

cp ./scripts/*.sh /usr/local/bin
chmod +x /usr/local/bin/vm_login.sh
chmod +x /usr/local/bin/vm_cleanup.sh
chmod +x /usr/local/bin/add_new_user.sh
chmod +x /usr/local/bin/remove_user.sh
chmod +x /usr/local/bin/update_vm_template.sh
ln -s /usr/local/bin/vm_login.sh /usr/bin/vm_login.sh

# Create the vmusers group if it does not exist
if ! getent group vmusers > /dev/null; then
    echo "\e[32m[INFO]\e[0m Creating group 'vmusers'..."
    groupadd vmusers
fi