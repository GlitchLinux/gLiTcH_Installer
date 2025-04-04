#!/bin/bash

# Configuration
LUKS_MAPPER_NAME="glitch_luks"
TARGET_MOUNT="/mnt/glitch_install"
EXCLUDE_FILE="/tmp/rsync_excludes.txt"
MINIMAL_PACKAGES="systemd,systemd-sysv,udev,dbus,logrotate,bash,coreutils,util-linux,findutils,grep,sed,gawk,tar,gzip,xz-utils,bzip2,less,procps,iproute2,iputils-ping,net-tools,dhcpcd5,openssh-client,openssh-server,ca-certificates,apt,apt-utils,gnupg,debian-archive-keyring,wget,curl,rsync,nano,vim-tiny,less,locales,adduser,passwd,login,libpam-systemd,ifupdown,isc-dhcp-client,netbase,initramfs-tools,linux-image-amd64,linux-headers-amd64,grub-common,grub-pc-bin,grub-efi-amd64-bin,cryptsetup,cryptsetup-initramfs"

# Required dependencies
DEPENDENCIES="wget cryptsetup-bin cryptsetup-initramfs grub-common grub-pc-bin grub-efi-amd64-bin parted rsync dosfstools mtools pv debootstrap"

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
            
            # Remove temp files
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
/var/log/*
/var/lib/apt/lists/*
/var/lib/dhcp/*
/swapfile
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

configure_efi_directory() {
    local efi_mount="$1"
    
    echo "Configuring EFI directory structure..."
    mkdir -p "${efi_mount}/EFI/BOOT"
    mkdir -p "${efi_mount}/EFI/GRUB"
    
    # Copy bootloader files to both locations
    if [ -f "${efi_mount}/EFI/GRUB/grubx64.efi" ]; then
        cp "${efi_mount}/EFI/GRUB/grubx64.efi" "${efi_mount}/EFI/BOOT/bootx64.efi"
        cp "${efi_mount}/EFI/GRUB/grubx64.efi" "${efi_mount}/EFI/BOOT/grubx64.efi"
        cp "${efi_mount}/EFI/GRUB/grub.cfg" "${efi_mount}/EFI/BOOT/grub.cfg"
    else
        echo "Warning: GRUB EFI files not found in expected location!"
    fi
}

copy_user_data() {
    local target_root="$1"
    
    echo -e "\nCopying user accounts and home directories..."
    
    # Copy passwd, shadow, group, gshadow files
    echo "Copying user account files..."
    cp /etc/passwd "${target_root}/etc/"
    cp /etc/shadow "${target_root}/etc/"
    cp /etc/group "${target_root}/etc/"
    cp /etc/gshadow "${target_root}/etc/" 2>/dev/null || true
    
    # Copy all home directories
    echo "Copying home directories..."
    mkdir -p "${target_root}/home"
    rsync -a /home/ "${target_root}/home/"
    
    # Copy skel directory
    echo "Copying skeleton directory..."
    rsync -a /etc/skel/ "${target_root}/etc/skel/"
    
    # Copy user-specific configurations
    echo "Copying user configurations..."
    for userdir in /home/*; do
        user=$(basename "$userdir")
        mkdir -p "${target_root}/home/${user}"
        
        # Copy important dotfiles and directories
        for item in .bashrc .profile .ssh .config .local; do
            if [ -e "/home/${user}/${item}" ]; then
                rsync -a "/home/${user}/${item}" "${target_root}/home/${user}/"
            fi
        done
    done
    
    # Ensure proper permissions
    echo "Setting correct permissions..."
    chmod 755 "${target_root}/home"
    for userdir in "${target_root}/home/*"; do
        user=$(basename "$userdir")
        chown -R "${user}:${user}" "${target_root}/home/${user}"
    done
    
    # Copy sudoers file if it exists
    if [ -f "/etc/sudoers" ]; then
        echo "Copying sudoers file..."
        cp /etc/sudoers "${target_root}/etc/"
    fi
    
    # Copy sudoers.d directory
    if [ -d "/etc/sudoers.d" ]; then
        echo "Copying sudoers.d directory..."
        mkdir -p "${target_root}/etc/sudoers.d"
        rsync -a /etc/sudoers.d/ "${target_root}/etc/sudoers.d/"
    fi
}

cleanup_target_filesystem() {
    local target_root="$1"
    
    echo -e "\nCleaning up target filesystem..."
    
    # Remove unnecessary documentation and man pages
    echo "Removing documentation and man pages..."
    rm -rf "${target_root}/usr/share/doc/*"
    rm -rf "${target_root}/usr/share/man/*"
    rm -rf "${target_root}/usr/share/info/*"
    
    # Remove locale files except en_US
    echo "Cleaning up locales..."
    find "${target_root}/usr/share/locale" -mindepth 1 -maxdepth 1 ! -name 'en_US' -exec rm -rf {} +
    
    # Clean up apt cache
    echo "Cleaning up package caches..."
    rm -rf "${target_root}/var/cache/apt/*"
    rm -rf "${target_root}/var/lib/apt/lists/*"
    
    # Remove temporary files
    echo "Removing temporary files..."
    rm -rf "${target_root}/tmp/*"
    rm -rf "${target_root}/var/tmp/*"
    
    # Remove old kernels (keep only current one)
    echo "Cleaning up old kernels..."
    current_kernel=$(ls "${target_root}/boot" | grep -E "vmlinuz-[0-9]" | sort -V | tail -n1 | sed 's/vmlinuz-//')
    for kernel in $(ls "${target_root}/boot" | grep -E "vmlinuz-[0-9]" | sort -V | sed 's/vmlinuz-//'); do
        if [ "$kernel" != "$current_kernel" ]; then
            rm -f "${target_root}/boot/vmlinuz-${kernel}"
            rm -f "${target_root}/boot/initrd.img-${kernel}"
            rm -f "${target_root}/boot/System.map-${kernel}"
            rm -f "${target_root}/boot/config-${kernel}"
        fi
    done
    
    # Remove unnecessary modules
    echo "Cleaning up kernel modules..."
    for module in $(ls "${target_root}/lib/modules"); do
        if [ "$module" != "$current_kernel" ]; then
            rm -rf "${target_root}/lib/modules/${module}"
        fi
    done
    
    # Remove unused firmware
    echo "Cleaning up firmware..."
    rm -rf "${target_root}/lib/firmware/*"
    
    # Remove X11 and desktop related files (but keep basic Xauthority)
    echo "Removing X11 and desktop files..."
    rm -rf "${target_root}/usr/share/X11"
    rm -rf "${target_root}/usr/share/xsessions"
    rm -rf "${target_root}/usr/share/wayland-sessions"
    rm -rf "${target_root}/usr/share/desktop-directories"
    rm -rf "${target_root}/usr/share/applications"
    
    # Remove systemd journal logs
    echo "Cleaning up systemd journal..."
    rm -rf "${target_root}/var/log/journal/*"
    
    echo "Target filesystem cleanup complete."
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

    # Configure EFI directory structure
    configure_efi_directory "${target_root}/boot/efi"
    
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

# First update initramfs with proper mounts available
echo "Updating initramfs..."
update-initramfs -u -k all || { echo "Initramfs update failed"; exit 1; }

# Then install GRUB
echo "Installing GRUB..."
if [ -d "/sys/firmware/efi" ]; then
    # Create standard EFI directory structure
    mkdir -p /boot/efi/EFI/{BOOT,GRUB}
    
    # Install GRUB for EFI
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck --removable || { echo "EFI GRUB install failed"; exit 1; }
    
    # Copy EFI files to both locations
    cp /boot/efi/EFI/GRUB/grubx64.efi /boot/efi/EFI/BOOT/bootx64.efi
    cp /boot/efi/EFI/GRUB/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi
    cp /boot/grub/grub.cfg /boot/efi/EFI/BOOT/grub.cfg
else
    # Install GRUB for BIOS
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

minimal_system_install() {
    local target_root="$1"
    
    echo -e "\nInstalling minimal system..."
    
    # Create essential directories
    mkdir -p "${target_root}/etc/apt"
    mkdir -p "${target_root}/var/lib/apt/lists/partial"
    mkdir -p "${target_root}/var/cache/apt/archives/partial"
    
    # Copy basic apt configuration
    cp -r /etc/apt/sources.list "${target_root}/etc/apt/"
    cp -r /etc/apt/sources.list.d "${target_root}/etc/apt/" 2>/dev/null || true
    cp -r /etc/apt/trusted.gpg "${target_root}/etc/apt/" 2>/dev/null || true
    cp -r /etc/apt/trusted.gpg.d "${target_root}/etc/apt/" 2>/dev/null || true
    
    # Set up basic fstab
    cat > "${target_root}/etc/fstab" << EOF
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
EOF
    
    # Install minimal packages
    echo "Installing minimal packages..."
    debootstrap --variant=minbase --include="$MINIMAL_PACKAGES" stable "$target_root" http://deb.debian.org/debian
    
    # Copy essential files from host
    echo "Copying essential configuration files..."
    cp /etc/hostname "${target_root}/etc/" 2>/dev/null || echo "glitch" > "${target_root}/etc/hostname"
    cp /etc/hosts "${target_root}/etc/" 2>/dev/null || echo "127.0.0.1 localhost" > "${target_root}/etc/hosts"
    cp /etc/localtime "${target_root}/etc/" 2>/dev/null || true
    cp /etc/timezone "${target_root}/etc/" 2>/dev/null || true
    cp /etc/locale.gen "${target_root}/etc/" 2>/dev/null || true
    cp /etc/default/locale "${target_root}/etc/default/" 2>/dev/null || true
    cp /etc/default/keyboard "${target_root}/etc/default/" 2>/dev/null || true
    
    # Set up basic network
    echo "Setting up basic network configuration..."
    cat > "${target_root}/etc/network/interfaces" << EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
    
    # Create essential device nodes
    echo "Creating essential device nodes..."
    mknod -m 666 "${target_root}/dev/null" c 1 3
    mknod -m 666 "${target_root}/dev/zero" c 1 5
    mknod -m 666 "${target_root}/dev/random" c 1 8
    mknod -m 666 "${target_root}/dev/urandom" c 1 9
    mknod -m 666 "${target_root}/dev/tty" c 5 0
    mknod -m 600 "${target_root}/dev/console" c 5 1
    
    # Copy user accounts and home directories
    copy_user_data "$target_root"
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
    
    # Ask for installation type
    echo -e "\nInstallation type:"
    echo "1) Minimal system (recommended)"
    echo "2) Full system copy"
    read -p "Choose installation type [1-2]: " INSTALL_TYPE
    
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
    
    # Install system based on chosen method
    case $INSTALL_TYPE in
        1)
            minimal_system_install "$TARGET_MOUNT"
            ;;
        2)
            echo -e "\nInstalling system..."
            create_exclude_file
            
            echo -e "\nStarting rsync transfer..."
            rsync -aAXH --info=name0,progress2 --exclude-from="$EXCLUDE_FILE" \
                  --exclude=/boot/efi --exclude=/boot/grub \
                  / "$TARGET_MOUNT" | pv -pet
            ;;
        *)
            echo "Invalid choice, using minimal installation."
            minimal_system_install "$TARGET_MOUNT"
            ;;
    esac
    
    # Configure system files
    configure_system_files "$TARGET_MOUNT" "$TARGET_DEVICE"
    
    # Clean up target filesystem (but preserve user data)
    cleanup_target_filesystem "$TARGET_MOUNT"
    
    # Prepare chroot environment
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