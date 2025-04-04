#!/bin/bash

# Configuration
LUKS_MAPPER_NAME="glitch_luks"
TARGET_MOUNT="/mnt/glitch_install"
MINIMAL_PACKAGES="systemd,udev,dbus,logrotate,bash,coreutils,util-linux,findutils,grep,sed,gawk,tar,gzip,xz-utils,bzip2,less,procps,iproute2,iputils-ping,net-tools,dhcpcd5,openssh-client,openssh-server,ca-certificates,apt,apt-utils,gnupg,debian-archive-keyring,wget,curl,rsync,nano,vim-tiny,less,locales,adduser,passwd,login,libpam-systemd,ifupdown,isc-dhcp-client,netbase,initramfs-tools,linux-image-amd64,grub-common,grub-pc-bin,grub-efi-amd64-bin,cryptsetup,cryptsetup-initramfs"

# Required dependencies
DEPENDENCIES="wget cryptsetup-bin cryptsetup-initramfs grub-common grub-pc-bin grub-efi-amd64-bin parted rsync dosfstools mtools pv debootstrap"

# Global variables for partition paths
EFI_PART=""
ROOT_PART=""
ENCRYPTED="no"

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
    [ -z "$KERNEL_VERSION" ] && { echo "ERROR: Kernel not found in ${target_root}/boot!" >&2; exit 1; }
    
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

copy_user_data() {
    local target_root="$1"
    
    echo -e "\nCopying user accounts and home directories..."
    
    # Get list of all regular users (UID >= 1000)
    local users=$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1}' /etc/passwd)
    
    if [ -z "$users" ]; then
        echo "Warning: No regular users found to copy!"
        return
    fi

    # Copy user account files
    echo "Copying user account files..."
    cp /etc/passwd "${target_root}/etc/"
    cp /etc/shadow "${target_root}/etc/"
    cp /etc/group "${target_root}/etc/"
    cp /etc/gshadow "${target_root}/etc/" 2>/dev/null || true
    
    # Copy each user's home directory
    for user in $users; do
        if [ -d "/home/${user}" ]; then
            echo "Copying home directory for ${user}..."
            mkdir -p "${target_root}/home/${user}"
            rsync -a "/home/${user}/" "${target_root}/home/${user}/"
            
            # Set correct ownership
            chown -R "${user}:${user}" "${target_root}/home/${user}"
        else
            echo "Warning: Home directory for ${user} not found!"
        fi
    done
    
    # Copy skel directory
    echo "Copying skeleton directory..."
    rsync -a /etc/skel/ "${target_root}/etc/skel/"
    
    # Copy sudoers configuration
    echo "Copying sudo configuration..."
    if [ -f "/etc/sudoers" ]; then
        cp /etc/sudoers "${target_root}/etc/"
    fi
    
    if [ -d "/etc/sudoers.d" ]; then
        mkdir -p "${target_root}/etc/sudoers.d"
        rsync -a /etc/sudoers.d/ "${target_root}/etc/sudoers.d/"
    fi
}

minimal_system_install() {
    local target_root="$1"
    
    echo -e "\nInstalling minimal system..."
    
    # Install minimal base system with bash included
    echo "Installing minimal packages..."
    if ! debootstrap --variant=minbase --include="$MINIMAL_PACKAGES" stable "$target_root" http://deb.debian.org/debian; then
        echo "Failed to install base system!" >&2
        exit 1
    fi
    
    # Copy essential configuration files
    echo "Copying system configuration..."
    cp /etc/hostname "${target_root}/etc/" 2>/dev/null || echo "glitch" > "${target_root}/etc/hostname"
    cp /etc/hosts "${target_root}/etc/" 2>/dev/null || echo "127.0.0.1 localhost" > "${target_root}/etc/hosts"
    cp /etc/localtime "${target_root}/etc/" 2>/dev/null || true
    cp /etc/timezone "${target_root}/etc/" 2>/dev/null || true
    cp /etc/locale.gen "${target_root}/etc/" 2>/dev/null || true
    
    # Copy kernel and initramfs
    echo "Copying kernel files..."
    mkdir -p "${target_root}/boot"
    if [ -d "/boot" ]; then
        rsync -a /boot/ "${target_root}/boot/" --exclude=efi --exclude=grub
    else
        echo "Warning: /boot directory not found!"
    fi
    
    # Copy user data
    copy_user_data "$target_root"
    
    # Set up basic network
    echo "Configuring network..."
    mkdir -p "${target_root}/etc/network"
    cat > "${target_root}/etc/network/interfaces" << EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
    
    # Create essential device nodes
    echo "Creating device nodes..."
    mknod -m 666 "${target_root}/dev/null" c 1 3
    mknod -m 666 "${target_root}/dev/zero" c 1 5
    mknod -m 666 "${target_root}/dev/random" c 1 8
    mknod -m 666 "${target_root}/dev/urandom" c 1 9
    mknod -m 666 "${target_root}/dev/tty" c 5 0
    mknod -m 600 "${target_root}/dev/console" c 5 1
}

