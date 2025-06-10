
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

# List disks
info "Available disks:"
lsblk -d -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT

# Get disk
read -rp "Enter disk to wipe (e.g., vda, sda, nvme0n1): " DISK
[[ -e "/dev/$DISK" ]] || error "Disk /dev/$DISK not found"

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
mount "/dev/${DISK}2" /mnt || error "Failed to mount root partition"
mkdir -p /mnt/boot
mount "/dev/${DISK}1" /mnt/boot || error "Failed to mount boot partition"
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
info "Installing base system and GRUB..."
pacstrap /mnt base linux linux-firmware grub efibootmgr os-prober || error "Failed to install base packages"
sleep 2
# Ensure /mnt/etc exists before generating fstab
mkdir -p /mnt/etc

# Generate fstab
info "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab || error "Failed to generate fstab"

# Chroot setup
info "Configuring GRUB and hibernation in chroot..."
arch-chroot /mnt /bin/bash <<EOF || error "Chroot commands failed"

    # Set timezone and locale
    ln -sf /usr/share/zoneinfo/$(timedatectl | grep "Time zone" | awk '{print $3}') /etc/localtime
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf

    # Set hostname
    
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

    # Enable systemd hibernation service
    echo "[Login]" > /etc/systemd/logind.conf.d/hibernate.conf
    echo "HandleLidSwitch=hibernate" >> /etc/systemd/logind.conf.d/hibernate.conf
    echo "HandleLidSwitchExternalPower=hibernate" >> /etc/systemd/logind.conf.d/hibernate.conf
EOF

newTask "==================================================\n=================================================="
newTask "==== FINALIZING INSTALLATION ===="

# Set root password
info "Set root password:"
arch-chroot /mnt passwd || warn "Failed to set root password (can do manually later)"

# Enable network manager (optional)
arch-chroot /mnt systemctl enable NetworkManager.service || warn "NetworkManager not installed"

# Configure sudo (optional)
echo "%wheel ALL=(ALL) ALL" >> /mnt/etc/sudoers || warn "Failed to configure sudo"

newTask "==================================================\n==================================================\n"

info "\n${GREEN}ARCH LINUX INSTALLATION COMPLETE!${NC}"
info "Hibernation is fully configured with:"
info "  - Swapfile at /swapfile (size: \$(numfmt --to=iec $(awk '/MemTotal/ {print $2 * 1024 * 1.15}' /proc/meminfo))"
info "  - GRUB resume parameters set"
info "  - systemd hibernation triggers (lid close)"

info "\n${YELLOW}REBOOT INSTRUCTIONS:${NC}"
info "1. Unmount: umount -R /mnt"
info "2. Reboot: systemctl reboot"
info "3. After reboot, verify hibernation works:"
info "   sudo systemctl hibernate"
info "   (Should resume to your desktop)"




info "\n${GREEN}System ready for Arch Linux installation!${NC}"
info "Next steps:"
info "1. Run: pacstrap /mnt base linux linux-firmware"
info "2. After chrooting, edit /etc/mkinitcpio.conf and add 'resume' to HOOKS:"
info "   HOOKS=(base udev autodetect modconf block filesystems keyboard fsck resume)"
info "3. Regenerate initramfs: mkinitcpio -P"
info "4. Configure GRUB: grub-mkconfig -o /boot/grub/grub.cfg"
info "5. Verify resume parameter in /proc/cmdline after reboot"


echo "[✓] Installation complete. You can now reboot."