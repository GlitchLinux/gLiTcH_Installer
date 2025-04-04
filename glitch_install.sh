#!/bin/bash

# Configuration
FILE_URL="https://glitchlinux.wtf/FILES/LUKS-BOOTLOADER-BIOS-UEFI-100MB.img"
TEMP_FILE="/tmp/LUKS-BOOTLOADER-BIOS-UEFI-100MB.img"
LUKS_MAPPER_NAME="glitch_luks"
TARGET_MOUNT="/mnt/glitch_install"
EXCLUDE_FILE="/tmp/rsync_excludes.txt"

# Required dependencies
DEPENDENCIES="wget cryptsetup-bin cryptsetup-initramfs grub-common grub-pc-bin grub-efi-amd64-bin parted rsync dosfstools mtools pv"

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
            echo "Use: umount -R $TARGET_MOUNT && cryptsetup close $LUKS_MAPPER_NAME"
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
            if cryptsetup status "$LUKS_MAPPER_NAME" &>/dev/null; then
                cryptsetup close "$LUKS_MAPPER_NAME"
            fi
            
            # Remove temp files
            [ -f "$TEMP_FILE" ] && rm -f "$TEMP_FILE"
            [ -f "$EXCLUDE_FILE" ] && rm -f "$EXCLUDE_FILE"
            
            # Remove mount point if empty
            [ -d "$TARGET_MOUNT" ] && rmdir "$TARGET_MOUNT" 2>/dev/null
            ;;
        *)
            echo "Invalid choice, keeping mounts active."
            ;;
    esac
}

trap cleanup EXIT

create_exclude_file() {
    cat > "$EXCLUDE_FILE" << EOF
/dev/*
/proc/*
/sys/*
/run/*
/tmp/*
/lost+found
/mnt/*
/media/*
/var/cache/*
/var/tmp/*
${TARGET_MOUNT}/*
EOF
}

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
    
    # Get actual UUIDs from the system
    local luks_part_uuid=$(get_uuid "$SECOND_PART")
    local luks_data_uuid=$(get_uuid "/dev/mapper/$LUKS_MAPPER_NAME")
    
    if [ -z "$luks_part_uuid" ] || [ -z "$luks_data_uuid" ]; then
        echo "ERROR: Failed to get UUIDs for LUKS partitions!" >&2
        exit 1
    fi

    # Verify UUIDs are correct
    echo "Verifying LUKS UUIDs:"
    echo "- Partition UUID: ${luks_part_uuid}"
    echo "- Filesystem UUID: ${luks_data_uuid}"
    lsblk -o NAME,UUID | grep -E "(${LUKS_MAPPER_NAME}|${SECOND_PART##*/})"

    # Detect swap partition if it exists
    SWAP_UUID="none"
    SWAP_PARTITION=$(blkid -t TYPE=swap -o device | head -n1)
    if [ -n "$SWAP_PARTITION" ]; then
        SWAP_UUID=$(get_uuid "$SWAP_PARTITION")
        echo "Found swap partition: $SWAP_PARTITION (UUID: $SWAP_UUID)"
    fi

    # Create /etc/crypttab
    echo "Creating /etc/crypttab..."
    cat > "${target_root}/etc/crypttab" << EOF
${LUKS_MAPPER_NAME} UUID=${luks_part_uuid} none luks,discard
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
UUID=${luks_data_uuid} /               ext4    errors=remount-ro 0       1
EOF

    # Add swap entry if swap partition exists
    if [ "$SWAP_UUID" != "none" ]; then
        echo "UUID=$SWAP_UUID none swap sw 0 0" >> "${target_root}/etc/fstab"
    fi

    # Configure resume settings for initramfs
    if [ "$SWAP_UUID" != "none" ]; then
        echo "Configuring initramfs resume settings..."
        mkdir -p "${target_root}/etc/initramfs-tools/conf.d"
        echo "RESUME=UUID=$SWAP_UUID" > "${target_root}/etc/initramfs-tools/conf.d/resume"
    fi

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
    
    cryptomount -u ${luks_part_uuid}
    set root='(crypto0)'
    search --no-floppy --fs-uuid --set=root ${luks_data_uuid}
    linux /boot/vmlinuz-${KERNEL_VERSION} root=UUID=${luks_data_uuid} cryptdevice=UUID=${luks_part_uuid}:${LUKS_MAPPER_NAME} ro quiet
    initrd /boot/${INITRD}
}

menuentry "Glitch Linux (recovery mode)" {
    insmod part_gpt
    insmod cryptodisk
    insmod luks
    insmod ext2
    
    cryptomount -u ${luks_part_uuid}
    set root='(crypto0)'
    search --no-floppy --fs-uuid --set=root ${luks_data_uuid}
    linux /boot/vmlinuz-${KERNEL_VERSION} root=UUID=${luks_data_uuid} cryptdevice=UUID=${luks_part_uuid}:${LUKS_MAPPER_NAME} ro single
    initrd /boot/${INITRD}
}

menuentry "Debian X - Encrypted Persistence" {
	linux /live/vmlinuz boot=live components quiet splash noeject findiso=${iso_path} persistent=cryptsetup persistence-encryption=luks persistence
	initrd /live/initrd.gz
}

