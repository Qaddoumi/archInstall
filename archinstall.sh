#!/bin/bash

set -o pipefail

echo "changing the font: "
setfont ter-116n


echo
# Ask for root password
# Arch Linux uses standard UNIX password rules:
# - Any length (but at least 1 character is required)
# - Can include letters, numbers, and symbols
# - No enforced complexity by default, but strong passwords are recommended
# - Avoid spaces and non-ASCII characters for compatibility

read -rsp "Enter root password: " ROOT_PASSWORD
echo
read -rsp "Confirm root password: " ROOT_PASSWORD_CONFIRM
echo
if [[ "$ROOT_PASSWORD" != "$ROOT_PASSWORD_CONFIRM" ]]; then
    echo "Root passwords do not match. Aborting."
    exit 1
fi
if [[ -z "$ROOT_PASSWORD" ]]; then
    echo "Root password cannot be empty. Aborting."
    exit 1
fi

# Ask for username
read -rp "Enter username: " USERNAME

# Ask for user password
read -rsp "Enter password for $USERNAME: " USER_PASSWORD
echo
read -rsp "Confirm password for $USERNAME: " USER_PASSWORD_CONFIRM
echo
if [[ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]]; then
    echo "User passwords do not match. Aborting."
    exit 1
fi

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

echo -e "\nupdating ...\n"
pacman -Sy
pacman -S --noconfirm archinstall 


# Check and unmount any partitions from the disk before wiping
echo -e "\nChecking for mounted partitions on $DISK..."
for part in $(lsblk -lnp -o NAME | grep "^$DISK"); do
    echo "Attempting to unmount $part..."
    if ! umount "$part"; then
        echo "Failed to unmount $part"
        exit 1
    fi
done
if ! swapoff "$DISK"; then
    echo "Failed to deactivate swap on $part"
    exit 1
fi

# Double check with a recursive unmount
if ! umount -R "$DISK"; then
    echo "Failed to recursively unmount $DISK"
    exit 1
fi

# Wipe existing partitions
echo -e "\nWiping $DISK..."
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"

# Create partitions: 2GB boot, rest root
echo "Creating partitions on $DISK..."

parted -s "$DISK" \
    mklabel gpt \
    mkpart primary fat32 1MiB 2049MiB \
    set 1 boot on \
    mkpart primary ext4 2049MiB 100%

# Partition naming fix for NVMe
if [[ "$DISK" =~ nvme ]]; then
  BOOT_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
else
  BOOT_PART="${DISK}1"
  ROOT_PART="${DISK}2"
fi

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

# Ensure /mnt/etc exists before generating fstab
mkdir -p /mnt/etc
genfstab -U /mnt >> /mnt/etc/fstab

echo "✅ Partitioning, formatting, and mounting complete."

bash <(curl -sL https://raw.githubusercontent.com/Qaddoumi/archInstall/refs/heads/main/post-chroot.sh) \
    --root-password "$ROOT_PASSWORD" \
    --username "$USERNAME" \
    --user-password "$USER_PASSWORD" 

echo "✅ Base system installed."
echo "✅ System setup complete. Rebooting now..."

reboot
