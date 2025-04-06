#!/bin/bash

# gLiTcH System Installer
# A graphical live installer using Zenity with unsquashfs progress monitoring

# Enable logging
LOG_FILE="/tmp/glitch-installer.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Starting gLiTcH System Installer..."

# Function to display errors
show_error() {
    zenity --error --title="Installation Error" --text="$1\n\nCheck the log file: $LOG_FILE" --width=400
    exit 1
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    zenity --error --title="Error" --text="This script must be run as root (sudo)."
    exit 1
fi

# Verify required tools are installed
for tool in zenity parted mkfs.fat mkfs.ext4 unsquashfs pv; do
    if ! command -v "$tool" &> /dev/null; then
        if [ "$tool" = "pv" ]; then
            zenity --info --title="Missing Tool" --text="The 'pv' tool is not installed. Progress monitoring will be limited.\nConsider installing it with: apt-get install pv" --width=400
        else
            show_error "Required tool not found: $tool\nPlease install it and try again."
        fi
    fi
done

# Welcome message
zenity --info --title="gLiTcH System Installer" --text="Welcome to the gLiTcH Linux installer.\n\nThis will install gLiTcH Linux on your system.\n\nWARNING: This will ERASE ALL DATA on the selected disk!" --width=400

# Get available disks using a more reliable method
echo "Detecting available disks..."
TEMP_DISKS_FILE=$(mktemp)
lsblk -d -n -o NAME,SIZE,MODEL -e 7,11 | grep -v "^fd" > "$TEMP_DISKS_FILE"
echo "Detected disks:"
cat "$TEMP_DISKS_FILE"

# Create a temporary file for disk options
DISK_OPTIONS_FILE=$(mktemp)
while read -r name size model; do
    echo "/dev/$name" >> "$DISK_OPTIONS_FILE"
done < "$TEMP_DISKS_FILE"

# Check if we have any disks
if [ ! -s "$DISK_OPTIONS_FILE" ]; then
    show_error "No suitable disks found for installation."
fi

# Display a simple list of disks
DISKS=$(cat "$DISK_OPTIONS_FILE")
echo "Available disks for selection: $DISKS"

# Let user select disk (simplified approach)
SELECTED_DISK=$(zenity --list --title="Select Disk" --text="Select the disk to install gLiTcH Linux:" \
    --radiolist --column="Select" --column="Device" \
    $(for disk in $DISKS; do echo "FALSE $disk"; done | sed 's/FALSE/TRUE/1') \
    --height=300 --width=300 --hide-header)

if [ -z "$SELECTED_DISK" ]; then
    zenity --error --title="Error" --text="No disk selected. Installation aborted."
    exit 1
fi

# Verify selected disk exists
if [ ! -b "$SELECTED_DISK" ]; then
    show_error "Selected disk $SELECTED_DISK does not exist or is not a block device."
fi

echo "Selected disk: $SELECTED_DISK"

# Display disk information for confirmation
DISK_INFO=$(lsblk -n -o SIZE,MODEL "$SELECTED_DISK" | head -1)
if ! zenity --question --title="Confirm Disk Selection" --text="You selected: $SELECTED_DISK ($DISK_INFO)\n\nWARNING: ALL DATA ON THIS DISK WILL BE ERASED!\n\nDo you want to continue?" --width=450; then
    zenity --info --title="Installation Aborted" --text="Installation has been aborted."
    exit 0
fi

# Function to update progress
update_progress() {
    local percent="$1"
    local message="$2"
    echo "$percent"
    echo "# $message"
}

# Initial progress dialog
{
    update_progress 0 "Preparing for installation..."
    
    # Make sure the disk isn't mounted
    update_progress 5 "Unmounting any partitions from $SELECTED_DISK..."
    mounted_parts=$(mount | grep "$SELECTED_DISK" | awk '{print $1}')
    for part in $mounted_parts; do
        umount -f "$part" 2>/dev/null || true
    done
    
    # Clear partition table using parted
    update_progress 10 "Creating partition table on $SELECTED_DISK..."
    
    # Stop any services that might be using the disk
    systemctl stop udisks2.service 2>/dev/null || true
    
    # Create new GPT partition table
    parted -s "$SELECTED_DISK" mklabel gpt || {
        echo "Failed to create GPT label with parted, retrying with fdisk"
        echo "g" | fdisk "$SELECTED_DISK" || show_error "Failed to create GPT label"
    }
    sync
    sleep 2
    
    # Create partitions using parted
    update_progress 15 "Creating partitions..."
    parted -s "$SELECTED_DISK" mkpart EFI-DEB fat32 1MiB 49MiB || show_error "Failed to create EFI partition"
    parted -s "$SELECTED_DISK" set 1 esp on || show_error "Failed to set ESP flag"
    parted -s "$SELECTED_DISK" mkpart gLiTcH-Linux ext4 51MiB 100% || show_error "Failed to create root partition"
    sync
    sleep 3
    
    # Determine partitions based on disk naming convention
    update_progress 20 "Identifying partitions..."
    # Force kernel to re-read partition table
    partprobe "$SELECTED_DISK" || true
    sleep 2
    
    # Get partition names
    if [[ "$SELECTED_DISK" == *"nvme"* ]] || [[ "$SELECTED_DISK" == *"mmcblk"* ]]; then
        # For NVMe drives (nvme0n1p1) or MMC devices (mmcblk0p1)
        EFI_PARTITION="${SELECTED_DISK}p1"
        ROOT_PARTITION="${SELECTED_DISK}p2"
    else
        # For regular disks (sda1, vda1)
        EFI_PARTITION="${SELECTED_DISK}1"
        ROOT_PARTITION="${SELECTED_DISK}2"
    fi
    
    echo "EFI Partition: $EFI_PARTITION"
    echo "Root Partition: $ROOT_PARTITION"
    
    # Wait for partitions to appear in /dev
    WAIT_SECONDS=10
    echo "Waiting up to $WAIT_SECONDS seconds for partitions to appear..."
    for i in $(seq 1 $WAIT_SECONDS); do
        if [ -b "$EFI_PARTITION" ] && [ -b "$ROOT_PARTITION" ]; then
            echo "Partitions found after $i seconds."
            break
        fi
        echo "Waiting for partitions ($i/$WAIT_SECONDS)..."
        sleep 1
    done
    
    # Final check for partitions
    if [ ! -b "$EFI_PARTITION" ] || [ ! -b "$ROOT_PARTITION" ]; then
        echo "Listing available block devices:"
        ls -la /dev/sd* /dev/nvme* /dev/mmcblk* /dev/vd* 2>/dev/null || true
        show_error "Partitions not found after creation. Installation cannot continue."
    fi
    
    # Format partitions
    update_progress 25 "Formatting EFI partition: $EFI_PARTITION..."
    mkfs.fat -F 32 -n "EFI-DEB" "$EFI_PARTITION" || show_error "Failed to format EFI partition"
    
    update_progress 30 "Formatting root partition: $ROOT_PARTITION..."
    mkfs.ext4 -F -L "gLiTcH-Linux" "$ROOT_PARTITION" || show_error "Failed to format root partition"
    
    # Mount partitions
    update_progress 35 "Mounting partitions..."
    mkdir -p /mnt || show_error "Failed to create mount point"
    mount "$ROOT_PARTITION" /mnt || show_error "Failed to mount root partition"
    mkdir -p /mnt/boot/efi || show_error "Failed to create EFI directory"
    mount "$EFI_PARTITION" /mnt/boot/efi || show_error "Failed to mount EFI partition"
    
    # Find squashfs file
    update_progress 40 "Locating system image..."
    SQUASHFS_PATHS=(
        "/run/live/medium/live/filesystem.squashfs"
        "/cdrom/live/filesystem.squashfs"
        "/run/initramfs/live/filesystem.squashfs"
        "/lib/live/mount/medium/live/filesystem.squashfs"
        "$(find /run -name filesystem.squashfs 2>/dev/null | head -1)"
        "$(find /cdrom -name filesystem.squashfs 2>/dev/null | head -1)"
        "$(find /media -name filesystem.squashfs 2>/dev/null | head -1)"
    )
    
    SQUASHFS_PATH=""
    for path in "${SQUASHFS_PATHS[@]}"; do
        if [ -f "$path" ]; then
            SQUASHFS_PATH="$path"
            echo "Found squashfs at: $SQUASHFS_PATH"
            break
        fi
    done
    
    if [ -z "$SQUASHFS_PATH" ] || [ ! -f "$SQUASHFS_PATH" ]; then
        show_error "Could not find filesystem.squashfs. Installation cannot continue."
    fi
    
    # Extract system files with progress
    update_progress 45 "Preparing to extract system files..."
    
    # Create a separate script to show unsquashfs progress
    PROGRESS_SCRIPT=$(mktemp)
    cat > "$PROGRESS_SCRIPT" << 'EOF'
#!/bin/bash
SQUASHFS_PATH="$1"
MOUNT_POINT="$2"
PROGRESS_FILE="$3"

# Get total number of files in squashfs
echo "Counting files in squashfs image..." > "$PROGRESS_FILE"
TOTAL_FILES=$(unsquashfs -l "$SQUASHFS_PATH" | grep -E '^[^0-9]+[0-9]+' | wc -l)
echo "Total files to extract: $TOTAL_FILES" >> "$PROGRESS_FILE"

# Run unsquashfs with pv if available
if command -v pv &>/dev/null && command -v stdbuf &>/dev/null; then
    # Advanced progress monitoring
    unsquashfs -f -d "$MOUNT_POINT" "$SQUASHFS_PATH" 2>&1 | 
        stdbuf -oL grep -E '^(created|extracted)' | 
        stdbuf -oL awk -v total="$TOTAL_FILES" '{
            count++; 
            if (count % 100 == 0 || $0 ~ /created directory/) {
                percent = int((count / total) * 100);
                if (percent > 100) percent = 100;
                if (percent < 45) percent = 45 + int(percent / 2);
                print percent > "'"$PROGRESS_FILE"'";
                print "Extracting: " count " of " total " files (" percent "%)..." >> "'"$PROGRESS_FILE"'";
            }
        }'
else
    # Basic extraction without detailed progress
    unsquashfs -f -d "$MOUNT_POINT" "$SQUASHFS_PATH" | 
        grep -E '^(created|extracted)' | 
        awk -v total="$TOTAL_FILES" '{
            count++; 
            if (count % 100 == 0) {
                percent = int((count / total) * 100);
                if (percent > 100) percent = 100;
                if (percent < 45) percent = 45 + int(percent / 2);
                print percent > "'"$PROGRESS_FILE"'";
                print "Extracting: " count " of " total " files (" percent "%)..." >> "'"$PROGRESS_FILE"'";
            }
        }'
