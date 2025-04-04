#!/bin/bash

# Configuration
LUKS_MAPPER_NAME="glitch_luks"
TARGET_MOUNT="/mnt/glitch_install"
SQUASHFS_IMAGE="/run/live/medium/live/filesystem.squashfs"  # Update this path to your SquashFS image

# Required dependencies
DEPENDENCIES="wget cryptsetup-bin cryptsetup-initramfs grub-common grub-pc-bin grub-efi-amd64-bin parted squashfs-tools dosfstools mtools pv"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root!" >&2
    exit 1
fi

# Install dependencies
echo "Installing required dependencies..."
if ! apt update || ! apt install -y $DEPENDENCIES; then
    echo "Failed to install dependencies!" >&2
    exit 1
fi

# Function to clean up
cleanup() {
    echo -e "\nCleanup options:"
    echo "1) Keep mounts active for chroot access"
    echo "2) Clean up everything and exit"
    read -p "Choose option [1-2]: " CLEANUP_CHOICE
    
    case $CLEANUP_CHOICE in
        1)
            echo "Keeping mounts active. Remember to manually clean up later!"
            echo "Use: umount -R $TARGET_MOUNT"
            [ "$ENCRYPTED" = "yes" ] && echo "cryptsetup close $LUKS_MAPPER_NAME"
            ;;
        2)
            echo "Cleaning up..."
            # Unmount all mounted filesystems
            for mountpoint in "${TARGET_MOUNT}/boot/efi" "${TARGET_MOUNT}/dev/pts" "${TARGET_MOUNT}/dev" \
                            "${TARGET_MOUNT}/proc" "${TARGET_MOUNT}/sys" "${TARGET_MOUNT}/run"; do
                if mountpoint -q "$mountpoint"; then
                    umount -R "$mountpoint" 2>/dev/null
                fi
            done
            
            # Unmount the main filesystem
            if mountpoint -q "$TARGET_MOUNT"; then
                umount -R "$TARGET_MOUNT" 2>/dev/null
            fi
            
            # Close LUKS if open
            if [ "$ENCRYPTED" = "yes" ] && cryptsetup status "$LUKS_MAPPER_NAME" &>/dev/null; then
                cryptsetup close "$LUKS_MAPPER_NAME"
            fi
            
            # Remove mount point if empty
            [ -d "$TARGET_MOUNT" ] && rmdir "$TARGET_MOUNT" 2>/dev/null
            ;;
        *)
            echo "Invalid choice, keeping mounts active."
            ;;
    esac
}

trap cleanup EXIT

find_kernel_initrd() {
    local target_root="$1"
    
    KERNEL_VERSION=$(ls -1 "${target_root}/boot" | grep -E "vmlinuz-[0-9]" | sort -V | tail -n1 | sed 's/vmlinuz-//')
    [ -z "$KERNEL_VERSION" ] && { echo "ERROR: Kernel not found!" >&2; exit 1; }
    
    INITRD=""
    for pattern in "initrd.img-${KERNEL_VERSION}" "initramfs-${KERNEL_VERSION}.img" "initrd-${KERNEL_VERSION}.gz"; do
        [ -f "${target_root}/boot/${pattern}" ] && INITRD="$pattern" && break
    done
    [ -z "$INITRD" ] && { echo "ERROR: Initrd not found for kernel ${KERNEL_VERSION}" >&2; exit 1; }
    
    echo "Found kernel: vmlinuz-${KERNEL_VERSION}"
    echo "Found initrd: ${INITRD}"
}

get_uuid() {
    local device="$1"
    blkid -s UUID -o value "$device"
}