configure_system_files() {
    local target_root="$1"
    local target_device="$2"
    
    if [ "$ENCRYPTED" = "yes" ]; then
        # Get UUIDs for encrypted setup
        local root_part_uuid=$(get_uuid "$ROOT_PART")
        local root_fs_uuid=$(get_uuid "/dev/mapper/$LUKS_MAPPER_NAME")
        
        if [ -z "$root_part_uuid" ] || [ -z "$root_fs_uuid" ]; then
            echo "ERROR: Failed to get UUIDs for partitions!" >&2
            exit 1
        fi

        echo "Configuring encrypted system..."
        echo "- Partition UUID: ${root_part_uuid}"
        echo "- Filesystem UUID: ${root_fs_uuid}"

        # Create crypttab
        cat > "${target_root}/etc/crypttab" << EOF
${LUKS_MAPPER_NAME} UUID=${root_part_uuid} none luks,discard
EOF

        # Configure cryptsetup for initramfs
        mkdir -p "${target_root}/etc/initramfs-tools/conf.d"
        cat > "${target_root}/etc/initramfs-tools/conf.d/cryptsetup" << EOF
KEYFILE_PATTERN=/etc/luks/*.keyfile
UMASK=0077
EOF

        # Add required modules to initramfs
        cat > "${target_root}/etc/initramfs-tools/modules" << EOF
dm-crypt
cryptodisk
luks
aes
sha256
ext4
EOF
    else
        # Unencrypted setup
        local root_fs_uuid=$(get_uuid "$ROOT_PART")
        
        if [ -z "$root_fs_uuid" ]; then
            echo "ERROR: Failed to get UUID for root partition!" >&2
            exit 1
        fi
    fi

    # Create fstab
    echo "Creating /etc/fstab..."
    local efi_fs_uuid=$(get_uuid "$EFI_PART")
    
    if [ "$ENCRYPTED" = "yes" ]; then
        local root_fs_uuid=$(get_uuid "/dev/mapper/$LUKS_MAPPER_NAME")
        cat > "${target_root}/etc/fstab" << EOF
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
UUID=${root_fs_uuid} /               ext4    errors=remount-ro 0       1
UUID=${efi_fs_uuid}  /boot/efi       vfat    umask=0077      0       1
EOF
    else
        local root_fs_uuid=$(get_uuid "$ROOT_PART")
        cat > "${target_root}/etc/fstab" << EOF
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
UUID=${root_fs_uuid} /               ext4    errors=remount-ro 0       1
UUID=${efi_fs_uuid}  /boot/efi       vfat    umask=0077      0       1
EOF
    fi

    # Configure GRUB
    echo "Configuring GRUB..."
    find_kernel_initrd "$target_root"
    
    mkdir -p "${target_root}/etc/default"
    echo "GRUB_ENABLE_CRYPTODISK=y" >> "${target_root}/etc/default/grub"
    
    mkdir -p "${target_root}/boot/grub"
    if [ "$ENCRYPTED" = "yes" ]; then
        local root_part_uuid=$(get_uuid "$ROOT_PART")
        local root_fs_uuid=$(get_uuid "/dev/mapper/$LUKS_MAPPER_NAME")
        
        cat > "${target_root}/boot/grub/grub.cfg" << EOF
menuentry "Glitch Linux" {
    insmod part_gpt
    insmod cryptodisk
    insmod luks
    insmod ext2
    
    cryptomount -u ${root_part_uuid}
    set root='(crypto0)'
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
    linux /boot/vmlinuz-${KERNEL_VERSION} root=UUID=${root_fs_uuid} cryptdevice=UUID=${root_part_uuid}:${LUKS_MAPPER_NAME} ro single
    initrd /boot/${INITRD}
}
EOF
    else
        local root_fs_uuid=$(get_uuid "$ROOT_PART")
        
        cat > "${target_root}/boot/grub/grub.cfg" << EOF
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
}

prepare_chroot() {
    local target_root="$1"
    local target_device="$2"
    
    echo "Preparing chroot environment..."
    
    # Mount required filesystems
    mount --bind /dev "${target_root}/dev"
    mount --bind /dev/pts "${target_root}/dev/pts"
    mount -t proc proc "${target_root}/proc"
    mount -t sysfs sys "${target_root}/sys"
    mount -t tmpfs tmpfs "${target_root}/run"
    
    # Copy DNS config
    [ -e "/etc/resolv.conf" ] && cp --dereference /etc/resolv.conf "${target_root}/etc/"
    
    # Create chroot setup script
    cat > "${target_root}/chroot_prep.sh" << EOF
#!/bin/sh
# Set hostname
echo "glitch" > /etc/hostname
echo "127.0.1.1 glitch" >> /etc/hosts

# Install crypto tools if encrypted
if [ "$ENCRYPTED" = "yes" ]; then
    echo "Installing cryptsetup..."
    apt-get update
    apt-get install -y cryptsetup-initramfs cryptsetup
fi

# Update initramfs
echo "Updating initramfs..."
update-initramfs -u -k all

# Enable cryptodisk
echo "grub-cryptodisk enable = y" >> /etc/default/grub

# Install GRUB packages
echo "Installing GRUB EFI packages..."
apt-get update
apt-get install -y grub-efi

# Install GRUB
echo "Installing GRUB..."
if [ -d "/sys/firmware/efi" ]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck --removable
else
    grub-install ${target_device} --recheck
fi

# Update GRUB
echo "Updating GRUB configuration..."
update-grub

# Clean up
rm -f /chroot_prep.sh
EOF

    chmod +x "${target_root}/chroot_prep.sh"
    
    # Auto-run chroot commands using /bin/sh since bash might not be available yet
    echo "Running chroot setup..."
    if ! chroot "${target_root}" /bin/sh -c "/chroot_prep.sh"; then
        echo "Chroot preparation failed!" >&2
        exit 1
    fi
    echo "Chroot preparation completed successfully!"
}

partition_disk() {
    local target_device="$1"
    
    echo "Partitioning ${target_device}..."
    
    # Wipe disk and create GPT partition table
    wipefs -a "$target_device"
    parted -s "$target_device" mklabel gpt
    
    # Create EFI partition (100MB)
    parted -s "$target_device" mkpart primary fat32 1MiB 101MiB
    parted -s "$target_device" set 1 esp on
    
    # Create root partition (remaining space)
    parted -s "$target_device" mkpart primary ext4 101MiB 100%
    
    # Wait for partitions to be recognized
    sleep 2
    partprobe "$target_device"
    sleep 2
    
    # Determine partition paths - use global variables
    if [[ "$target_device" =~ "nvme" ]]; then
        EFI_PART="${target_device}p1"
        ROOT_PART="${target_device}p2"
    else
        EFI_PART="${target_device}1"
        ROOT_PART="${target_device}2"
    fi
    
    echo "Created partitions:"
    echo "  EFI: $EFI_PART"
    echo "  ROOT: $ROOT_PART"
    
    # Format partitions
    echo "Formatting partitions..."
    mkfs.vfat -F32 "$EFI_PART"
    
    if [ "$ENCRYPTED" = "yes" ]; then
        echo "Setting up LUKS encryption..."
        cryptsetup luksFormat --type luks1 -v -y "$ROOT_PART"
        cryptsetup open "$ROOT_PART" "$LUKS_MAPPER_NAME"
        mkfs.ext4 "/dev/mapper/$LUKS_MAPPER_NAME"
    else
        mkfs.ext4 "$ROOT_PART"
    fi
}

post_installation_steps() {
    local target_root="$1"
    
    echo "Running post-installation steps..."
    
    # Create post-installation script
    cat > "${target_root}/post_install.sh" << EOF
#!/bin/sh
# Enable cryptodisk
echo "grub-cryptodisk enable = y" >> /etc/default/grub

# Update and install GRUB EFI
apt update && apt install -y grub-efi

# Install GRUB to the EFI partition
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck --removable

# Update GRUB configuration
update-grub

# Clean up
rm -f /post_install.sh
EOF

    chmod +x "${target_root}/post_install.sh"
    
    # Execute post-installation script in chroot
    echo "Executing post-installation script..."
    if ! chroot "${target_root}" /bin/sh -c "/post_install.sh"; then
        echo "Post-installation steps failed!" >&2
        exit 1
    fi
    echo "Post-installation steps completed successfully!"
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
    read -p "Enable disk encryption? (yes/no) [default: yes]: " ENCRYPT_CHOICE
    ENCRYPTED=${ENCRYPT_CHOICE:-yes}
    
    # Partition and format disk
    partition_disk "$TARGET_DEVICE"
    
    # Mount filesystems
    echo "Mounting filesystems..."
    mkdir -p "$TARGET_MOUNT"
    
    if [ "$ENCRYPTED" = "yes" ]; then
        mount "/dev/mapper/$LUKS_MAPPER_NAME" "$TARGET_MOUNT"
    else
        mount "$ROOT_PART" "$TARGET_MOUNT"
    fi
    
    mkdir -p "${TARGET_MOUNT}/boot/efi"
    mount "$EFI_PART" "${TARGET_MOUNT}/boot/efi"
    
    # Install minimal system
    minimal_system_install "$TARGET_MOUNT"
    
    # Configure system files
    configure_system_files "$TARGET_MOUNT" "$TARGET_DEVICE"
    
    # Prepare chroot and install bootloader
    prepare_chroot "$TARGET_MOUNT" "$TARGET_DEVICE"
    
    # Run post-installation steps
    post_installation_steps "$TARGET_MOUNT"
    
    echo -e "\nInstallation complete!"
    echo "You may now reboot into your new system."
}

main_install
