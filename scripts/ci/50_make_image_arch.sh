#!/bin/bash
# Arch Linux Image Build Script
# Creates a bootable Arch Linux disk image with GNOME desktop

set -euo pipefail

#######################################
# Configuration
#######################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Image configuration
IMAGE_NAME="${IMAGE_NAME:-arch-gaokun}"
IMAGE_SIZE="${IMAGE_SIZE:-12G}"
EFI_SIZE="${EFI_SIZE:-512M}"

# Partition sizes
EFI_PART_SIZE="512MiB"

# Build artifacts
BUILD_DIR="${BUILD_DIR:-${PROJECT_ROOT}/build}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/output}"

# System configuration
HOSTNAME="${HOSTNAME:-arch-gaokun}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"

# User configuration
USERNAME="${USERNAME:-user}"
USER_PASSWORD="${USER_PASSWORD:-user}"
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#######################################
# Helper Functions
#######################################
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup() {
    local exit_code=$?
    log_info "Cleaning up..."
    
    # Unmount if mounted
    if mountpoint -q "${MOUNT_ROOT:-/tmp/arch-build-root}" 2>/dev/null; then
        umount -R "${MOUNT_ROOT}" || true
    fi
    
    # Detach loop device if attached
    if [[ -n "${LOOP_DEVICE:-}" ]] && [[ -e "${LOOP_DEVICE}" ]]; then
        losetup -d "${LOOP_DEVICE}" || true
    fi
    
    exit $exit_code
}

trap cleanup EXIT

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_dependencies() {
    local deps=("parted" "pacstrap" "grub-install" "mkinitcpio" "losetup" "mkfs.vfat" "mkfs.ext4" "arch-chroot")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        log_info "Install with: pacman -S parted arch-install-scripts grub mkinitcpio dosfstools e2fsprogs"
        exit 1
    fi
}

#######################################
# Image Creation Functions
#######################################
create_disk_image() {
    log_info "Creating disk image: ${IMAGE_NAME}.img (${IMAGE_SIZE})"
    
    mkdir -p "${BUILD_DIR}"
    mkdir -p "${OUTPUT_DIR}"
    
    local image_path="${BUILD_DIR}/${IMAGE_NAME}.img"
    
    # Create sparse file
    truncate -s "${IMAGE_SIZE}" "${image_path}"
    
    log_info "Disk image created: ${image_path}"
    echo "${image_path}"
}

partition_disk() {
    local image_path="$1"
    log_info "Partitioning disk image..."
    
    # Setup loop device
    LOOP_DEVICE=$(losetup --find --show --partscan "${image_path}")
    log_info "Loop device: ${LOOP_DEVICE}"
    
    # Create partition table (GPT)
    parted -s "${LOOP_DEVICE}" mklabel gpt
    
    # Create EFI System Partition (512MiB)
    parted -s "${LOOP_DEVICE}" mkpart ESP fat32 1MiB "${EFI_PART_SIZE}"
    parted -s "${LOOP_DEVICE}" set 1 esp on
    
    # Create Linux root partition (rest of disk)
    parted -s "${LOOP_DEVICE}" mkpart rootfs ext4 "${EFI_PART_SIZE}" 100%
    
    # Inform kernel of partition changes
    partprobe "${LOOP_DEVICE}"
    sleep 2
    
    log_info "Partitioning complete"
    echo "${LOOP_DEVICE}"
}

format_partitions() {
    local loop_device="$1"
    log_info "Formatting partitions..."
    
    local efi_part="${loop_device}p1"
    local root_part="${loop_device}p2"
    
    # Wait for partition devices to appear
    local max_wait=30
    local waited=0
    while [[ ! -e "${efi_part}" ]] && [[ $waited -lt $max_wait ]]; do
        sleep 1
        ((waited++))
    done
    
    if [[ ! -e "${efi_part}" ]]; then
        log_error "EFI partition device not found: ${efi_part}"
        exit 1
    fi
    
    # Format EFI partition (FAT32)
    mkfs.vfat -F32 -n "EFI" "${efi_part}"
    
    # Format root partition (ext4)
    mkfs.ext4 -L "ROOT" -F "${root_part}"
    
    log_info "Formatting complete"
}

mount_partitions() {
    local loop_device="$1"
    log_info "Mounting partitions..."
    
    local efi_part="${loop_device}p1"
    local root_part="${loop_device}p2"
    
    MOUNT_ROOT="${BUILD_DIR}/root"
    
    mkdir -p "${MOUNT_ROOT}"
    mkdir -p "${MOUNT_ROOT}/boot"
    
    # Mount root partition
    mount "${root_part}" "${MOUNT_ROOT}"
    
    # Mount EFI partition
    mount "${efi_part}" "${MOUNT_ROOT}/boot"
    
    log_info "Partitions mounted at ${MOUNT_ROOT}"
}

install_base_system() {
    log_info "Installing base system with pacstrap..."
    
    # Base packages
    local base_packages=(
        base
        base-devel
        linux
        linux-headers
        linux-firmware
    )
    
    pacstrap -K "${MOUNT_ROOT}" "${base_packages[@]}"
    
    log_info "Base system installed"
}

install_kernel_packages() {
    log_info "Installing kernel packages..."
    
    local kernel_packages=(
        linux-lts
        linux-lts-headers
        linux-hardened
        linux-hardened-headers
    )
    
    pacstrap "${MOUNT_ROOT}" "${kernel_packages[@]}"
    
    log_info "Kernel packages installed (4 packages)"
}

