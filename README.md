# Arch Linux Build Workflow for Huawei MateBook E Go

CI-built Linux kernel images using buildbot patches for the Huawei MateBook E Go (MS-7D73) platform.

## Description

This repository provides automated build infrastructure for Arch Linux kernel images tailored for the Huawei MateBook E Go. It uses patches from the [linux-gaokun-buildbot](https://github.com/KawaiiHachimi/linux-gaokun-buildbot) project to enable full hardware support including display, touch, keyboard, and power management.

**This uses buildbot patches for Arch Linux builds.**

## What is Included

- `patches/` - Kernel patches from buildbot source
- `defconfig/` - Optimized kernel configuration files
- `dts/` - Device tree sources for hardware support
- `firmware/` - Required firmware blobs
- `packaging/` - PKGBUILD templates for Arch package creation
- `scripts/ci/` - CI/CD workflows for automated builds
- `tools/` - Helper scripts for development and testing

## Build Instructions

### Prerequisites

- Arch Linux development environment
- `base-devel` package group installed
- Git and standard build tools

### Building the Kernel

```bash
# Clone the repository
git clone https://github.com/KawaiiHachimi/arch-gaokun-build.git
cd arch-gaokun-build

# Run the build script
./scripts/ci/build.sh

# Or build manually using the packaging scripts
cd packaging
makepkg -si
```

### Using the PKGBUILD

```bash
cd packaging
makepkg -sf
sudo pacman -U linux-gaokun-*.pkg.tar.zst
```

## Usage Guide

### USB Boot

1. Build the kernel package using the instructions above
2. Install to a USB drive:
   ```bash
   sudo pacman -U linux-gaokun-*.pkg.tar.zst --root /mnt/usb
   ```
3. Configure bootloader (systemd-boot or GRUB) on the USB drive
4. Boot from USB and select the linux-gaokun entry

### Installation

After booting from USB, install to internal storage:

```bash
# Mount target partitions
mount /dev/nvme0n1pX /mnt

# Install the kernel package
pacman -r /mnt -U linux-gaokun-*.pkg.tar.zst

# Install bootloader
bootctl install --path /mnt/boot
```

## References

- **buildbot**: https://github.com/KawaiiHachimi/linux-gaokun-buildbot
- **AUR linux-gaokun3**: https://aur.archlinux.org/packages/linux-gaokun3
- **Original gaokun repo**: https://github.com/right-0903/linux-gaokun

## License

This project follows the licensing of its upstream sources.
