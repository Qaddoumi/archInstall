
#!/bin/bash

# Disk Wipe and Arch Linux Preparation Script
# Version 0.4 - More robust cleanup handling

set -uo pipefail  # Strict error handling

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error() {
    echo -e "${RED}[ERROR] $*${NC}" >&2
    exit 1
}

info() {
    echo -e "${GREEN}[INFO] $*${NC}"
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
read -rp "Enter disk to wipe (e.g., vda, nvme0n1): " DISK
[[ -e "/dev/$DISK" ]] || error "Disk /dev/$DISK not found"

# Show disk info
info "\nSelected disk layout:"
lsblk "/dev/$DISK"

# Final confirmation
read -rp "WARNING: ALL DATA ON /dev/$DISK WILL BE DESTROYED! Confirm (type 'y'): " CONFIRM
[[ "$CONFIRM" == "y" ]] || error "Operation cancelled"


# Enhanced cleanup function
cleanup1() {
    local attempts=3
    info "Starting cleanup process..."
    
    while (( attempts-- > 0 )); do
        # 1. Kill processes using the disk
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
        info "Disabling swap..."
        swapoff -a 2>/dev/null
        for swap in $(blkid -t TYPE=swap -o device | grep "/dev/$DISK"); do
            swapoff -v "$swap"
        done
        sleep 2

        # Check and unmount any partitions from the disk before wiping
        info "\nChecking for mounted partitions on /dev/$DISK..."
        for part in $(lsblk -lnp -o NAME | grep "^/dev/$DISK" | tail -n +2); do
            info "Attempting to unmount $part..."
            if ! umount "$part" 2>/dev/null; then
                warn "Failed to unmount $part"
            else
                info "$part unmounted successfully."
            fi
        done
        sleep 2
        
        # 5. Check if cleanup was successful
        if ! (mount | grep -q "/dev/$DISK") && \
           ! (lsof +f -- "/dev/$DISK"* 2>/dev/null | grep -q .); then
            info "Cleanup successful"
            return 0
        fi
        
        sleep 2
    done
    
    warn "Cleanup incomplete - some resources might still be in use"
    return 1
}

# Run cleanup
if ! cleanup1; then
    warn "Proceeding with disk operations despite cleanup warnings"
fi


# Cleanup sequence
cleanup() {
    info "Starting cleanup process...\n"

    info "\nkilling any processes using the disk $DISK ...\n"
    for process in $(lsof +f -- /dev/${DISK}* 2>/dev/null | awk '{print $2}' | uniq); do kill -9 "$process"; done
    sleep 2  # Allow time for processes to settle
    # try again to kill any processes using the disk
    lsof +f -- /dev/${DISK}* 2>/dev/null | awk '{print $2}' | uniq | xargs -r kill -9
    sleep 2
    
    # Disable swap
    info "Disabling swap..."
    swapoff -a 2>/dev/null
    for swap in $(blkid -t TYPE=swap -o device | grep "/dev/$DISK"); do
        swapoff -v "$swap"
        sleep 2
    done
    
    # Deactivate LVM (silenced descriptor leak warnings)
    if command -v vgchange &>/dev/null; then
        info "Deactivating LVM volumes..."
        vgchange -an 2>/dev/null
        sleep 2
    fi

    # Check and unmount any partitions from the disk before wiping
    info "\nChecking for mounted partitions on /dev/$DISK..."
    for part in $(lsblk -lnp -o NAME | grep "^/dev/$DISK" | tail -n +2); do
        info "Attempting to unmount $part..."
        if ! umount "$part" 2>/dev/null; then
            warn "Failed to unmount $part"
        else
            info "$part unmounted successfully."
        fi
    done
    sleep 2
    
    sync
    sleep 2  # Allow time for processes to settle
}

#cleanup

# Wipe disk
info "Wiping disk signatures..."
wipefs -a "/dev/$DISK" || error "Failed to wipe disk"

# Partitioning
info "Creating new GPT partition table..."
parted -s "/dev/$DISK" mklabel gpt || error "Partitioning failed"

# Custom partition sizes
EFI_SIZE="2G"  # Adjust as needed
ROOT_SIZE="100%"  # Remainder for root

info "Creating partitions:"
# EFI Partition
parted -s "/dev/$DISK" mkpart primary fat32 1MiB "$EFI_SIZE" || error "EFI partition failed"
parted -s "/dev/$DISK" set 1 esp on

# Root Partition
parted -s "/dev/$DISK" mkpart primary ext4 "$EFI_SIZE" "$ROOT_SIZE" || error "Root partition failed"

# Formatting
info "Formatting partitions:"
mkfs.fat -F32 "/dev/${DISK}1" || error "EFI format failed"
mkfs.ext4 -F "/dev/${DISK}2" || error "Root format failed"

# Verification
info "Verifying new layout:"
fdisk -l "/dev/$DISK" || error "Verification failed"

info "\n${GREEN}Disk preparation successful!${NC}"
info "Mount points for Arch installation:"
info "  mount /dev/${DISK}2 /mnt"
info "  mkdir -p /mnt/boot && mount /dev/${DISK}1 /mnt/boot"