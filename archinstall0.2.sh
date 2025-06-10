#!/bin/bash
set -euo pipefail

DISK="/dev/sda"
PART="${DISK}1"

echo "[*] Wiping and partitioning $DISK..."
parted --script "$DISK" mklabel msdos
parted --script "$DISK" mkpart primary ext4 1MiB 100%
parted --script "$DISK" set 1 boot on

echo "[*] Formatting partition $PART..."
mkfs.ext4 "$PART"

echo "[*] Mounting $PART to /mnt..."
mount "$PART" /mnt

echo "[*] Installing base system..."
pacstrap /mnt base linux linux-firmware vim grub os-prober

echo "[*] Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "[*] Copying post-chroot script..."
cp post-chroot.sh /mnt/root/
chmod +x /mnt/root/post-chroot.sh

echo "[*] Entering chroot to continue setup..."
arch-chroot /mnt /root/post-chroot.sh

echo "[*] Unmounting and syncing..."
umount -R /mnt
sync

echo "[✓] Installation complete. You can now reboot."
