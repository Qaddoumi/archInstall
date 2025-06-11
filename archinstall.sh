#!/bin/bash

# Disk Wipe and Arch Linux Preparation Script
# Version 0.4 - More robust cleanup handling

set -uo pipefail  # Strict error handling
trap 'cleanup' EXIT  # Ensure cleanup runs on exit

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # rest the color to default

# Security cleanup function
cleanup() {
    unset ROOT_PASSWORD USER_PASSWORD  # Wipe passwords from memory
    sync
    if mountpoint -q /mnt; then
        umount -R /mnt 2>/dev/null
    fi
}

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

# Verify internet
if ! ping -c 1 archlinux.org &>/dev/null; then
    warn "No internet connection detected!"
    read -rp "Continue without internet? (not recommended) [y/N]: " NO_NET
    [[ "$NO_NET" == "y" ]] || error "Aborted"
fi

# Root password
while true; do
    read -rsp "Enter root password: " ROOT_PASSWORD
    echo
    [[ -n "$ROOT_PASSWORD" ]] || { warn "Password cannot be empty"; continue; }
    
    read -rsp "Confirm root password: " ROOT_PASSWORD_CONFIRM
    echo
    [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD_CONFIRM" ]] && break
    warn "Passwords don't match!"
done

# User account
read -rp "Enter username: " USERNAME
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || error "Invalid username"

while true; do
    read -rsp "Enter password for $USERNAME: " USER_PASSWORD
    echo
    [[ -n "$USER_PASSWORD" ]] || { warn "Password cannot be empty"; continue; }
    
    read -rsp "Confirm password: " USER_PASSWORD_CONFIRM
    echo
    [[ "$USER_PASSWORD" == "$USER_PASSWORD_CONFIRM" ]] && break
    warn "Passwords don't match!"
done

export ROOT_PASSWORD
export USERNAME
export USER_PASSWORD

newTask "==================================================\n==================================================\n"

# List disks
info "Available disks:"
lsblk -d -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT

# Get disk
read -rp "Enter disk to wipe (e.g., vda, sda, nvme0n1): " DISK
[[ -e "/dev/$DISK" ]] || error "Disk /dev/$DISK not found"

# Update partition naming
if [[ "$DISK" =~ "nvme" ]]; then
    BIOS_PART="/dev/${DISK}p1"
    BOOT_PART="/dev/${DISK}p2"
    ROOT_PART="/dev/${DISK}p3"
else
    BIOS_PART="/dev/${DISK}1"
    BOOT_PART="/dev/${DISK}2"
    ROOT_PART="/dev/${DISK}3"
fi

# Show disk info
info "\nSelected disk layout:"
lsblk "/dev/$DISK"

# Final confirmation
read -rp "WARNING: ALL DATA ON /dev/$DISK WILL BE DESTROYED! Confirm (type 'y'): " CONFIRM
[[ "$CONFIRM" == "y" ]] || error "Operation cancelled"

newTask "==================================================\n==================================================\n"
 
# Enhanced cleanup function
cleanup_disks() {
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

# Run cleanup to clean the disk
if ! cleanup_disks; then
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

newTask "==================================================\n=================================================="

# Custom partition sizes
BIOS_BOOT_SIZE="2M"    # New BIOS boot partition
EFI_SIZE="2G"
ROOT_SIZE="100%"

info "Creating partitions"
# BIOS Boot Partition (required for GRUB on GPT)
parted -s "/dev/$DISK" mkpart primary 1MiB "$BIOS_BOOT_SIZE" || error "BIOS boot partition failed"
parted -s "/dev/$DISK" set 1 bios_grub on

# EFI Partition
parted -s "/dev/$DISK" mkpart primary fat32 "$BIOS_BOOT_SIZE" "$EFI_SIZE" || error "EFI partition failed"
parted -s "/dev/$DISK" set 2 esp on

# Root Partition
parted -s "/dev/$DISK" mkpart primary ext4 "$EFI_SIZE" "$ROOT_SIZE" || error "Root partition failed"
sleep 2

newTask "==================================================\n=================================================="

# Formatting
info "Formatting partitions"
mkfs.fat -F32 "$BOOT_PART" || error "EFI format failed"
mkfs.ext4 -F "$ROOT_PART" || error "Root format failed"
sleep 2

newTask "==================================================\n==================================================\n"

# Verification
info "Verifying new layout:"
fdisk -l "/dev/$DISK" || error "Verification failed"

newTask "==================================================\n==================================================\n"

# Mounting partitions
info "Mounting partitions for installation..."
mkdir -p /mnt || error "Failed to create /mnt"
mount "$ROOT_PART" /mnt || error "Failed to mount root partition"
mkdir -p /mnt/boot || error "Failed to create /mnt/boot"
mount "$BOOT_PART" /mnt/boot || error "Failed to mount boot partition"

# Verify mounts
info "Verifying mounts:"
findmnt | grep "/mnt" || error "Mount verification failed"
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
    
    info "Swap file created successfully:"
    swapon --show
}

create_swap
sleep 2

newTask "==================================================\n=================================================="

# Install essential packages
CPU_VENDOR=$(grep -m 1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
info "Detected CPU vendor: $CPU_VENDOR"
# Fix microcode package naming
case "$CPU_VENDOR" in
    "GenuineIntel") UCODE_PKG="intel-ucode" ;;
    "AuthenticAMD") UCODE_PKG="amd-ucode" ;;
    *) UCODE_PKG=""; warn "Unknown CPU vendor: $CPU_VENDOR" ;;
