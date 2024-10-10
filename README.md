# Auto VM Script
This repo contains the scripts necessary to configure a Proxmox VE instance to spin up VMs for users upon SSH login, and redirect the user's SSH session to the VM. Any new connections from the same user will connect to the same VM, and the VM will be shutdown (or destroyed, can be configured) once there are no active sessions for more than 15 minutes. The script will (almost) seamlessly redirect the SSH login.

This is mostly useful for sharing compute resources to users in a way which isolates each user instance and ensures a repeatable/standardized environment. (Particularly useful when users do not have linux machines available)

## What does it do?

#### `vm_login.sh`
This script will redirect the user login to a VM, and it will spin up a new VM if there is no existing VM, transferring the correct ssh keys to the VM, obtaining the IP address to the VM, and redirecting the SSH connection using `nc` to proxy the connection. (This relies on the user having set an appropriate `ProxyCommand` in their SSH config file)

#### `update_vm_template.sh`
This script aids in keeping a VM template (`ID 9000`) up to date by creating a VM from it, updating the VM, and replacing the template with the updated VM.

#### `vm_cleanup.sh`
This script will check for active VMs and check if there are any active SSH connections associated with the user for the VMs. If there are none and the elapsed idle time since the last connection was active is greater than 15 minutes, the VM will be shutdown (can be modified to destroy the VM). This script is meant to be run every minute in a cron job.

#### `add_new_user.sh`
It adds a new user given a username in the format `vm_user_xx` and a public key.

#### `remove_user.sh`
Removes a specified user and cleans up any associated VMs.

## Setup
Ensure you have Proxmox VE installed, and you have configured a VM template with `ID 9000` (or one that matches the constant in `config/auto_vm_config.sh`), which has `cloud-init`, `qemu-guest-agent`, and `ssh` installed and enabled to run on startup.

Set all the necessary constants in `config/auto_vm_config.sh` as per your needs.

Then, ensure your Proxmox VE instance has `nc` for proxying ssh.

Run the install script `install.sh` as root, which will do the following
- install the dependencies `lsof`, `jq`, and `sudo`
- copy the configuration file to `/etc/auto_vm/auto_vm_config.sh`
- copy the scripts under `scripts` to `/usr/local/bin`
- makes the scripts executable
- symlinks `/usr/local/bin/vm_login.sh` to `/usr/bin/vm_login.sh` such that it can be accesed from a `rbash` shell
- create the group `vmusers`
- setup a cron job to run `vm_cleanup.sh` every minute
- setup a logrotate config to manage the log files generated
- add the `/etc/sudoers.d/vm_users` file to include the of `sudoers.d/vm_users.template` to allow the `vmusers` group to run the necessary commands to create and start the VM.
- add the contents of `sshd_config.vm_login.template` to the end of your `/etc/ssh/sshd_config` file. This will run the `vm_login.sh` script for all users who match the specified `USER_PREFIX`.

The `remove.sh` script will undo most of these and remove logs, except the apt packages will not be removed.

## Users
To add users, you require a SSH public key of the user. Then, simply use the `add_new_user.sh` script to add a new user `vm_user_XX`. The user will have to add the following configuration to their local SSH config

    Host jump_host
        HostName <your server IP/URL here>
        User vm_user_XX
        AddKeysToAgent yes
        IdentityFile <path_to_your_private_key_here>

    Host docker_vm
        ProxyCommand ssh -q jump_host
        User vm_user_XX
        AddKeysToAgent yes
        IdentityFile <path_to_your_private_key_here>

## How it works

How this works is by taking advantage of the `ForceCommand` argument available in `sshd_config`. The command is executed in the user's login shell. By using the `vm_login.sh` script, we can handle spinning up a VM when there is none created, relying on `cloud-init` to add the ssh keys and then subsequently using the QEMU Guest Agent to retrieve the new VM's IP address. 

