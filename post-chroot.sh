#!/bin/bash
set -euo pipefail

# First part - before chroot
pacstrap -K /mnt base linux linux-firmware sudo vim nano networkmanager openssh wget curl
# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

echo "✅ Base system installed."    

# Create a second script for chroot commands
cat <<'SCRIPTEOF' > /mnt/setup.sh
#!/bin/bash
set -euo pipefail

### CONFIGURATION ###
HOSTNAME="mohArch"
MYUSER="moh"
LOCALE="en_US.UTF-8"
TIMEZONE="Asia/Amman"
ROOT_PART_UUID=$(blkid -s UUID -o value $(findmnt / -o SOURCE -n))

# Set timezone
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# Set locale
sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# Hostname & hosts
echo "$HOSTNAME" > /etc/hostname
cat <<HOSTSEOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTSEOF

# Root password
echo "Set root password: "
passwd root

# Create user and add to groups
echo "Creating user account..."
useradd -m -G wheel -s /bin/bash "${MYUSER}"
echo "Set password for ${MYUSER}: "
passwd "${MYUSER}"

# Enable sudo for wheel group
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

# Enable swap
if [ ! -f /swapfile ]; then
    echo "Error: Swapfile not found"
else
    swapon /swapfile
    echo "/swapfile none swap defaults 0 0" >> /etc/fstab
fi

# Enable services
systemctl enable NetworkManager
systemctl enable sshd

# Install bootloader
bootctl install

# Create systemd-boot config
cat <<LOADEREOF > /boot/loader/loader.conf
default arch
timeout 3
editor no
LOADEREOF

cat <<ARCHEOF > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=${ROOT_PART_UUID} rw
ARCHEOF

echo "✅ System configured. Rebooting in 5 seconds..."
sleep 5
exit
SCRIPTEOF

# Make the script executable
chmod +x /mnt/setup.sh

# Execute the script in chroot
arch-chroot /mnt /setup.sh

# Clean up
rm /mnt/setup.sh

# Unmount and reboot
echo "Unmounting partitions and rebooting..."
sync
umount -R /mnt
reboot