install_desktop_environment() {
    log_info "Installing GNOME desktop and applications..."
    
    local packages=(
        # GNOME desktop
        gnome
        gnome-extra
        gdm
        
        # Display and graphics
        xorg-server
        xorg-xinit
        mesa
        vulkan-radeon
        amd-ucode
        
        # Input method
        fcitx5
        fcitx5-chinese-addons
        fcitx5-gtk
        fcitx5-qt
        fcitx5-configtool
        
        # Network
        networkmanager
        network-manager-applet
        
        # Audio
        pipewire
        pipewire-pulse
        pipewire-alsa
        wireplumber
        
        # Tools
        git
        vim
        nano
        htop
        fastfetch
        screen
        firefox
        mpv
        v4l-utils
        
        # System utilities
        sudo
        openssh
        wget
        curl
        tar
        unzip
        rsync
    )
    
    pacstrap "${MOUNT_ROOT}" "${packages[@]}"
    
    log_info "Desktop environment and tools installed"
}

configure_system() {
    log_info "Configuring system..."
    
    # Generate fstab
    genfstab -U "${MOUNT_ROOT}" >> "${MOUNT_ROOT}/etc/fstab"
    
    # Set hostname
    echo "${HOSTNAME}" > "${MOUNT_ROOT}/etc/hostname"
    
    # Configure hosts
    cat > "${MOUNT_ROOT}/etc/hosts" << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF
    
    # Configure locale
    sed -i "s/^#${LOCALE}/${LOCALE}/" "${MOUNT_ROOT}/etc/locale.gen"
    arch-chroot "${MOUNT_ROOT}" locale-gen
    
    echo "LANG=${LOCALE}" > "${MOUNT_ROOT}/etc/locale.conf"
    echo "KEYMAP=${KEYMAP}" > "${MOUNT_ROOT}/etc/vconsole.conf"
    
    # Set timezone
    arch-chroot "${MOUNT_ROOT}" ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    arch-chroot "${MOUNT_ROOT}" hwclock --systohc
    
    # Configure sudo
    echo "%wheel ALL=(ALL) ALL" > "${MOUNT_ROOT}/etc/sudoers.d/wheel"
    
    # Create user
    arch-chroot "${MOUNT_ROOT}" useradd -m -G wheel -s /bin/bash "${USERNAME}"
    
    # Set passwords
    echo "root:${ROOT_PASSWORD}" | arch-chroot "${MOUNT_ROOT}" chpasswd
    echo "${USERNAME}:${USER_PASSWORD}" | arch-chroot "${MOUNT_ROOT}" chpasswd
    
    # Enable services
    arch-chroot "${MOUNT_ROOT}" systemctl enable gdm NetworkManager
    
    # Configure fcitx5 environment
    cat > "${MOUNT_ROOT}/etc/environment" << EOF
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
EOF
    
    log_info "System configuration complete"
}

install_bootloader() {
    log_info "Installing GRUB bootloader..."
    
    arch-chroot "${MOUNT_ROOT}" grub-install --target=arm64-efi \
        --efi-directory=/boot \
        --bootloader-id=ARCH \
        --removable
    
    log_info "GRUB installed"
}

generate_initramfs() {
    log_info "Generating initramfs with mkinitcpio..."
    
    # Ensure correct hooks in mkinitcpio.conf
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/' \
        "${MOUNT_ROOT}/etc/mkinitcpio.conf"
    
    arch-chroot "${MOUNT_ROOT}" mkinitcpio -P
    
    log_info "Initramfs generated"
}

configure_grub() {
    log_info "Configuring GRUB..."
    
    arch-chroot "${MOUNT_ROOT}" grub-mkconfig -o /boot/grub/grub.cfg
    
    log_info "GRUB configuration complete"
}

finalize_image() {
    log_info "Finalizing image..."
    
    # Clean pacman cache
    arch-chroot "${MOUNT_ROOT}" pacman -Scc --noconfirm || true
    
    # Clean journal
    arch-chroot "${MOUNT_ROOT}" journalctl --vacuum-time=1s || true
    
    # Sync and unmount
    sync
    
    # Unmount in reverse order
    umount "${MOUNT_ROOT}/boot"
    umount "${MOUNT_ROOT}"
    
    # Detach loop device
    losetup -d "${LOOP_DEVICE}"
    LOOP_DEVICE=""
    
    # Move to output directory
    mv "${BUILD_DIR}/${IMAGE_NAME}.img" "${OUTPUT_DIR}/${IMAGE_NAME}.img"
    
    log_info "Image finalized: ${OUTPUT_DIR}/${IMAGE_NAME}.img"
}

#######################################
# Main
#######################################
main() {
    log_info "========================================="
    log_info "Arch Linux Image Build Script"
    log_info "========================================="
    
    check_root
    check_dependencies
    
    local image_path
    image_path=$(create_disk_image)
    
    LOOP_DEVICE=$(partition_disk "${image_path}")
    format_partitions "${LOOP_DEVICE}"
    mount_partitions "${LOOP_DEVICE}"
    install_base_system
    install_kernel_packages
    install_desktop_environment
    configure_system
    install_bootloader
    generate_initramfs
    configure_grub
    finalize_image
    
    log_info "========================================="
    log_info "Build complete!"
    log_info "Image: ${OUTPUT_DIR}/${IMAGE_NAME}.img"
    log_info "========================================="
}

main "$@"