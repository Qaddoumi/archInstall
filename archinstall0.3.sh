#!/bin/bash

# Disk Wipe and Preparation Script for Arch Linux Installation
# WARNING: This will completely erase all data on the specified disk

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use 'sudo' or log in as root."
    exit 1
fi

# List available disks
echo "Available disks on your system:"
lsblk -d -o NAME,SIZE,MODEL

# Prompt for disk selection
read -p "Enter the disk to wipe (e.g., sda, nvme0n1): " DISK

# Verify disk exists
if [ ! -e "/dev/$DISK" ]; then
    echo "Error: Disk /dev/$DISK does not exist."
    exit 1
fi

# Display disk information for confirmation
echo -e "\nYou have selected the following disk:"
lsblk "/dev/$DISK"
echo -e "\nWARNING: ALL DATA ON /dev/$DISK WILL BE PERMANENTLY ERASED!"

# Final confirmation
read -p "Are you absolutely sure you want to continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Operation cancelled."
    exit 0
fi

echo -e "\nkilling any processes using the disk $DISK ...\n"
for process in $(lsof +f -- /dev/${DISK}* 2>/dev/null | awk '{print $2}' | uniq); do kill -9 "$process"; done
# try again to kill any processes using the disk
lsof +f -- /dev/${DISK}* 2>/dev/null | awk '{print $2}' | uniq | xargs -r kill -9

# Improved unmounting sequence - CORRECT ORDER
echo -e "\nAttempting to disable swap, deactivate LVM, and unmount partitions..."

# 1. Disable swap (check if any swap is on this disk)
swapoff -a  # Disable all swap (safer, but you could target only ${DISK} if preferred)
for swap in $(blkid -t TYPE=swap -o device | grep "/dev/${DISK}"); do
    swapoff -v "$swap"
done

# 2. Deactivate LVM (if present)
if command -v vgchange &>/dev/null; then
    vgchange -an  # Deactivate all volume groups (or target specific ones if needed)
fi

# 3. Now unmount filesystems (including LVM if it was active)
for mount in $(mount | grep "/dev/${DISK}" | awk '{print $1}'); do
    umount -v "$mount"
done

# 4. Final sync to ensure all operations are complete
sync

echo -e "\nWaiting for processes to settle... then proceeding with disk wipe.\n"
sleep 10

# Wipe the disk
echo -e "\nWiping disk..."
wipefs -a /dev/$DISK

# Create a new GPT partition table
echo -e "\nCreating new GPT partition table..."
parted -s /dev/$DISK mklabel gpt

# Create partitions (adjust sizes as needed)
echo -e "\nCreating partitions..."
# 1. EFI System Partition (2049MiB)
parted -s /dev/$DISK mkpart primary fat32 1MiB 2049MiB
parted -s /dev/$DISK set 1 esp on

# 2. Root partition (remaining space)
parted -s /dev/$DISK mkpart primary ext4 2049MiB 100%

# Format partitions
echo -e "\nFormatting partitions..."
mkfs.fat -F32 /dev/${DISK}1
mkfs.ext4 /dev/${DISK}2

# Verify the new partition layout
echo -e "\nNew partition layout:"
fdisk -l /dev/$DISK

echo -e "\nDisk preparation complete. You can now proceed with Arch Linux installation."
echo "Mount /dev/${DISK}2 to /mnt and /dev/${DISK}1 to /mnt/boot for installation."



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