#!/bin/bash
# Arch Linux Release Packaging Script
# Compresses image and creates release artifacts

set -euo pipefail

#######################################
# Configuration
#######################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Build configuration
IMAGE_NAME="${IMAGE_NAME:-arch-gaokun}"
BUILD_DIR="${BUILD_DIR:-${PROJECT_ROOT}/build}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/output}"
RELEASE_DIR="${RELEASE_DIR:-${PROJECT_ROOT}/release}"

# Compression settings
COMPRESSOR="${COMPRESSOR:-zstd}"
COMPRESS_LEVEL="${COMPRESS_LEVEL:-19}"
COMPRESS_THREADS="${COMPRESS_THREADS:-$(nproc)}"

# Version info
VERSION="${VERSION:-$(date +%Y%m%d)}"
BUILD_DATE="${BUILD_DATE:-$(date +%Y-%m-%d)}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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

check_dependencies() {
    local deps=("zstd" "sha256sum" "sha512sum" "gpg")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        log_info "Install with: pacman -S zstd coreutils gnupg"
        exit 1
    fi
}

#######################################
# Packaging Functions
#######################################
prepare_release_directory() {
    log_info "Preparing release directory..."
    
    mkdir -p "${RELEASE_DIR}"
    mkdir -p "${RELEASE_DIR}/${VERSION}"
    
    log_info "Release directory: ${RELEASE_DIR}/${VERSION}"
}

compress_image() {
    log_info "Compressing image with zstd..."
    
    local input_image="${OUTPUT_DIR}/${IMAGE_NAME}.img"
    local output_image="${RELEASE_DIR}/${VERSION}/${IMAGE_NAME}-${VERSION}.img.zst"
    
    if [[ ! -f "${input_image}" ]]; then
        log_error "Image not found: ${input_image}"
        exit 1
    fi
    
    local original_size
    original_size=$(stat -c %s "${input_image}")
    log_info "Original size: $((original_size / 1024 / 1024 / 1024)) GB"
    
    zstd -T"${COMPRESS_THREADS}" -"${COMPRESS_LEVEL}" \
        -f "${input_image}" \
        -o "${output_image}"
    
    local compressed_size
    compressed_size=$(stat -c %s "${output_image}")
    local ratio
    ratio=$(echo "scale=2; ${original_size} / ${compressed_size}" | bc)
    
    log_info "Compressed size: $((compressed_size / 1024 / 1024)) MB"
    log_info "Compression ratio: ${ratio}x"
    
    echo "${output_image}"
}

generate_checksums() {
    local release_file="$1"
    local release_dir
    release_dir=$(dirname "${release_file}")
    local filename
    filename=$(basename "${release_file}")
    
    log_info "Generating checksums..."
    
    pushd "${release_dir}" >/dev/null
    
    # SHA256
    sha256sum "${filename}" > "${filename}.sha256"
    log_info "SHA256: $(cat "${filename}.sha256")"
    
    # SHA512
    sha512sum "${filename}" > "${filename}.sha512"
    log_info "SHA512 generated"
    
    # BLAKE2b if available
    if command -v b2sum &>/dev/null; then
        b2sum "${filename}" > "${filename}.b2sum"
        log_info "BLAKE2b generated"
    fi
    
    popd >/dev/null
    
    log_info "Checksums generated"
}

sign_release() {
    local release_file="$1"
    
    if [[ -z "${GPG_KEY_ID:-}" ]]; then
        log_warn "GPG_KEY_ID not set, skipping signing"
        return 0
    fi
    
    log_info "Signing release with GPG..."
    
    gpg --batch --yes \
        --local-user "${GPG_KEY_ID}" \
        --armor \
        --detach-sign "${release_file}"
    
    log_info "Signature created: ${release_file}.asc"
}

create_release_notes() {
    local release_dir="$1"
    local release_file="$2"
    local notes_file="${release_dir}/RELEASE_NOTES.md"
    
    log_info "Creating release notes..."
    
    local file_size
    file_size=$(stat -c %s "${release_file}")
    local file_size_mb=$((file_size / 1024 / 1024))
    
    local checksum_sha256
    checksum_sha256=$(sha256sum "${release_file}" | cut -d' ' -f1)
    
    cat > "${notes_file}" << EOF
# Arch Linux Gaokun Release ${VERSION}

## Release Information

- **Version**: ${VERSION}
- **Build Date**: ${BUILD_DATE}
- **Image Name**: ${IMAGE_NAME}

## System Requirements

- UEFI-capable system
- Minimum 16GB RAM recommended
- 12GB+ storage for installation

## Included Software

### Desktop Environment
- GNOME desktop with extra applications
- GDM display manager

### Kernels
- linux (latest stable)
- linux-lts (long-term support)
- linux-hardened (security-focused)

### Input Method
- fcitx5 with Chinese addons
- GTK and Qt integration

### Graphics
- Mesa with Vulkan support
- AMD microcode

### Multimedia
- Firefox web browser
- MPV media player
- V4L utilities

### System Tools
- git, vim, nano
- htop, fastfetch, screen
- NetworkManager
- PipeWire audio system

## File Information

| Property | Value |
|----------|-------|
| Filename | $(basename "${release_file}") |
| Size | ${file_size_mb} MB |
| SHA256 | \`${checksum_sha256}\` |

## Installation

1. Write the image to disk:
   \`\`\`bash
   zstd -d ${IMAGE_NAME}-${VERSION}.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
   \`\`\`

2. Boot from the disk and login with:
   - Username: \`user\`
   - Password: \`user\`

3. Change passwords immediately after first login.

## Verification

Verify the download with checksums:
\`\`\`bash
sha256sum -c ${IMAGE_NAME}-${VERSION}.img.zst.sha256
\`\`\`

## Notes

- This is an unofficial Arch Linux distribution
- Default passwords should be changed immediately
- Update the system after installation: \`sudo pacman -Syu\`

---
Built on ${BUILD_DATE}
EOF
    
    log_info "Release notes created: ${notes_file}"
}

create_checksum_file() {
    local release_dir="$1"
    local checksum_file="${release_dir}/CHECKSUMS"
    
    log_info "Creating combined checksum file..."
    
    pushd "${release_dir}" >/dev/null
    
    {
        echo "# Checksums for Arch Linux Gaokun ${VERSION}"
        echo "# Generated: $(date -Iseconds)"
        echo ""
        
        for f in *.img.zst; do
            [[ -f "$f" ]] || continue
            echo "SHA256 (${f}) = $(sha256sum "$f" | cut -d' ' -f1)"
            echo "SHA512 (${f}) = $(sha512sum "$f" | cut -d' ' -f1)"
            echo ""
        done
    } > "${checksum_file}"
    
    popd >/dev/null
    
    log_info "Combined checksums: ${checksum_file}"
}

#######################################
# Main
#######################################
main() {
    log_info "========================================="
    log_info "Arch Linux Release Packaging"
    log_info "========================================="
    
    check_dependencies
    prepare_release_directory
    
    local compressed_image
    compressed_image=$(compress_image)
    
    generate_checksums "${compressed_image}"
    sign_release "${compressed_image}"
    create_release_notes "$(dirname "${compressed_image}")" "${compressed_image}"
    create_checksum_file "$(dirname "${compressed_image}")"
    
    log_info "========================================="
    log_info "Packaging complete!"
    log_info "Release directory: ${RELEASE_DIR}/${VERSION}"
    log_info "========================================="
}

main "$@"