fi

# Ensure we show 100% when done
echo "100" > "$PROGRESS_FILE"
echo "Extraction complete!" >> "$PROGRESS_FILE"
EOF

    chmod +x "$PROGRESS_SCRIPT"
    
    # Create a temp file for progress communication
    PROGRESS_FILE=$(mktemp)
    
    # Start the extraction process in background
    update_progress 45 "Starting system extraction (this will take some time)..."
    "$PROGRESS_SCRIPT" "$SQUASHFS_PATH" "/mnt" "$PROGRESS_FILE" &
    EXTRACT_PID=$!
    
    # Monitor the progress file and update zenity progress
    while kill -0 $EXTRACT_PID 2>/dev/null; do
        if [ -f "$PROGRESS_FILE" ]; then
            PERCENT=$(head -n 1 "$PROGRESS_FILE")
            MESSAGE=$(tail -n 1 "$PROGRESS_FILE")
            
            # Only update if we have valid data
            if [[ "$PERCENT" =~ ^[0-9]+$ ]]; then
                update_progress "$PERCENT" "$MESSAGE"
            else
                update_progress 50 "Extracting system files..."
            fi
        else
            update_progress 50 "Extracting system files..."
        fi
        sleep 1
    done
    
    # Check if extraction was successful
    wait $EXTRACT_PID
    if [ $? -ne 0 ]; then
        show_error "Failed to extract system files"
    fi
    
    update_progress 80 "Setting up chroot environment..."
    mount --bind /dev /mnt/dev || show_error "Failed to bind /dev"
    mount --bind /proc /mnt/proc || show_error "Failed to bind /proc"
    mount --bind /sys /mnt/sys || show_error "Failed to bind /sys"
    
    # Update initramfs
    update_progress 85 "Updating initramfs..."
    chroot /mnt /bin/bash -c "update-initramfs -u -k all" || show_error "Failed to update initramfs"
    
    # Install GRUB
    update_progress 90 "Installing GRUB bootloader..."
    chroot /mnt /bin/bash -c "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Debian" || show_error "Failed to install GRUB"
    
    # Update GRUB
    update_progress 93 "Updating GRUB configuration..."
    chroot /mnt /bin/bash -c "update-grub" || show_error "Failed to update GRUB configuration"
    
    # Clean up
    update_progress 97 "Cleaning up..."
    umount /mnt/sys || echo "Warning: Failed to unmount /mnt/sys"
    umount /mnt/proc || echo "Warning: Failed to unmount /mnt/proc"
    umount /mnt/dev || echo "Warning: Failed to unmount /mnt/dev"
    umount /mnt/boot/efi || echo "Warning: Failed to unmount /mnt/boot/efi"
    umount /mnt || echo "Warning: Failed to unmount /mnt"
    
    # Remove temporary files
    rm -f "$PROGRESS_FILE" "$PROGRESS_SCRIPT" "$TEMP_DISKS_FILE" "$DISK_OPTIONS_FILE"
    
    update_progress 100 "Installation complete!"
} | zenity --progress --title="Installing gLiTcH Linux" --text="Preparing for installation..." --percentage=0 --auto-close --auto-kill --width=450

# Check if installation completed successfully
if [ $? -ne 0 ]; then
    show_error "Installation was interrupted or failed. Check the log file for details."
fi

# Show completion message
zenity --info --title="Installation Complete" --text="gLiTcH Linux has been successfully installed on $SELECTED_DISK.\n\nYou can now reboot your system.\n\nA log file was saved to: $LOG_FILE" --width=400

exit 0