esac

GPU_TYPE=$(lspci | grep -E "VGA|3D" | awk -F': ' '{print $2}')
case "$GPU_TYPE" in
    *NVIDIA*) GPU_PKGS="nvidia nvidia-utils" ;;
    *AMD*)    GPU_PKGS="xf86-video-amdgpu" ;;
    *Intel*)  GPU_PKGS="xf86-video-intel" ;;
    *)        GPU_PKGS=""; warn "Unknown GPU: $GPU_TYPE" ;;
esac
info "Detected ${GPU_PKGS}, Install the proper video drivers"

# Base packages
BASE_PKGS="base linux linux-firmware grub efibootmgr os-prober e2fsprogs networkmanager sudo nano git openssh vim wget"

# Combine packages, filtering out empty ones
INSTALL_PKGS="$BASE_PKGS"
[[ -n "$UCODE_PKG" ]] && INSTALL_PKGS="$INSTALL_PKGS $UCODE_PKG"
[[ -n "$GPU_PKGS" ]] && INSTALL_PKGS="$INSTALL_PKGS $GPU_PKGS"
info "Installing: $INSTALL_PKGS"
pacstrap /mnt $INSTALL_PKGS || error "Package installation failed"
sleep 2

# Ensure /mnt/etc exists before generating fstab
mkdir -p /mnt/etc

# Generate fstab
info "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab || error "Failed to generate fstab"
sleep 2
newTask "==================================================\n=================================================="
info "==== CHROOT SETUP ===="

# Chroot setup
info "Configuring GRUB and hibernation in chroot..."
arch-chroot /mnt /bin/bash <<EOF || error "Chroot commands failed"

set +u

# Pass variables from parent environment
ROOT_PASSWORD="${ROOT_PASSWORD}"
USERNAME="${USERNAME}"
USER_PASSWORD="${USER_PASSWORD}"
DISK="${DISK}"
ROOT_PART="${ROOT_PART}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() {
    echo -e "\${RED}[ERROR] \$*\${NC}" >&2
    exit 1
}
info() {
    echo -e "\${GREEN}[*] \$*\${NC}"
}
newTask() {
    echo -e "\${GREEN}\$*\${NC}"
}
warn() {
    echo -e "\${YELLOW}[WARN] \$*\${NC}"
}

TIMEZONE="Asia/Amman"
LOCALE="en_US.UTF-8"
HOSTNAME="\${USERNAME}Arch"

# Set timezone
info "Setting timezone to \${TIMEZONE}"
ln -sf /usr/share/zoneinfo/\${TIMEZONE} /etc/localtime
hwclock --systohc

# Set locale
info "Setting locale to \${LOCALE}"
sed -i "s/^#\${LOCALE}/\${LOCALE}/" /etc/locale.gen
locale-gen
echo "LANG=\${LOCALE}" > /etc/locale.conf

# Set hostname and hosts
info "Setting hostname to \${HOSTNAME}"
echo "\$HOSTNAME" > /etc/hostname
cat <<HOSTSEOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   \${HOSTNAME}.localdomain \${HOSTNAME}
HOSTSEOF

# Set root password
info "Setting root password"
echo "root:\${ROOT_PASSWORD}" | chpasswd

# Create user 
info "Creating user \${USERNAME} account"
useradd -m -G wheel -s /bin/bash "\${USERNAME}"
echo "\${USERNAME}:\${USER_PASSWORD}" | chpasswd

# Configure mkinitcpio for hibernation
info "Configuring mkinitcpio for hibernation"
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck resume)/' /etc/mkinitcpio.conf
mkinitcpio -P
sleep 2

