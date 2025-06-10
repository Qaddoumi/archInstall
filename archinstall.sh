#!/bin/bash

# Disk Wipe and Arch Linux Preparation Script
# Version 0.4 - More robust cleanup handling

set -uo pipefail  # Strict error handling

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # rest the color to default

error() {
    echo -e "${RED}[ERROR] $*${NC}" >&2
    exit 1
}

info() {
    echo -e "${GREEN}[*] $*${NC}"
}

newTask() {
    echo -e "${GREEN}$*${NC}"
}

warn() {
    echo -e "${YELLOW}[WARN] $*${NC}"
}

# Check root
[[ $(id -u) -eq 0 ]] || error "This script must be run as root"

read -rsp "Enter root password: " ROOT_PASSWORD
echo
read -rsp "Confirm root password: " ROOT_PASSWORD_CONFIRM
echo
if [[ "$ROOT_PASSWORD" != "$ROOT_PASSWORD_CONFIRM" ]]; then
    error "Root passwords do not match. Aborting."
fi
if [[ -z "$ROOT_PASSWORD" ]]; then
    error "Root password cannot be empty. Aborting."
fi

# Ask for username
read -rp "Enter username: " USERNAME

# Ask for user password
read -rsp "Enter password for $USERNAME: " USER_PASSWORD
echo
read -rsp "Confirm password for $USERNAME: " USER_PASSWORD_CONFIRM
echo
if [[ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]]; then
    error "User passwords do not match. Aborting."
fi

export ROOT_PASSWORD
export USERNAME
export USER_PASSWORD

# List disks
info "Available disks:"
lsblk -d -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT

# Get disk
read -rp "Enter disk to wipe (e.g., vda, sda, nvme0n1): " DISK
[[ -e "/dev/$DISK" ]] || error "Disk /dev/$DISK not found"

# Add NVMe partition naming handler here
if [[ "$DISK" =~ "nvme" ]]; then
    BOOT_PART="/dev/${DISK}p1"
    ROOT_PART="/dev/${DISK}p2"
else
    BOOT_PART="/dev/${DISK}1"
    ROOT_PART="/dev/${DISK}2"
fi

# Show disk info
info "\nSelected disk layout:"
lsblk "/dev/$DISK"

# Final confirmation
read -rp "WARNING: ALL DATA ON /dev/$DISK WILL BE DESTROYED! Confirm (type 'y'): " CONFIRM
[[ "$CONFIRM" == "y" ]] || error "Operation cancelled"

newTask "==================================================\n==================================================\n"
 
# Enhanced cleanup function
cleanup() {
    local attempts=3
    info "Starting cleanup process (3 attempts)...\n"
    
    while (( attempts-- > 0 )); do
        # 1. Kill processes using the disk
        echo
        info "Attempt $((3-attempts)): Killing processes..."
        pids=$(lsof +f -- "/dev/$DISK"* 2>/dev/null | awk '{print $2}' | uniq)
        sleep 2
        [[ -n "$pids" ]] && kill -9 $pids 2>/dev/null
        sleep 2
        for process in $(lsof +f -- /dev/${DISK}* 2>/dev/null | awk '{print $2}' | uniq); do kill -9 "$process"; done
        sleep 2  # Allow time for processes to settle
        # try again to kill any processes using the disk
        lsof +f -- /dev/${DISK}* 2>/dev/null | awk '{print $2}' | uniq | xargs -r kill -9
        sleep 2
        
        # 2. Unmount filesystems (including nested mounts)
        echo
        info "Unmounting partitions..."
        umount -R "/dev/$DISK"* 2>/dev/null
        sleep 2
        
        # 3. Deactivate LVM
        if command -v vgchange &>/dev/null; then
            info "Deactivating LVM..."
            vgchange -an 2>/dev/null
            lvremove -f $(lvs -o lv_path --noheadings 2>/dev/null | grep "$DISK") 2>/dev/null
        fi
        sleep 2
        
        # 4. Disable swap
        echo
        info "Disabling swap..."
        swapoff -a 2>/dev/null
        for swap in $(blkid -t TYPE=swap -o device | grep "/dev/$DISK"); do
            swapoff -v "$swap"
        done
        sleep 2

        # Check and unmount any partitions from the disk before wiping
        echo
        info "Checking for mounted partitions on /dev/$DISK..."
        for part in $(lsblk -lnp -o NAME | grep "^/dev/$DISK" | tail -n +2); do
            info "Attempting to unmount $part..."
            if ! umount "$part" 2>/dev/null; then
                warn "Failed to unmount $part, maybe it was not mounted."
            else
                info "$part unmounted successfully."
            fi
        done
        sleep 2
        
        # 5. Check if cleanup was successful
        if ! (mount | grep -q "/dev/$DISK") && \
           ! (lsof +f -- "/dev/$DISK"* 2>/dev/null | grep -q .); then
            echo
            info "Cleanup successful :) "
            return 0
        fi
        
        sleep 2
    done
    
    warn "Cleanup incomplete - some resources might still be in use"
    return 1
}

