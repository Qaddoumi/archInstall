#!/bin/bash
set -euo pipefail

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

# First part - before chroot
echo "Starting Arch Linux post installation script..."
pacstrap -K /mnt base linux linux-firmware systemd systemd-sysvcompat sudo vim nano networkmanager openssh wget curl \
    git linux-headers base-devel efibootmgr dosfstools mkinitcpio

# Install microcode based on CPU vendor
if grep -q "GenuineIntel" /proc/cpuinfo; then
    echo "Installing Intel microcode..."
    pacman -Sy --noconfirm intel-ucode
elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    echo "Installing AMD microcode..."
    pacman -Sy --noconfirm amd-ucode
else
    echo "Unknown CPU vendor. Skipping microcode installation."
fi

if lspci | grep -q "VGA compatible controller: NVIDIA"; then
    echo "NVIDIA GPU detected. Installing NVIDIA drivers..."
    pacman -Sy --noconfirm nvidia nvidia-utils
elif lspci | grep -q "VGA compatible controller: AMD"; then
    echo "AMD GPU detected. Installing AMD drivers..."
    pacman -Sy --noconfirm xf86-video-amdgpu
elif lspci | grep -q "VGA compatible controller: Intel"; then
    echo "Intel GPU detected. Installing Intel drivers..."
    pacman -Sy --noconfirm xf86-video-intel
else
    echo "Unknown GPU. Skipping GPU driver installation."
fi

# Generate fstab
echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "✅ Base system installed."    

sleep 5

# Create a second script for chroot commands
cat <<'SCRIPTEOF' > /mnt/setup.sh
#!/bin/bash
set -euo pipefail

### CONFIGURATION ###
HOSTNAME="mohArch"
LOCALE="en_US.UTF-8"
TIMEZONE="Asia/Amman"
ROOT_PART_UUID=$(blkid -s UUID -o value $(findmnt / -o SOURCE -n))

# Set timezone
echo "Setting timezone to ${TIMEZONE}..."
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# Set locale
echo "Setting locale to ${LOCALE}..."
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
echo "Setting root password..."
echo "root:${ROOT_PASSWORD}" | chpasswd

# Create user and add to groups using default credentials from environment variables
echo "Creating user account..."
useradd -m -G wheel -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

# Enable sudo for wheel group
echo "Enabling sudo for wheel group..."
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) NOPASSWD: ALL/' /etc/sudoers
sleep 5

# Enable swap
echo "Setting up swap..."
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

sleep 5

# Enable services
echo -e "\nEnabling services (NetworkManager, sshd)"
systemctl enable NetworkManager
systemctl enable sshd

echo -e "\nEnabling essential systemd services..."
systemctl enable systemd-networkd
systemctl enable systemd-resolved
systemctl enable systemd-timesyncd

sleep 5

# Generate initramfs
echo "Generating initramfs..."
mkinitcpio -P
sleep 5

# Install bootloader
echo "Installing bootloader..."
if ! command -v bootctl &> /dev/null; then
    echo "❌ bootctl not found. Please install systemd-boot first."
    exit 1
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

    # Add microcode to boot entry
    if [ -f "/boot/intel-ucode.img" ]; then
        MICROCODE="initrd  /intel-ucode.img"
    elif [ -f "/boot/amd-ucode.img" ]; then
        MICROCODE="initrd  /amd-ucode.img"
    else
        MICROCODE=""
    fi

    cat <<ARCHEOF > /boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
${MICROCODE}
initrd  /initramfs-linux.img
options root=UUID=${ROOT_PART_UUID} rw rootfstype=ext4 systemd.unified_cgroup_hierarchy=1
ARCHEOF
fi

cat <<SYSTEMDHOOKSEOF > /etc/mkinitcpio.conf
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole block filesystems fsck)
SYSTEMDHOOKSEOF

# Regenerate initramfs after changing config
mkinitcpio -P


echo "✅ System configured."
sleep 5
SCRIPTEOF

# Make the script executable
chmod +x /mnt/setup.sh

# Execute the script in chroot
arch-chroot /mnt /setup.sh

# Clean up
echo "Cleaning up..."
rm /mnt/setup.sh
sleep 5

# Unmount and reboot
echo "Unmounting partitions "
sync
umount -R /mnt
