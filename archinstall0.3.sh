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
