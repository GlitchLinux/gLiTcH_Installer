#!/bin/bash

# Configuration
LUKS_MAPPER_NAME="glitch_luks"
TARGET_MOUNT="/mnt/glitch_install"
EXCLUDE_FILE="/tmp/rsync_excludes.txt"

# Required dependencies
DEPENDENCIES="wget cryptsetup-bin cryptsetup-initramfs grub-common grub-pc-bin grub-efi-amd64-bin parted rsync dosfstools mtools pv zenity"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    zenity --error --title="Permission Error" --text="This script must be run as root!" --width=300
    exit 1
fi

# Install dependencies
if ! zenity --question --title="Dependencies" --text="Install required dependencies?\n\n$DEPENDENCIES" --width=400; then
    zenity --error --title="Aborted" --text="Dependencies are required to continue." --width=300
    exit 1
fi

(
echo "10" ; sleep 1
echo "Updating package list..." ; apt update
echo "30" ; sleep 1
echo "Installing dependencies..." ; apt install -y $DEPENDENCIES
echo "100" ; sleep 1
) | zenity --progress --title="Installing Dependencies" --text="Preparing..." --percentage=0 --auto-close

if [ $? -ne 0 ]; then
    zenity --error --title="Installation Failed" --text="Failed to install dependencies!" --width=300
    exit 1
fi

# Function to clean up
cleanup() {
    choice=$(zenity --list --title="Cleanup Options" --text="Choose cleanup action:" \
                    --column="Option" --column="Description" \
                    "Keep mounts" "Keep mounts active for chroot access" \
                    "Clean up" "Unmount everything and clean up" \
                    --width=500 --height=200)
    
    case "$choice" in
        "Keep mounts")
            zenity --info --title="Cleanup" --text="Keeping mounts active. Remember to manually clean up later!\n\nUse: umount -R $TARGET_MOUNT\n$([ "$ENCRYPTED" = "yes" ] && echo "cryptsetup close $LUKS_MAPPER_NAME")" --width=400
            ;;
        "Clean up")
            (
            echo "20" ; sleep 0.5
            echo "Unmounting filesystems..." 
            # Unmount all mounted filesystems
            for mountpoint in "${TARGET_MOUNT}/boot/efi" "${TARGET_MOUNT}/dev/pts" "${TARGET_MOUNT}/dev" \
                            "${TARGET_MOUNT}/proc" "${TARGET_MOUNT}/sys" "${TARGET_MOUNT}/run"; do
                if mountpoint -q "$mountpoint"; then
                    umount -R "$mountpoint" 2>/dev/null
                fi
            done
            
            echo "40" ; sleep 0.5
            # Unmount the main filesystem
            if mountpoint -q "$TARGET_MOUNT"; then
                umount -R "$TARGET_MOUNT" 2>/dev/null
            fi
            
            echo "60" ; sleep 0.5
            # Close LUKS if open
            if [ "$ENCRYPTED" = "yes" ] && cryptsetup status "$LUKS_MAPPER_NAME" &>/dev/null; then
                cryptsetup close "$LUKS_MAPPER_NAME"
            fi
            
            echo "80" ; sleep 0.5
            # Remove temp files
            [ -f "$EXCLUDE_FILE" ] && rm -f "$EXCLUDE_FILE"
            
            # Remove mount point if empty
            [ -d "$TARGET_MOUNT" ] && rmdir "$TARGET_MOUNT" 2>/dev/null
            echo "100" ; sleep 0.5
            ) | zenity --progress --title="Cleaning Up" --text="Cleaning up..." --percentage=0 --auto-close
            ;;
        *)
            zenity --info --title="Cleanup" --text="Keeping mounts active." --width=300
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
    [ -z "$KERNEL_VERSION" ] && { zenity --error --title="Error" --text="Kernel not found!" --width=300; exit 1; }
    
    INITRD=""
    for pattern in "initrd.img-${KERNEL_VERSION}" "initramfs-${KERNEL_VERSION}.img" "initrd-${KERNEL_VERSION}.gz"; do
        [ -f "${target_root}/boot/${pattern}" ] && INITRD="$pattern" && break
    done
    [ -z "$INITRD" ] && { zenity --error --title="Error" --text="Initrd not found for kernel ${KERNEL_VERSION}" --width=300; exit 1; }
    
    zenity --info --title="Kernel Found" --text="Found kernel: vmlinuz-${KERNEL_VERSION}\nFound initrd: ${INITRD}" --width=300
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
            zenity --error --title="Error" --text="Failed to get UUIDs for partitions!" --width=300
            exit 1
        fi

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
            zenity --error --title="Error" --text="Failed to get UUID for root partition!" --width=300
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
    mount --bind /dev "${target_root}/dev" || { zenity --error --title="Error" --text="Failed to mount /dev"; exit 1; }
    mount --bind /dev/pts "${target_root}/dev/pts" || { zenity --error --title="Error" --text="Failed to mount /dev/pts"; exit 1; }
    mount -t proc proc "${target_root}/proc" || { zenity --error --title="Error" --text="Failed to mount /proc"; exit 1; }
    mount -t sysfs sys "${target_root}/sys" || { zenity --error --title="Error" --text="Failed to mount /sys"; exit 1; }
    mount -t tmpfs tmpfs "${target_root}/run" || { zenity --error --title="Error" --text="Failed to mount /run"; exit 1; }
    
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
    
    if zenity --question --title="Chroot Preparation" --text="Chroot environment ready! Would you like to automatically run the chroot commands now?" --width=400; then
        (
        echo "50" ; sleep 1
        echo "Running chroot commands..." 
        if ! chroot "${target_root}" /bin/bash -c "/chroot_prep.sh"; then
            zenity --error --title="Error" --text="Chroot preparation failed!" --width=300
            exit 1
        fi
        echo "100" ; sleep 1
        ) | zenity --progress --title="Chroot Preparation" --text="Preparing..." --percentage=0 --auto-close
        zenity --info --title="Success" --text="Chroot preparation completed successfully!" --width=300
    else
        zenity --info --title="Chroot Instructions" --text="You can manually run the chroot commands later with:\n\n  chroot ${target_root} /bin/bash\n  /chroot_prep.sh" --width=400
    fi
}