# Run cleanup
if ! cleanup; then
    warn "Proceeding with disk operations despite cleanup warnings"
fi

newTask "==================================================\n==================================================\n"

# Wipe disk
info "Wiping disk signatures..."
wipefs -a "/dev/$DISK" || error "Failed to wipe disk"
sleep 2

newTask "==================================================\n==================================================\n"

# Partitioning
info "Creating new GPT partition table..."
parted -s "/dev/$DISK" mklabel gpt || error "Partitioning failed"
sleep 2

newTask "==================================================\n==================================================\n"

# Custom partition sizes
EFI_SIZE="2G"  # Adjust as needed
ROOT_SIZE="100%"  # Remainder for root

info "Creating partitions:"
# EFI Partition
parted -s "/dev/$DISK" mkpart primary fat32 1MiB "$EFI_SIZE" || error "EFI partition failed"
parted -s "/dev/$DISK" set 1 esp on

# Root Partition
parted -s "/dev/$DISK" mkpart primary ext4 "$EFI_SIZE" "$ROOT_SIZE" || error "Root partition failed"
sleep 2

newTask "==================================================\n==================================================\n"

# Formatting
info "Formatting partitions:"
mkfs.fat -F32 "/dev/${DISK}1" || error "EFI format failed"
mkfs.ext4 -F "/dev/${DISK}2" || error "Root format failed"
sleep 2

newTask "==================================================\n==================================================\n"

# Verification
info "Verifying new layout:"
fdisk -l "/dev/$DISK" || error "Verification failed"

newTask "==================================================\n==================================================\n"

# Mounting partitions
info "Mounting partitions for installation..."
mkdir -p /mnt
mount "$ROOT_PART" /mnt || error "Failed to mount root partition"
mkdir -p /mnt/boot
mount "$BOOT_PART" /mnt/boot || error "Failed to mount boot partition"
sleep 2
info "Partitions mounted successfully:"
mount | grep "/dev/$DISK"

newTask "==================================================\n==================================================\n"

# Create swap file with hibernation support
info "Creating swap file with hibernation support..."
create_swap() {
    # Get precise RAM size in bytes (not rounded to GB)
    local ram_bytes=$(awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo)
    local ram_gib=$(awk "BEGIN {print int(($ram_bytes/1073741824)+0.5)}")  # Round to nearest GB
    local swapfile="/mnt/swapfile"
    
    # For hibernation, swap should be RAM size + 10-20% (kernel docs recommendation)
    local swap_size=$(awk "BEGIN {print int($ram_bytes * 1.15)}")  # 15% larger than RAM
    
    info "System has ${ram_gib}GB RAM (precise: $(numfmt --to=iec $ram_bytes))"
    info "Creating swap file for hibernation (size: $(numfmt --to=iec $swap_size))..."
    
    # Create swap file
    dd if=/dev/zero of="$swapfile" bs=1M count=$(($swap_size/1048576)) status=progress || 
        error "Failed to create swap file"
    chmod 600 "$swapfile"
    mkswap "$swapfile" || error "Failed to format swap file"
    swapon "$swapfile" || error "Failed to activate swap"
    
    # Add to fstab (commented out by default)
    echo "# Swap file for hibernation" >> /mnt/etc/fstab
    echo "$swapfile none swap defaults 0 0" >> /mnt/etc/fstab
    echo "resume=UUID=$(blkid -s UUID -o value /dev/${DISK}2)" >> /mnt/etc/default/grub
    
    info "Swap file created successfully:"
    swapon --show
    info "Hibernation support configured in fstab and GRUB"
}

create_swap
sleep 2

newTask "==================================================\n=================================================="

