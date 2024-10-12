# /etc/auto_vm_config.sh

# Directories DO NOT EDIT THESE AFTER INSTALLING
LOCK_DIR="/var/lock/auto_vm"
CLOUDINIT_DIR="/var/lib/vz/template/iso"
LOG_DIR="/var/log/auto_vm"
USERDATA_DIR="/tmp"
METADATA_DIR="/tmp"

# Log Files DO NOT EDIT THESE AFTER INSTALLING
VM_MANAGEMENT_LOG="${LOG_DIR}/vm_management.log"
VM_CLEANUP_LOG="${LOG_DIR}/vm_cleanup.log"
VM_USER_LOG="${LOG_DIR}/user.log"
VM_UPDATE_LOG="${LOG_DIR}/vm_update.log"

# VM Settings THESE CAN BE EDITED AFTER INSTALLING
TEMPLATE_ID=9000
TEMPLATE_NAME="debian-docker-template"
TEMP_VM_ID=9999  # Temporary VM ID for updating
TEMP_VM_NAME="template-update-vm"
VM_DISK_ID="virtio0"
USER_VM_DISK_SIZE="64G" # Ensure this is larger than the template disk size

# Timeout Settings THESE CAN BE EDITED AFTER INSTALLING
INACTIVITY_THRESHOLD=20          # Inactivity threshold in minutes
TOTAL_TIMEOUT_VM_START=120       # Timeout for VM to start in seconds
TOTAL_TIMEOUT_SSH=60             # Timeout for SSH availability in seconds
TOTAL_TIMEOUT_SHUTDOWN=60        # Timeout for VM to shut down due to inactivity
SLEEP_INTERVAL_VM_START=2        # Sleep interval for VM start checks
SLEEP_INTERVAL_SSH=1             # Sleep interval for SSH availability checks
SLEEP_INTERVAL_SHUTDOWN=5        # Sleep interval for VM shutdown checks

# Naming Conventions DO NOT EDIT THESE AFTER INSTALLING
USER_PREFIX="vm_user_"
VM_PREFIX="user-vm-"
VM_ID_START="2" # Defined X by default such that the VMs number from X00, up to X99

# Executables DO NOT EDIT THESE AFTER INSTALLING
CLOUD_LOCALDS_CMD="/usr/bin/cloud-localds"
QM_CMD="/usr/sbin/qm"
NC_CMD="/bin/nc"
LSOF_CMD="/usr/bin/lsof"