configure_system_files() {
    local target_root="$1"
    local target_device="$2"
    
    if [ "$ENCRYPTED" = "yes" ]; then
        # Get actual UUIDs from the system for encrypted setup
        local root_part_uuid=$(get_uuid "$ROOT_PART")
        local root_fs_uuid=$(get_uuid "/dev/mapper/$LUKS_MAPPER_NAME")
        
        if [ -z "$root_part_uuid" ] || [ -z "$root_fs_uuid" ]; then
            echo "ERROR: Failed to get UUIDs for partitions!" >&2
            exit 1
        fi

        # Verify UUIDs are correct
        echo "Verifying UUIDs:"
        echo "- Partition UUID: ${root_part_uuid}"
        echo "- Filesystem UUID: ${root_fs_uuid}"
        lsblk -o NAME,UUID | grep -E "(${LUKS_MAPPER_NAME}|${ROOT_PART##*/})"

        # Create /etc/crypttab
        echo "Creating /etc/crypttab..."
        cat > "${target_root}/etc/crypttab" << EOF
${LUKS_MAPPER_NAME} UUID=${root_part_uuid} none luks,discard
EOF

        # Configure cryptsetup for initramfs
        echo "Configuring cryptsetup for initramfs..."
        mkdir -p "${target_root}/etc/initramfs-tools/conf.d"
        cat > "${target_root}/etc/initramfs-tools/conf.d/cryptsetup" << EOF
KEYFILE_PATTERN=/etc/luks/*.keyfile
UMASK=0077
EOF

        # Add necessary modules to initramfs
        echo "Adding required modules to initramfs..."
        cat > "${target_root}/etc/initramfs-tools/modules" << EOF
dm-crypt
cryptodisk
luks
aes
sha256
ext4
EOF

        # Create /etc/fstab with correct UUIDs
        echo "Creating /etc/fstab..."
        cat > "${target_root}/etc/fstab" << EOF
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
UUID=${root_fs_uuid} /               ext4    errors=remount-ro 0       1
EOF

        # Update GRUB configuration
        echo "Updating GRUB configuration..."
        find_kernel_initrd "$target_root"
        
        # Ensure GRUB cryptodisk support is enabled
        echo "Configuring GRUB_ENABLE_CRYPTODISK..."
        mkdir -p "${target_root}/etc/default"
        if [ -f "${target_root}/etc/default/grub" ]; then
            sed -i 's/^GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' "${target_root}/etc/default/grub"
        fi
        if ! grep -q '^GRUB_ENABLE_CRYPTODISK=y' "${target_root}/etc/default/grub"; then
            echo "GRUB_ENABLE_CRYPTODISK=y" >> "${target_root}/etc/default/grub"
        fi
        
        mkdir -p "${target_root}/boot/grub"
        cat > "${target_root}/boot/grub/grub.cfg" << EOF
loadfont /usr/share/grub/unicode.pf2

set gfxmode=640x480
load_video
insmod gfxterm
set locale_dir=/boot/grub/locale
set lang=C
insmod gettext
background_image -m stretch /boot/grub/grub.png
terminal_output gfxterm
insmod png
if background_image /boot/grub/grub.png; then
    true
else
    set menu_color_normal=cyan/blue
    set menu_color_highlight=white/blue
fi

menuentry "Glitch Linux" {
    insmod part_gpt
    insmod cryptodisk
    insmod luks
    insmod ext2
    
    cryptomount -u ${root_part_uuid}
    set root='(crypto0)'
    search --no-floppy --fs-uuid --set=root ${root_fs_uuid}
    linux /boot/vmlinuz-${KERNEL_VERSION} root=UUID=${root_fs_uuid} cryptdevice=UUID=${root_part_uuid}:${LUKS_MAPPER_NAME} ro quiet
    initrd /boot/${INITRD}
}

menuentry "Glitch Linux (recovery mode)" {
    insmod part_gpt
    insmod cryptodisk
    insmod luks
    insmod ext2
    
    cryptomount -u ${root_part_uuid}
    set root='(crypto0)'
    search --no-floppy --fs-uuid --set=root ${root_fs_uuid}
    linux /boot/vmlinuz-${KERNEL_VERSION} root=UUID=${root_fs_uuid} cryptdevice=UUID=${root_part_uuid}:${LUKS_MAPPER_NAME} ro single
    initrd /boot/${INITRD}
}
EOF
    else
        # Unencrypted setup
        local root_fs_uuid=$(get_uuid "$ROOT_PART")
        
        if [ -z "$root_fs_uuid" ]; then
            echo "ERROR: Failed to get UUID for root partition!" >&2
            exit 1
        fi

        # Create /etc/fstab
        echo "Creating /etc/fstab..."
        cat > "${target_root}/etc/fstab" << EOF
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
UUID=${root_fs_uuid} /               ext4    errors=remount-ro 0       1
EOF

        # Update GRUB configuration
        echo "Updating GRUB configuration..."
        find_kernel_initrd "$target_root"
        
        mkdir -p "${target_root}/boot/grub"
        cat > "${target_root}/boot/grub/grub.cfg" << EOF
loadfont /usr/share/grub/unicode.pf2

set gfxmode=640x480
load_video
insmod gfxterm
set locale_dir=/boot/grub/locale
set lang=C
insmod gettext
background_image -m stretch /boot/grub/grub.png
terminal_output gfxterm
insmod png
if background_image /boot/grub/grub.png; then
    true
else
    set menu_color_normal=cyan/blue
    set menu_color_highlight=white/blue
fi

menuentry "Glitch Linux" {
    insmod part_gpt
    insmod ext2
    
    search --no-floppy --fs-uuid --set=root ${root_fs_uuid}
    linux /boot/vmlinuz-${KERNEL_VERSION} root=UUID=${root_fs_uuid} ro quiet
    initrd /boot/${INITRD}
}

menuentry "Glitch Linux (recovery mode)" {
    insmod part_gpt
    insmod ext2
    
    search --no-floppy --fs-uuid --set=root ${root_fs_uuid}
    linux /boot/vmlinuz-${KERNEL_VERSION} root=UUID=${root_fs_uuid} ro single
    initrd /boot/${INITRD}
}
EOF
    fi

    echo "Initramfs will be updated after chroot environment is prepared"
}

prepare_chroot() {
    local target_root="$1"
    local target_device="$2"
    
    echo "Mounting required filesystems for chroot..."
    mount --bind /dev "${target_root}/dev" || { echo "Failed to mount /dev"; exit 1; }
    mount --bind /dev/pts "${target_root}/dev/pts" || { echo "Failed to mount /dev/pts"; exit 1; }
    mount -t proc proc "${target_root}/proc" || { echo "Failed to mount /proc"; exit 1; }
    mount -t sysfs sys "${target_root}/sys" || { echo "Failed to mount /sys"; exit 1; }
    mount -t tmpfs tmpfs "${target_root}/run" || { echo "Failed to mount /run"; exit 1; }
    
    [ -e "/etc/resolv.conf" ] && cp --dereference /etc/resolv.conf "${target_root}/etc/"
    
    cat > "${target_root}/chroot_prep.sh" << EOF
#!/bin/bash
# Set up basic system
echo "glitch" > /etc/hostname
echo "127.0.1.1 glitch" >> /etc/hosts

# Install required packages in chroot
echo "Installing required packages..."
apt-get update
[ "$ENCRYPTED" = "yes" ] && apt-get install -y cryptsetup-initramfs cryptsetup

# Reinstall the latest kernel to ensure proper boot files
echo "Reinstalling kernel..."
KERNEL_PKG=\$(dpkg -l | grep '^ii.*linux-image' | awk '{print \$2}' | sort -V | tail -n1)
apt-get install --reinstall -y \$KERNEL_PKG

# First update initramfs with proper mounts available
echo "Updating initramfs..."
update-initramfs -u -k all || { echo "Initramfs update failed"; exit 1; }

# Then install GRUB
echo "Installing GRUB..."
if [ -d "/sys/firmware/efi" ]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck || { echo "EFI GRUB install failed"; exit 1; }
else
    grub-install ${target_device} --recheck || { echo "BIOS GRUB install failed"; exit 1; }
fi
update-grub || { echo "GRUB update failed"; exit 1; }

# Verify cryptsetup in initramfs if encrypted
if [ "$ENCRYPTED" = "yes" ]; then
    echo "Verifying cryptsetup in initramfs..."
    lsinitramfs /boot/initrd.img-*\$(uname -r) | grep cryptsetup || echo "Warning: cryptsetup not found in initramfs"
fi

# Clean up
rm -f /chroot_prep.sh
EOF
    chmod +x "${target_root}/chroot_prep.sh"
    
    echo -e "\nChroot environment ready! To complete setup:"
    echo "1. chroot ${target_root}"
    echo "2. Run /chroot_prep.sh"
    echo "3. Exit and reboot"
    
    # Offer to automatically run chroot commands
    read -p "Would you like to automatically run the chroot commands now? [y/N] " AUTO_CHROOT
    if [[ "$AUTO_CHROOT" =~ [Yy] ]]; then
        echo "Running chroot commands..."
        if ! chroot "${target_root}" /bin/bash -c "/chroot_prep.sh"; then
            echo "Chroot preparation failed!" >&2
            exit 1
        fi
        echo "Chroot preparation completed successfully!"
    else
        echo "You can manually run the chroot commands later with:"
        echo "  chroot ${target_root} /bin/bash"
        echo "  /chroot_prep.sh"
    fi
}

partition_disk() {
    local target_device="$1"
    
    # Wipe the disk
    echo "Wiping disk..."
    wipefs -a "$target_device"
    
    # Create GPT partition table
    echo "Creating GPT partition table..."
    parted -s "$target_device" mklabel gpt
    
    # Create EFI partition (100MB)
    echo "Creating EFI partition (100MB)..."
    parted -s "$target_device" mkpart primary fat32 1MiB 101MiB
    parted -s "$target_device" set 1 esp on
    
    # Create root partition (remaining space)
    echo "Creating root partition..."
    parted -s "$target_device" mkpart primary ext4 101MiB 100%
    
    # Wait for partitions to settle
    sleep 2
    partprobe "$target_device"
    sleep 2
    
    # Determine partition names
    if [[ "$target_device" =~ "nvme" ]]; then
        EFI_PART="${target_device}p1"
        ROOT_PART="${target_device}p2"
    else
        EFI_PART="${target_device}1"
        ROOT_PART="${target_device}2"
    fi
    
    # Format EFI partition
    echo "Formatting EFI partition as FAT32..."
    mkfs.vfat -F32 "$EFI_PART"
    
    if [ "$ENCRYPTED" = "yes" ]; then
        # Set up LUKS encryption
        echo "Setting up LUKS encryption on root partition..."
        cryptsetup luksFormat --type luks1 -v -y "$ROOT_PART"
        echo "Opening encrypted partition..."
        cryptsetup open "$ROOT_PART" "$LUKS_MAPPER_NAME"
        
        # Format the encrypted partition
        echo "Formatting encrypted partition as ext4..."
        mkfs.ext4 "/dev/mapper/$LUKS_MAPPER_NAME"
    else
        # Format root partition directly
        echo "Formatting root partition as ext4..."
        mkfs.ext4 "$ROOT_PART"
    fi
}

install_system() {
    local target_root="$1"
    
    # Check if SquashFS image exists
    if [ ! -f "$SQUASHFS_IMAGE" ]; then
        echo "ERROR: SquashFS image not found at $SQUASHFS_IMAGE" >&2
        exit 1
    fi
    
    echo "Installing system from SquashFS image..."
    
    # Create temporary directory for unsquashing
    TEMP_DIR=$(mktemp -d)
    
    # Unsquash the filesystem
    echo "Extracting SquashFS image..."
    if ! unsquashfs -f -d "$TEMP_DIR" "$SQUASHFS_IMAGE"; then
        echo "Failed to extract SquashFS image!" >&2
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # Copy files to target
    echo "Copying files to target..."
    cp -a "$TEMP_DIR"/* "$target_root"/
    
    # Clean up temporary directory
    rm -rf "$TEMP_DIR"
    
    echo "System installation complete."
}

main_install() {
    # List available disks
    echo -e "\nAvailable disks:"
    lsblk -d -o NAME,SIZE,MODEL | grep -v "NAME"
    
    # Get target device
    read -p "Enter target device (e.g., /dev/sdX): " TARGET_DEVICE
    [ ! -b "$TARGET_DEVICE" ] && { echo "Invalid device!"; exit 1; }
    read -p "This will ERASE ${TARGET_DEVICE}! Continue? (yes/no): " CONFIRM
    [ "$CONFIRM" != "yes" ] && exit 0
    
    # Ask for encryption
    read -p "Enable disk encryption? (yes/no) [default: yes]: " ENCRYPTED
    ENCRYPTED=${ENCRYPTED:-yes}
    
    # Partition and format disk
    partition_disk "$TARGET_DEVICE"
    
    # Mount the filesystems
    echo "Mounting filesystems..."
    mkdir -p "$TARGET_MOUNT"
    
    if [ "$ENCRYPTED" = "yes" ]; then
        mount "/dev/mapper/$LUKS_MAPPER_NAME" "$TARGET_MOUNT"
    else
        mount "$ROOT_PART" "$TARGET_MOUNT"
    fi
    
    mkdir -p "${TARGET_MOUNT}/boot/efi"
    mount "$EFI_PART" "${TARGET_MOUNT}/boot/efi"
    
    # Install system from SquashFS
    install_system "$TARGET_MOUNT"
    
    configure_system_files "$TARGET_MOUNT" "$TARGET_DEVICE"
    prepare_chroot "$TARGET_MOUNT" "$TARGET_DEVICE"

    # Keep system running for chroot access if not automated
    if [[ ! "$AUTO_CHROOT" =~ [Yy] ]]; then
        while true; do
            read -p "Enter 'exit' when done with chroot to cleanup: " cmd
            [ "$cmd" = "exit" ] && break
        done
    fi
}

main_install