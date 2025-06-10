#!/bin/bash

# Disk Wipe and Arch Linux Preparation Script
# Version 0.3 - Improved error handling and logging

set -uo pipefail  # Strict error handling

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

error() {
    echo -e "${RED}[ERROR] $*${NC}" >&2
    exit 1
}

info() {
    echo -e "${GREEN}[INFO] $*${NC}"
}

# Check root
[[ $(id -u) -eq 0 ]] || error "This script must be run as root"

# List disks
info "Available disks:"
lsblk -d -o NAME,SIZE,MODEL,TRAN

# Get disk
read -rp "Enter disk to wipe (e.g., vda, nvme0n1): " DISK
[[ -e "/dev/$DISK" ]] || error "Disk /dev/$DISK not found"

# Show disk info
info "\nSelected disk layout:"
lsblk "/dev/$DISK"

# Final confirmation
read -rp "WARNING: ALL DATA ON /dev/$DISK WILL BE DESTROYED! Confirm (type 'erase'): " CONFIRM
[[ "$CONFIRM" == "erase" ]] || error "Operation cancelled"

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
    done
    
    # Deactivate LVM (silenced descriptor leak warnings)
    if command -v vgchange &>/dev/null; then
        info "Deactivating LVM volumes..."
        vgchange -an 2>/dev/null
    fi
    
    # Unmount filesystems
    info "Unmounting partitions..."
    for mount in $(mount | grep "/dev/$DISK" | awk '{print $1}'); do
        umount -v "$mount" 2>/dev/null
    done
    
    sync
    sleep 2  # Allow time for processes to settle
}

cleanup

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