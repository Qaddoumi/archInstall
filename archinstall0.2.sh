#!/bin/bash
set -euo pipefail

DISK="/dev/vda"

echo -e "\nkilling any processes using the disk $DISK ...\n"
for process in $(lsof +f -- /dev/${DISK}* 2>/dev/null | awk '{print $2}' | uniq); do kill -9 "$process"; done
# try again to kill any processes using the disk
lsof +f -- /dev/${DISK}* 2>/dev/null | awk '{print $2}' | uniq | xargs -r kill -9

# Check and unmount any partitions from the disk before wiping
echo -e "\nChecking for mounted partitions on $DISK..."
for part in $(lsblk -lnp -o NAME | grep "^$DISK" | tail -n +2); do
    echo "Attempting to unmount $part..."
    if ! umount "$part" 2>/dev/null; then
        echo "Failed to unmount $part"
    fi
done
if ! swapoff "$DISK"; then
    echo "Failed to deactivate swap on $DISK, maybe it was not active."
fi

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
curl -s "https://raw.githubusercontent.com/Qaddoumi/archInstall/refs/heads/main/post-chroot0.2.sh" -o /mnt/root/post-chroot.sh
chmod +x /mnt/root/post-chroot.sh

echo "[*] Entering chroot to continue setup..."
arch-chroot /mnt /root/post-chroot.sh

echo "[*] Unmounting and syncing..."
umount -R /mnt
sync

echo "[✓] Installation complete. You can now reboot."