newTask "==== CONFIGURING GRUB & HIBERNATION ===="

# Install essential packages
CPU_VENDOR=$(grep -m 1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
info "Detected CPU vendor: $CPU_VENDOR"
info "Install the proper video drivers based on GPU type"
GPU_TYPE=$(lspci | grep -E "VGA compatible controller" | awk '{print $5}')
if [[ "$GPU_TYPE" == "NVIDIA" ]]; then
    info "NVIDIA GPU detected. Installing NVIDIA drivers..."
    GPU_PACKAGES="nvidia nvidia-utils"
elif [[ "$GPU_TYPE" == "AMD" ]]; then
    info "AMD GPU detected. Installing AMD drivers..."
    GPU_PACKAGES="xf86-video-amdgpu"
elif [[ "$GPU_TYPE" == "Intel" ]]; then
    info "Intel GPU detected. Installing Intel drivers..."
    GPU_PACKAGES="xf86-video-intel"
else
    warn "Unknown GPU type: $GPU_TYPE. Skipping GPU driver installation."
    GPU_PACKAGES=""
fi
info "Installing base system, GRUB and required packages..."
pacstrap /mnt base linux linux-firmware grub efibootmgr os-prober \
    networkmanager openssh sudo nano vim wget git ${CPU_VENDOR}-ucode ${GPU_PACKAGES} || error "Failed to install base packages"
sleep 2

# Ensure /mnt/etc exists before generating fstab
mkdir -p /mnt/etc

# Generate fstab
info "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab || error "Failed to generate fstab"
sleep 2
newTask "==================================================\n==================================================\n"
newTask "==== CHROOT SETUP ===="

# Chroot setup
info "Configuring GRUB and hibernation in chroot..."
arch-chroot /mnt /bin/bash <<EOF || error "Chroot commands failed"

TIMEZONE="Asia/Amman"
LOCALE="en_US.UTF-8"
HOSTNAME="${USERNAME}Arch"

# Set timezone
echo "Setting timezone to ${TIMEZONE}..."
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# Set locale
echo "Setting locale to ${LOCALE}..."
sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# Set hostname and hosts
echo "Setting hostname to ${USERNAME}Arch"

echo "setting hosts file"
echo "$HOSTNAME" > /etc/hostname
cat <<HOSTSEOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTSEOF

# Set root password
echo "Setting root password..."
echo "root:${ROOT_PASSWORD}" | chpasswd

# Create user 
echo "Creating user account..."
useradd -m -G wheel -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

# Configure mkinitcpio for hibernation
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck resume)/' /etc/mkinitcpio.conf
mkinitcpio -P
sleep 2

# Install and configure GRUB
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
sleep 2
echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub

# Calculate swapfile offset (critical for hibernation)
SWAPFILE_OFFSET=\$(filefrag -v /swapfile | awk '{ if(\$1=="0:"){print \$4} }')
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet resume=UUID=\$(blkid -s UUID -o value /dev/${DISK}2) resume_offset=\$SWAPFILE_OFFSET\"|" /etc/default/grub

grub-mkconfig -o /boot/grub/grub.cfg
sleep 2

# Enable systemd hibernation service (hypernate on lid close)
mkdir -p /etc/systemd/logind.conf.d
echo "[Login]" > /etc/systemd/logind.conf.d/hibernate.conf
echo "HandleLidSwitch=hibernate" >> /etc/systemd/logind.conf.d/hibernate.conf
echo "HandleLidSwitchExternalPower=hibernate" >> /etc/systemd/logind.conf.d/hibernate.conf

# Enable services
info "Enabling essential services..."
systemctl enable NetworkManager || warn "Failed to enable NetworkManager"
systemctl enable sshd || warn "Failed to enable sshd"

EOF

newTask "==================================================\n=================================================="
newTask "==== FINALIZING INSTALLATION ===="

# Enable network manager (optional)
arch-chroot /mnt systemctl enable NetworkManager.service || warn "NetworkManager not installed"

# Configure sudo (optional)
echo "%wheel ALL=(ALL) ALL" >> /mnt/etc/sudoers || warn "Failed to configure sudo"

sync
sleep 2
umount -R /mnt
sleep 1

newTask "==================================================\n==================================================\n"

info "\n${GREEN}[✓] ARCH LINUX INSTALLATION COMPLETE!${NC}"
echo
echo "you can now reboot."
