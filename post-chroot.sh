#!/bin/bash
set -euo pipefail

# First part - before chroot
pacstrap -K /mnt base linux linux-firmware sudo vim nano networkmanager openssh wget curl
# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

echo "✅ Base system installed."    

# Parse named arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --root-password)
            ROOT_PASSWORD="$2"
            shift 2
            ;;
        --username)
            DEFAULT_USER="$2"
            shift 2
            ;;
        --user-password)
            USER_PASSWORD="$2"
            shift 2
            ;;
        *)
            echo "Unknown parameter: $1"
            echo "Usage: $0 --root-password <password> --username <user> --user-password <password>"
            exit 1
            ;;
    esac
done

# Verify all required parameters are provided
if [[ -z "${ROOT_PASSWORD:-}" ]] || [[ -z "${USERNAME:-}" ]] || [[ -z "${USER_PASSWORD:-}" ]]; then
    echo "Missing required parameters"
    echo "Usage: $0 --root-password <password> --username <user> --user-password <password>"
    exit 1
fi

export ROOT_PASSWORD
export USERNAME
export USER_PASSWORD

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

# Set root password non-interactively using the default from environment variable
echo "root:${ROOT_PASSWORD}" | chpasswd

# Create user and add to groups using default credentials from environment variables
echo "Creating user account..."
useradd -m -G wheel -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

# Enable sudo for wheel group
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers

# Enable swap
if [ ! -f /swapfile ]; then
    echo "❌ Error: /swapfile not found. Aborting."
    exit 1
fi

if ! swapon --show=NAME | grep -q "^/swapfile"; then
    echo "🔁 Enabling swapfile..."
    swapon /swapfile
else
    echo "✅ Swapfile already active."
fi

# Ensure it's in fstab (only once)
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap defaults 0 0' >> /etc/fstab


# Enable services
echo -e "\nEnabling services (NetworkManager, sshd)"
systemctl enable NetworkManager
systemctl enable sshd

# Install bootloader
if ! command -v bootctl &> /dev/null; then
    echo "❌ bootctl not found. Please install systemd-boot first."
fi
else 
    echo "✅ bootctl found."
    echo "Installing systemd-boot..."
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
fi



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
echo "Unmounting partitions "
sync
umount -R /mnt
