#!/bin/bash

set -euo pipefail

echo "changing the font: "
setfont ter-116n


echo -e "\nupdating ...\n"
pacman -Sy

echo -e "\n\nexcuting lsblk to show all the drives : \n"

lsblk

echo


# Ask for the disk device
read -rp "Enter the disk to install on (e.g. /dev/sda or /dev/nvme0n1): " DISK

# Double-check the disk exists
if [ ! -b "$DISK" ]; then
    echo "Disk $DISK not found. Aborting."
    exit 1
fi

# Wipe existing partitions
echo "Wiping $DISK..."
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"

# Create partitions: 2GB boot, rest root
echo "Creating partitions on $DISK..."

parted -s "$DISK" \
    mklabel gpt \
    mkpart primary fat32 1MiB 2049MiB \
    set 1 boot on \
    mkpart primary ext4 2049MiB 100%

BOOT_PART="${DISK}1"
ROOT_PART="${DISK}2"

# Format partitions
echo "Formatting boot partition ($BOOT_PART) as FAT32..."
mkfs.fat -F32 "$BOOT_PART"

echo "Formatting root partition ($ROOT_PART) as ext4..."
mkfs.ext4 -F "$ROOT_PART"

# Mount root
mount "$ROOT_PART" /mnt

# Create /boot and mount it
mkdir /mnt/boot
mount "$BOOT_PART" /mnt/boot

# Setup swap file the size of RAM
RAM_SIZE=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024) "M"}')

echo "Creating swap file with size $RAM_SIZE..."

fallocate -l "$RAM_SIZE" /mnt/swapfile
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
swapon /mnt/swapfile

# Persist fstab
genfstab -U /mnt >> /mnt/etc/fstab

echo "✅ Partitioning, formatting, and mounting complete."