menuentry "Grub-Multiarch (BIOS)" {
    insmod multiboot
    multiboot /boot/grub/grub_multiarch/grubfm.elf
    boot
}

menuentry "Netboot.xyz (BIOS)" {
    linux16 /boot/grub/netboot.xyz/netboot.xyz.lkrn
}

menuentry "Netboot.xyz (UEFI)" {
    chainloader /boot/grub/netboot.xyz/EFI/BOOT/BOOTX64.EFI
}

menuentry "GRUBFM (UEFI)" {
    chainloader /EFI/GRUB-FM/E2B-bootx64.efi
}

menuentry "rEFInd (UEFI)" {
    chainloader /EFI/rEFInd/bootx64.efi
}

EOF

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
apt-get install -y cryptsetup-initramfs cryptsetup

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

# Verify cryptsetup in initramfs
echo "Verifying cryptsetup in initramfs..."
lsinitramfs /boot/initrd.img-*\$(uname -r) | grep cryptsetup || echo "Warning: cryptsetup not found in initramfs"

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

main_install() {
    # List available disks
    echo -e "\nAvailable disks:"
    lsblk -d -o NAME,SIZE,MODEL | grep -v "NAME"
    
    # Get target device
    read -p "Enter target device (e.g., /dev/sdX): " TARGET_DEVICE
    [ ! -b "$TARGET_DEVICE" ] && { echo "Invalid device!"; exit 1; }
    read -p "This will ERASE ${TARGET_DEVICE}! Continue? (yes/no): " CONFIRM
    [ "$CONFIRM" != "yes" ] && exit 0

    # Flash image
    echo -e "\nDownloading and flashing image..."
    if ! wget "$FILE_URL" -O "$TEMP_FILE"; then
        echo "Download failed!" >&2
        exit 1
    fi
    
    if ! dd if="$TEMP_FILE" of="$TARGET_DEVICE" bs=4M status=progress && sync; then
        echo "Flashing failed!" >&2
        exit 1
    fi

    # Resize partitions
    echo -e "\nResizing partitions..."
    if ! sgdisk -e "$TARGET_DEVICE"; then
        echo "Failed to expand GPT data structures!" >&2
        exit 1
    fi
    
    # Determine partitions
    if [[ "$TARGET_DEVICE" =~ "nvme" ]]; then
        FIRST_PART="${TARGET_DEVICE}p1"
        SECOND_PART="${TARGET_DEVICE}p2"
    else
        FIRST_PART="${TARGET_DEVICE}1"
        SECOND_PART="${TARGET_DEVICE}2"
    fi
    
    # Wait for partitions to settle
    sleep 2
    partprobe "$TARGET_DEVICE"
    sleep 2
    
    # Unmount if mounted
    for part in "$FIRST_PART" "$SECOND_PART"; do
        if mount | grep -q "$part"; then
            umount "$part"
        fi
    done
    
    # Delete and recreate partition
    if ! sgdisk -d 2 "$TARGET_DEVICE" || \
       ! sgdisk -n 2:0:0 -t 2:8300 "$TARGET_DEVICE"; then
        echo "Failed to recreate partition!" >&2
        exit 1
    fi
    
    partprobe "$TARGET_DEVICE"
    sleep 2

    # Setup LUKS
    echo -e "\nSetting up LUKS..."
    if ! cryptsetup luksOpen "$SECOND_PART" "$LUKS_MAPPER_NAME"; then
        echo "Failed to open LUKS!" >&2
        exit 1
    fi
    
    if ! cryptsetup resize "$LUKS_MAPPER_NAME"; then
        echo "Failed to resize LUKS container!" >&2
        exit 1
    fi
    
    echo -e "\nChecking filesystem (this may take a while)..."
    if ! e2fsck -f -y -C 0 "/dev/mapper/$LUKS_MAPPER_NAME"; then
        echo "Filesystem check failed!" >&2
        exit 1
    fi
    
    echo -e "\nResizing filesystem..."
    if ! resize2fs "/dev/mapper/$LUKS_MAPPER_NAME"; then
        echo "Filesystem resize failed!" >&2
        exit 1
    fi

    # Install system
    echo -e "\nInstalling system..."
    create_exclude_file
    mkdir -p "$TARGET_MOUNT"
    
    if ! mount "/dev/mapper/$LUKS_MAPPER_NAME" "$TARGET_MOUNT"; then
        echo "Failed to mount LUKS container!" >&2
        exit 1
    fi
    
    # Mount EFI partition
    mkdir -p "${TARGET_MOUNT}/boot/efi"
    if ! mount "$FIRST_PART" "${TARGET_MOUNT}/boot/efi"; then
        echo "Failed to mount EFI partition!" >&2
        exit 1
    fi
    
    echo -e "\nStarting rsync transfer..."
    rsync -aAXH --info=progress2 --exclude-from="$EXCLUDE_FILE" \
          --exclude=/boot/efi --exclude=/boot/grub \
          / "$TARGET_MOUNT" | pv -pet
    
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