partition_disk() {
    local target_device="$1"
    
    (
    echo "10" ; sleep 0.5
    echo "Wiping disk..." 
    wipefs -a "$target_device"
    
    echo "20" ; sleep 0.5
    echo "Creating GPT partition table..." 
    parted -s "$target_device" mklabel gpt
    
    echo "30" ; sleep 0.5
    echo "Creating EFI partition (100MB)..." 
    parted -s "$target_device" mkpart primary fat32 1MiB 101MiB
    parted -s "$target_device" set 1 esp on
    
    echo "50" ; sleep 0.5
    echo "Creating root partition..." 
    parted -s "$target_device" mkpart primary ext4 101MiB 100%
    
    echo "60" ; sleep 0.5
    echo "Waiting for partitions to settle..." 
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
    
    echo "70" ; sleep 0.5
    echo "Formatting EFI partition as FAT32..." 
    mkfs.vfat -F32 "$EFI_PART"
    
    if [ "$ENCRYPTED" = "yes" ]; then
        echo "80" ; sleep 0.5
        echo "Setting up LUKS encryption on root partition..." 
        cryptsetup luksFormat --type luks1 -v -y "$ROOT_PART" || { zenity --error --title="Error" --text="LUKS setup failed!"; exit 1; }
        
        echo "90" ; sleep 0.5
        echo "Opening encrypted partition..." 
        cryptsetup open "$ROOT_PART" "$LUKS_MAPPER_NAME" || { zenity --error --title="Error" --text="Failed to open LUKS partition!"; exit 1; }
        
        echo "95" ; sleep 0.5
        echo "Formatting encrypted partition as ext4..." 
        mkfs.ext4 "/dev/mapper/$LUKS_MAPPER_NAME" || { zenity --error --title="Error" --text="Failed to format encrypted partition!"; exit 1; }
    else
        echo "95" ; sleep 0.5
        echo "Formatting root partition as ext4..." 
        mkfs.ext4 "$ROOT_PART" || { zenity --error --title="Error" --text="Failed to format root partition!"; exit 1; }
    fi
    echo "100" ; sleep 0.5
    ) | zenity --progress --title="Partitioning Disk" --text="Preparing..." --percentage=0 --auto-close
}

main_install() {
    # List available disks
    disks_info=$(lsblk -d -o NAME,SIZE,MODEL | grep -v "NAME" | awk '{print $1 " " $2 " " $3}')
    
    # Get target device
    TARGET_DEVICE=$(zenity --list --title="Select Target Device" --text="Available disks:" \
                          --column="Device" --column="Size" --column="Model" \
                          $(echo "$disks_info") \
                          --width=600 --height=400)
    [ -z "$TARGET_DEVICE" ] && exit 0
    TARGET_DEVICE="/dev/$TARGET_DEVICE"
    
    if ! zenity --question --title="Warning" --text="This will ERASE ALL DATA on ${TARGET_DEVICE}!\n\nAre you sure you want to continue?" --width=400; then
        exit 0
    fi
    
    # Ask for encryption
    ENCRYPTED=$(zenity --list --title="Encryption" --text="Enable disk encryption?" \
                      --column="Option" --column="Description" \
                      "yes" "Encrypt the root partition (recommended)" \
                      "no" "No encryption" \
                      --width=400 --height=200)
    [ -z "$ENCRYPTED" ] && exit 0
    
    # Partition and format disk
    partition_disk "$TARGET_DEVICE"
    
    # Mount the filesystems
    (
    echo "20" ; sleep 0.5
    echo "Mounting filesystems..." 
    mkdir -p "$TARGET_MOUNT"
    
    if [ "$ENCRYPTED" = "yes" ]; then
        mount "/dev/mapper/$LUKS_MAPPER_NAME" "$TARGET_MOUNT" || { zenity --error --title="Error" --text="Failed to mount encrypted partition!"; exit 1; }
    else
        mount "$ROOT_PART" "$TARGET_MOUNT" || { zenity --error --title="Error" --text="Failed to mount root partition!"; exit 1; }
    fi
    
    echo "40" ; sleep 0.5
    mkdir -p "${TARGET_MOUNT}/boot/efi"
    mount "$EFI_PART" "${TARGET_MOUNT}/boot/efi" || { zenity --error --title="Error" --text="Failed to mount EFI partition!"; exit 1; }
    
    echo "60" ; sleep 0.5
    # Install system
    echo "Creating exclude file..." 
    create_exclude_file
    
    echo "80" ; sleep 0.5
    echo "Starting rsync transfer..." 
    rsync -aAXH --info=progress2 --exclude-from="$EXCLUDE_FILE" \
          --exclude=/boot/efi --exclude=/boot/grub \
          / "$TARGET_MOUNT" | pv -pet | zenity --progress --title="Copying Files" --text="Transferring system..." --percentage=0 --auto-close
    
    echo "90" ; sleep 0.5
    echo "Configuring system files..." 
    configure_system_files "$TARGET_MOUNT" "$TARGET_DEVICE"
    
    echo "100" ; sleep 0.5
    ) | zenity --progress --title="Installing System" --text="Preparing..." --percentage=0 --auto-close
    
    prepare_chroot "$TARGET_MOUNT" "$TARGET_DEVICE"
}

# Start the installation
main_install
