

# Fix 3: Improved create_swap function with better error checking
create_swap() {
    # Get precise RAM size in bytes (not rounded to GB)
    local ram_bytes=$(awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo)
    local ram_gib=$(awk "BEGIN {print int(($ram_bytes/1073741824)+0.5)}")  # Round to nearest GB
    local swapfile="/mnt/swapfile"
    
    # For hibernation, swap should be RAM size + 10-20% (kernel docs recommendation)
    local swap_size=$(awk "BEGIN {print int($ram_bytes * 1.15)}")  # 15% larger than RAM
    
    info "System has ${ram_gib}GB RAM (precise: $(numfmt --to=iec $ram_bytes))"
    info "Creating swap file for hibernation (size: $(numfmt --to=iec $swap_size))..."
    
    # Create swap file
    dd if=/dev/zero of="$swapfile" bs=1M count=$(($swap_size/1048576)) status=progress || 
        error "Failed to create swap file"
    chmod 600 "$swapfile" || error "Failed to set swap file permissions"
    mkswap "$swapfile" || error "Failed to format swap file"
    swapon "$swapfile" || error "Failed to activate swap"
    
    info "Swap file created successfully:"
    swapon --show
}

# Fix 4: Improved chroot section with proper error checking and GRUB order
arch-chroot /mnt /bin/bash <<EOF || error "Chroot commands failed"

TIMEZONE="Asia/Amman"
LOCALE="en_US.UTF-8"
HOSTNAME="${USERNAME}Arch"

# Set timezone
echo "Setting timezone to ${TIMEZONE}..."
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# Set locale
echo "Setting locale to ${LOCALE}..."
sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# Set hostname and hosts
echo "Setting hostname to ${USERNAME}Arch"
echo "$HOSTNAME" > /etc/hostname
cat <<HOSTSEOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTSEOF

# Set root password
echo "Setting root password..."
echo "root:${ROOT_PASSWORD}" | chpasswd

# Create user 
echo "Creating user account..."
useradd -m -G wheel -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

# Configure mkinitcpio for hibernation
echo "Configuring mkinitcpio for hibernation..."
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck resume)/' /etc/mkinitcpio.conf
mkinitcpio -P || { echo "Warning: mkinitcpio failed, continuing..."; }

# Install GRUB first (before configuring hibernation)
echo "Installing GRUB bootloader..."
if [[ -d /sys/firmware/efi ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || {
        echo "Error: GRUB installation failed"
        exit 1
    }
else
    grub-install --target=i386-pc "/dev/$DISK" || {
        echo "Error: GRUB installation failed"
        exit 1
    }
fi

# Configure GRUB for dual boot
echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub

# Now configure hibernation with proper error checking
echo "Configuring hibernation..."

# Get root partition UUID
ROOT_UUID=\$(blkid -s UUID -o value "/dev/${DISK}2")
if [[ -z "\$ROOT_UUID" ]]; then
    echo "Error: Could not get root partition UUID"
    exit 1
fi

# Calculate swapfile offset with error checking
echo "Calculating swapfile offset for hibernation..."
if [[ ! -f /swapfile ]]; then
    echo "Error: Swapfile not found at /swapfile"
    exit 1
fi

# Check if filefrag is available
if ! command -v filefrag >/dev/null 2>&1; then
    echo "Error: filefrag command not found. Installing e2fsprogs..."
    pacman -S --noconfirm e2fsprogs || {
        echo "Error: Failed to install e2fsprogs"
        exit 1
    }
fi

# Get swapfile offset with multiple methods for robustness
SWAPFILE_OFFSET=\$(filefrag -v /swapfile 2>/dev/null | awk 'NR==4 {gsub(/\\.\\.*/, "", \$4); print \$4}')

# Alternative method if first fails
if [[ -z "\$SWAPFILE_OFFSET" ]] || [[ "\$SWAPFILE_OFFSET" == "0" ]]; then
    echo "First method failed, trying alternative..."
    SWAPFILE_OFFSET=\$(filefrag -v /swapfile 2>/dev/null | awk '/^ *0:/ {print \$4}' | sed 's/\\.\\.//')
fi

# Final validation
if [[ -z "\$SWAPFILE_OFFSET" ]] || [[ "\$SWAPFILE_OFFSET" == "0" ]]; then
    echo "Warning: Could not determine swapfile offset. Hibernation may not work."
    echo "You can calculate it manually later with: filefrag -v /swapfile"
    # Set default GRUB config without hibernation
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"/' /etc/default/grub
else
    echo "Swapfile offset: \$SWAPFILE_OFFSET"
    # Configure GRUB with hibernation support
    sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet resume=UUID=\$ROOT_UUID resume_offset=\$SWAPFILE_OFFSET\"/" /etc/default/grub
fi

# Generate GRUB config
echo "Generating GRUB configuration..."
grub-mkconfig -o /boot/grub/grub.cfg || {
    echo "Error: GRUB config generation failed"
    exit 1
}

# Configure systemd for hibernation on lid close (only if hibernation is properly configured)
if [[ -n "\$SWAPFILE_OFFSET" ]] && [[ "\$SWAPFILE_OFFSET" != "0" ]]; then
    echo "Configuring systemd for hibernation on lid close..."
    mkdir -p /etc/systemd/logind.conf.d
    cat > /etc/systemd/logind.conf.d/hibernate.conf <<HIBERNATEEOF
[Login]
HandleLidSwitch=hibernate
HandleLidSwitchExternalPower=hibernate
HIBERNATEEOF
    echo "Hibernation configured successfully"
else
    echo "Skipping hibernation configuration due to swapfile offset issues"
fi

# Enable services
echo "Enabling SSH service..."
systemctl enable sshd || echo "Warning: Failed to enable sshd"

EOF

# Fix 5: Add fstab entry for swapfile (move this outside the create_swap function)
# Add swapfile to fstab after chroot is complete
echo "Adding swapfile to fstab..."
echo "# Swap file for hibernation" >> /mnt/etc/fstab
echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab