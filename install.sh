#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
pushd "$SCRIPT_DIR" >/dev/null

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo_error "Please run as root"
    exit 1
fi

apt-get install jq

mkdir -p /etc/auto_vm/
cp ./config/auto_vm_config.sh /etc/auto_vm/

cp ./scripts/*.sh /usr/local/bin
ln -s /usr/bin/vm_login.sh /usr/local/bin/vm_login.sh

# Create the vmusers group if it does not exist
if ! getent group vmusers > /dev/null; then
    echo "\e[32m[INFO]\e[0m Creating group 'vmusers'..."
    groupadd vmusers
fi

popd > /dev/null