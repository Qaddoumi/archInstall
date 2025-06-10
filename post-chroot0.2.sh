#!/bin/bash
set -euo pipefail

DISK="/dev/vda"

echo "[*] Setting timezone and clock..."
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

echo "[*] Configuring locale..."
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "[*] Setting hostname and hosts..."
echo "archvm" > /etc/hostname
cat <<EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   archvm.localdomain archvm
EOF

echo "[*] Installing and configuring GRUB..."
grub-install --target=i386-pc --recheck "$DISK"
grub-mkconfig -o /boot/grub/grub.cfg

echo "[*] Creating initramfs..."
mkinitcpio -P

echo "[*] Setting root password..."
echo "root:toor" | chpasswd

echo "[✓] Chroot setup complete. You can now exit and reboot."