# Install and configure GRUB
info "Installing GRUB bootloader"
if [[ -d /sys/firmware/efi ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || {
        error "GRUB installation failed"
    }
else
    grub-install --target=i386-pc "/dev/$DISK" || {
        error "GRUB installation failed"
    }
fi
sleep 2

# Configure GRUB for dual boot
info "Configuring GRUB for dual boot"
echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub

# Now configure hibernation with proper error checking
info "Configuring hibernation"
# Get root partition UUID
ROOT_UUID=\$(blkid -s UUID -o value "\${ROOT_PART}")
if [[ -z "\$ROOT_UUID" ]]; then
    warn "Could not get root partition UUID, hibernation may not work properly"
    ROOT_UUID=\$(blkid -s UUID -o value \$(findmnt -n -o SOURCE /))
fi

# Calculate swapfile offset (critical for hibernation)
echo "Calculating swapfile offset for hibernation..."
if [[ ! -f /swapfile ]]; then
    warn "Swapfile not found at /swapfile"
    SWAPFILE_OFFSET=""
fi

# Check if filefrag is available
if ! command -v filefrag >/dev/null 2>&1; then
    warn "filefrag command not found, hibernation may not work"
    SWAPFILE_OFFSET=""
    pacman -S --noconfirm e2fsprogs || {
        warn "Failed to install e2fsprogs which provides filefrag"
    }
fi

# Get swapfile offset with multiple methods for robustness
SWAPFILE_OFFSET=\$(filefrag -v /swapfile 2>/dev/null | awk 'NR==4 {gsub(/\\.\\.*/, "", \$4); print \$4}')
# Alternative method if first fails
if [[ -z "\$SWAPFILE_OFFSET" ]] || [[ "\$SWAPFILE_OFFSET" == "0" ]]; then
    warn "First method failed, trying alternative..."
    SWAPFILE_OFFSET=\$(filefrag -v /swapfile 2>/dev/null | awk '/^ *0:/ {print \$4}' | sed 's/\\.\\.//')
fi

# If still not found, warn and set default
# Final validation
if [[ -z "\$SWAPFILE_OFFSET" ]] || [[ "\$SWAPFILE_OFFSET" == "0" ]]; then
    warn " Could not determine swapfile offset. Hibernation may not work."
    info "You can calculate it manually later with: filefrag -v /swapfile"
    # Set default GRUB config without hibernation
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"/' /etc/default/grub
else
    info "Swapfile offset: \$SWAPFILE_OFFSET"
    # Configure GRUB with hibernation support
    sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet resume=UUID=\$ROOT_UUID resume_offset=\$SWAPFILE_OFFSET\"/" /etc/default/grub
fi

# Generate GRUB config
echo "Generating GRUB configuration"
grub-mkconfig -o /boot/grub/grub.cfg  || {
    error "Failed to generate GRUB configuration"
}
sleep 2

# (hypernate on lid close)
# Configure systemd for hibernation on lid close (only if hibernation is properly configured)
if [[ -n "\$SWAPFILE_OFFSET" ]] && [[ "\$SWAPFILE_OFFSET" != "0" ]]; then
    info "Configuring systemd for hibernation on lid close..."
    mkdir -p /etc/systemd/logind.conf.d
    cat > /etc/systemd/logind.conf.d/hibernate.conf <<HIBERNATEEOF
[Login]
HandleLidSwitch=hibernate
HandleLidSwitchExternalPower=hibernate
HIBERNATEEOF
    info "Hibernation configured successfully"
else
    warn "Skipping hibernation configuration due to swapfile offset issues"
fi

# Enable services
echo "Enabling openssh service"
systemctl enable sshd || warn "Failed to enable sshd"

# Clear sensitive variables in chroot
unset ROOT_PASSWORD USER_PASSWORD

EOF

# Add swapfile entry to fstab for hibernation
echo "Configuring fstab for hibernation support" 
echo "# Swap file for hibernation" >> /mnt/etc/fstab
echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab
echo "resume=UUID=$(blkid -s UUID -o value ${ROOT_PART})" >> /mnt/etc/default/grub
info "Hibernation support configured in fstab and GRUB"

newTask "==================================================\n=================================================="
info "==== FINALIZING INSTALLATION ===="

# Enable network manager 
info "Enabling NetworkManager service"
arch-chroot /mnt systemctl enable NetworkManager || warn "NetworkManager not installed"

# Configure sudo (optional)
echo "%wheel ALL=(ALL) ALL" >> /mnt/etc/sudoers || warn "Failed to configure sudo"

# Ensure all writes are committed to disk before cleanup
sync
sleep 2

# Cleanup will run automatically due to trap
# cleanup  # no need to uncommit this line as it's redundant
sleep 1

newTask "==================================================\n==================================================\n"

info "\n${GREEN}[✓] INSTALLATION COMPLETE!${NC}"
info "\n${YELLOW}Next steps:${NC}"
info "1. Reboot: systemctl reboot"
info "2. Verify hibernation: sudo systemctl hibernate"
info "3. Check GPU: lspci -k | grep -A 3 -E '(VGA|3D)'"
info "\nRemember your credentials:"
info "  Root password: Set during installation"
info "  User: $USERNAME (with sudo privileges)"
