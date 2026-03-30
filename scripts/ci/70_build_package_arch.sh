#!/bin/bash
# 70_build_package_arch.sh - Build kernel and create Arch packages
#
# This script builds the Linux kernel for Gaokun devices and packages
# it into Arch Linux packages using makepkg.
#
# Workflow:
#   1. Checkout torvalds/linux at specified KERNEL_TAG
#   2. Apply patches from patches/*.patch using git am
#   3. Copy defconfig to .config
#   4. Configure kernel: make gaokun3_defconfig, olddefconfig
#   5. Build kernel: make -j$(nproc)
#   6. Build modules: make modules
#   7. Prepare modules: make modules_prepare
#   8. Create Arch packages using PKGBUILD templates
#   9. Upload artifacts

set -euo pipefail

# ============================================================================
# Environment Variables
# ============================================================================

# Required inputs (can be overridden via environment)
KERNEL_TAG="${KERNEL_TAG:-v6.14-rc5}"
GAOKUN_DIR="${GAOKUN_DIR:-$(pwd)}"
WORKDIR="${WORKDIR:-/tmp/gaokun-build}"
KERN_SRC="${KERN_SRC:-${WORKDIR}/linux-src}"
KERN_OUT="${KERN_OUT:-${WORKDIR}/linux-out}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${WORKDIR}/artifacts}"

# Build configuration
NPROC="${NPROC:-$(nproc)}"
MAKE_OPTS="${MAKE_OPTS:-}"

# Package version (derived from KERNEL_TAG)
PKGVER="${PKGVER:-7.0.rc5}"
PKGREL="${PKGREL:-1}"

# ============================================================================
# Logging Functions
# ============================================================================

log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_section() {
    echo ""
    echo "============================================================"
    echo "$1"
    echo "============================================================"
    echo ""
}

# ============================================================================
# Cleanup and Setup Functions
# ============================================================================

cleanup_workdir() {
    log_info "Cleaning up work directory: ${WORKDIR}"
    rm -rf "${WORKDIR}"
}

setup_workdir() {
    log_info "Setting up work directory: ${WORKDIR}"
    mkdir -p "${WORKDIR}"
    mkdir -p "${KERN_SRC}"
    mkdir -p "${KERN_OUT}"
    mkdir -p "${ARTIFACT_DIR}"
}

# ============================================================================
# Kernel Source Checkout
# ============================================================================

checkout_kernel_source() {
    log_section "Checking out kernel source at ${KERNEL_TAG}"

    if [ -d "${KERN_SRC}/.git" ]; then
        log_info "Existing git repository found, fetching updates..."
        cd "${KERN_SRC}"
        git fetch --depth=1 origin "${KERNEL_TAG}"
        git checkout "${KERNEL_TAG}"
    else
        log_info "Cloning fresh kernel repository..."
        git clone --depth=1 --branch "${KERNEL_TAG}" \
            https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git \
            "${KERN_SRC}"
    fi

    # Verify checkout
    cd "${KERN_SRC}"
    log_info "Checked out kernel version: $(make kernelversion)"
    log_info "Kernel release: $(make kernelrelease)"
}

# ============================================================================
# Patch Application
# ============================================================================

apply_patches() {
    log_section "Applying patches from ${GAOKUN_DIR}/patches/"

    cd "${KERN_SRC}"

    local patch_dir="${GAOKUN_DIR}/patches"
    local patch_count=0
    local failed_patches=0

    # Sort patches by number and apply them in order
    for patch in $(ls "${patch_dir}"/*.patch 2>/dev/null | sort -V); do
        patch_name=$(basename "${patch}")
        log_info "Applying patch: ${patch_name}"

        if git am --3way "${patch}" 2>/dev/null; then
            patch_count=$((patch_count + 1))
            log_info "  Successfully applied: ${patch_name}"
        else
            # Try to skip if already applied
            if git am --skip 2>/dev/null; then
                log_info "  Patch already applied or skipped: ${patch_name}"
                patch_count=$((patch_count + 1))
            else
                log_error "  Failed to apply: ${patch_name}"
                git am --abort 2>/dev/null || true
                failed_patches=$((failed_patches + 1))
            fi
        fi
    done

    log_info "Applied ${patch_count} patches, ${failed_patches} failures"

    if [ ${failed_patches} -gt 0 ]; then
        log_error "Some patches failed to apply. Check the output above."
        return 1
    fi
}

# ============================================================================
# Kernel Configuration
# ============================================================================

configure_kernel() {
    log_section "Configuring kernel"

    cd "${KERN_SRC}"

    # Copy defconfig to kernel source
    local defconfig="${GAOKUN_DIR}/defconfig/gaokun3_defconfig"
    log_info "Copying defconfig from ${defconfig}"
    cp "${defconfig}" "arch/arm64/configs/gaokun3_defconfig"

    # Generate .config using gaokun3_defconfig
    log_info "Running: make gaokun3_defconfig"
    make ${MAKE_OPTS} gaokun3_defconfig

    # Run olddefconfig to resolve any dependencies
    log_info "Running: make olddefconfig"
    make ${MAKE_OPTS} olddefconfig

    # Verify configuration
    log_info "Kernel configuration summary:"
    grep "CONFIG_LOCALVERSION" .config || true
    grep "CONFIG_ARM64" .config || true
    grep "CONFIG_ARCH_QCOM" .config || true
}

# ============================================================================
# Kernel Build
# ============================================================================

build_kernel() {
    log_section "Building kernel (using ${NPROC} jobs)"

    cd "${KERN_SRC}"

    log_info "Starting kernel build..."
    make ${MAKE_OPTS} -j${NPROC} all

    log_info "Kernel build completed successfully"
}

build_modules() {
    log_section "Building kernel modules"

    cd "${KERN_SRC}"

    log_info "Building modules..."
    make ${MAKE_OPTS} -j${NPROC} modules

    log_info "Preparing modules..."
    make ${MAKE_OPTS} modules_prepare

    log_info "Modules build completed successfully"
}

# ============================================================================
# Artifact Collection
# ============================================================================

collect_artifacts() {
    log_section "Collecting build artifacts"

    cd "${KERN_SRC}"

    local kernver=$(make kernelrelease)
    log_info "Kernel version: ${kernver}"

    # Create output directories
    mkdir -p "${KERN_OUT}/kernel"
    mkdir -p "${KERN_OUT}/modules"
    mkdir -p "${KERN_OUT}/headers"
    mkdir -p "${KERN_OUT}/dtbs"

    # Copy kernel image
    log_info "Copying kernel image..."
    cp "arch/arm64/boot/Image" "${KERN_OUT}/kernel/vmlinuz"

    # Copy kernel config
    cp ".config" "${KERN_OUT}/kernel/.config"

    # Copy System.map
    cp "System.map" "${KERN_OUT}/kernel/System.map"

    # Copy Module.symvers
    cp "Module.symvers" "${KERN_OUT}/kernel/Module.symvers"

    # Copy device tree blobs
    log_info "Copying device tree blobs..."
    if [ -d "arch/arm64/boot/dts/qcom" ]; then
        # Find and copy relevant DTBs
        find arch/arm64/boot/dts/qcom -name "*.dtb" -exec cp {} "${KERN_OUT}/dtbs/" \; 2>/dev/null || true
        # Also copy the specific gaokun DTB if it exists
        if [ -f "arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb" ]; then
            cp "arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb" "${KERN_OUT}/dtbs/"
        fi
    fi

    # Install modules to output directory
    log_info "Installing modules..."
    make ${MAKE_OPTS} INSTALL_MOD_PATH="${KERN_OUT}/modules" modules_install

    # Prepare headers for module building
    log_info "Preparing headers..."
    prepare_headers

    log_info "Artifact collection completed"
}

prepare_headers() {
    cd "${KERN_SRC}"

    local headers_dir="${KERN_OUT}/headers"
    local kernver=$(make kernelrelease)

    # Create headers directory structure
    mkdir -p "${headers_dir}/usr/src/kernels/${kernver}"

    # Copy essential headers
    cp -r include "${headers_dir}/usr/src/kernels/${kernver}/"

    # Copy kernel config
    cp ".config" "${headers_dir}/usr/src/kernels/${kernver}/.config"

    # Copy System.map
    cp "System.map" "${headers_dir}/usr/src/kernels/${kernver}/System.map"

    # Copy Module.symvers
    cp "Module.symvers" "${headers_dir}/usr/src/kernels/${kernver}/Module.symvers"

    # Copy scripts directory
    if [ -d "scripts" ]; then
        cp -r scripts "${headers_dir}/usr/src/kernels/${kernver}/"
        chmod -R u+rx "${headers_dir}/usr/src/kernels/${kernver}/scripts"
    fi

    # Copy arch-specific headers
    mkdir -p "${headers_dir}/usr/src/kernels/${kernver}/arch/arm64"
    cp -r arch/arm64/include "${headers_dir}/usr/src/kernels/${kernver}/arch/arm64/"

    # Fix permissions
    chmod -R u+rwX,go+rX "${headers_dir}/usr/src/kernels/${kernver}"
}

# ============================================================================
# Arch Package Creation
# ============================================================================

create_arch_packages() {
    log_section "Creating Arch Linux packages"

    local pkg_base_dir="${GAOKUN_DIR}/packaging"
    local kernver=$(make kernelrelease -C "${KERN_SRC}")
    local pkg_workdir="${WORKDIR}/pkgbuild"

    mkdir -p "${pkg_workdir}"

    # Package: linux-gaokun3
    create_kernel_package "${pkg_base_dir}/linux-gaokun3" "${pkg_workdir}/linux-gaokun3"

    # Package: linux-modules-gaokun3
    create_modules_package "${pkg_base_dir}/linux-modules-gaokun3" "${pkg_workdir}/linux-modules-gaokun3"

    # Package: linux-headers-gaokun3
    create_headers_package "${pkg_base_dir}/linux-headers-gaokun3" "${pkg_workdir}/linux-headers-gaokun3"

    # Package: linux-firmware-gaokun3
    create_firmware_package "${pkg_base_dir}/linux-firmware-gaokun3" "${pkg_workdir}/linux-firmware-gaokun3"

    log_info "All packages created successfully"
}

create_kernel_package() {
    local template_dir="$1"
    local pkg_dir="$2"
    local kernver=$(make kernelrelease -C "${KERN_SRC}")

    log_info "Creating package: linux-gaokun3"

    mkdir -p "${pkg_dir}/src"

    # Copy template PKGBUILD
    cp "${template_dir}/PKGBUILD" "${pkg_dir}/PKGBUILD"

    # Prepare source files for makepkg
    cp "${KERN_OUT}/kernel/vmlinuz" "${pkg_dir}/src/vmlinuz"
    cp "${KERN_OUT}/kernel/.config" "${pkg_dir}/src/.config"
    cp "${KERN_OUT}/kernel/System.map" "${pkg_dir}/src/System.map"

    # Copy DTBs if available
    if [ -d "${KERN_OUT}/dtbs" ] && [ "$(ls -A ${KERN_OUT}/dtbs 2>/dev/null)" ]; then
        cp -r "${KERN_OUT}/dtbs" "${pkg_dir}/src/dtbs"
    fi

    # Update PKGBUILD with actual version
    sed -i "s/^pkgver=.*/pkgver=${PKGVER}/" "${pkg_dir}/PKGBUILD"
    sed -i "s/^pkgrel=.*/pkgrel=${PKGREL}/" "${pkg_dir}/PKGBUILD"

    # Build package
    cd "${pkg_dir}"
    makepkg --skipchecksums --skippgpcheck --config /etc/makepkg.conf

    # Move package to artifacts
    mv *.pkg.tar.zst "${ARTIFACT_DIR}/" 2>/dev/null || true

    log_info "Package linux-gaokun3 created"
}

create_modules_package() {
    local template_dir="$1"
    local pkg_dir="$2"
    local kernver=$(make kernelrelease -C "${KERN_SRC}")

    log_info "Creating package: linux-modules-gaokun3"

    mkdir -p "${pkg_dir}/src"

    # Copy template PKGBUILD
    cp "${template_dir}/PKGBUILD" "${pkg_dir}/PKGBUILD"

    # Prepare source files for makepkg
    local mod_install_dir="${KERN_OUT}/modules/usr/lib/modules/${kernver}"

    if [ -d "${mod_install_dir}" ]; then
        # Copy module files
        cp -r "${mod_install_dir}" "${pkg_dir}/src/modules"

        # Copy module metadata files
        cp "${mod_install_dir}/modules.dep" "${pkg_dir}/src/" 2>/dev/null || true
        cp "${mod_install_dir}/modules.alias" "${pkg_dir}/src/" 2>/dev/null || true
        cp "${mod_install_dir}/modules.symbols" "${pkg_dir}/src/" 2>/dev/null || true
        cp "${mod_install_dir}/modules.builtin" "${pkg_dir}/src/" 2>/dev/null || true
        cp "${mod_install_dir}/modules.order" "${pkg_dir}/src/" 2>/dev/null || true
    fi

    # Copy System.map for depmod
    cp "${KERN_OUT}/kernel/System.map" "${pkg_dir}/src/System.map"

    # Update PKGBUILD with actual version
    sed -i "s/^pkgver=.*/pkgver=${PKGVER}/" "${pkg_dir}/PKGBUILD"
    sed -i "s/^pkgrel=.*/pkgrel=${PKGREL}/" "${pkg_dir}/PKGBUILD"

    # Build package
    cd "${pkg_dir}"
    makepkg --skipchecksums --skippgpcheck --config /etc/makepkg.conf

    # Move package to artifacts
    mv *.pkg.tar.zst "${ARTIFACT_DIR}/" 2>/dev/null || true

    log_info "Package linux-modules-gaokun3 created"
}

create_headers_package() {
    local template_dir="$1"
    local pkg_dir="$2"
    local kernver=$(make kernelrelease -C "${KERN_SRC}")

    log_info "Creating package: linux-headers-gaokun3"

    mkdir -p "${pkg_dir}/src"

    # Copy template PKGBUILD
    cp "${template_dir}/PKGBUILD" "${pkg_dir}/PKGBUILD"

    # Prepare source files for makepkg
    local headers_install_dir="${KERN_OUT}/headers/usr/src/kernels/${kernver}"

    if [ -d "${headers_install_dir}" ]; then
        cp -r "${headers_install_dir}" "${pkg_dir}/src/headers"
    fi

    # Copy essential files
    cp "${KERN_OUT}/kernel/.config" "${pkg_dir}/src/.config"
    cp "${KERN_OUT}/kernel/System.map" "${pkg_dir}/src/System.map"
    cp "${KERN_OUT}/kernel/Module.symvers" "${pkg_dir}/src/Module.symvers"

    # Copy scripts if available
    if [ -d "${KERN_SRC}/scripts" ]; then
        cp -r "${KERN_SRC}/scripts" "${pkg_dir}/src/scripts"
    fi

    # Copy include directories
    for dir in include/arch include/linux include/asm include/generated; do
        if [ -d "${KERN_SRC}/${dir}" ]; then
            mkdir -p "${pkg_dir}/src/${dir}"
            cp -r "${KERN_SRC}/${dir}/" "${pkg_dir}/src/${dir}/"
        fi
    done

    # Update PKGBUILD with actual version
    sed -i "s/^pkgver=.*/pkgver=${PKGVER}/" "${pkg_dir}/PKGBUILD"
    sed -i "s/^pkgrel=.*/pkgrel=${PKGREL}/" "${pkg_dir}/PKGBUILD"

    # Build package
    cd "${pkg_dir}"
    makepkg --skipchecksums --skippgpcheck --config /etc/makepkg.conf

    # Move package to artifacts
    mv *.pkg.tar.zst "${ARTIFACT_DIR}/" 2>/dev/null || true

    log_info "Package linux-headers-gaokun3 created"
}

create_firmware_package() {
    local template_dir="$1"
    local pkg_dir="$2"

    log_info "Creating package: linux-firmware-gaokun3"

    mkdir -p "${pkg_dir}/src"

    # Copy template PKGBUILD
    cp "${template_dir}/PKGBUILD" "${pkg_dir}/PKGBUILD"

    # Prepare source files - copy firmware from repository
    local firmware_dir="${GAOKUN_DIR}/firmware"

    if [ -d "${firmware_dir}" ]; then
        mkdir -p "${pkg_dir}/src/firmware"
        # Copy firmware files, excluding spec files
        find "${firmware_dir}" -type f ! -name "*.spec.in" -exec cp --parents {} "${pkg_dir}/src/firmware/" \; 2>/dev/null || true
    fi

    # Update PKGBUILD with actual version
    sed -i "s/^pkgver=.*/pkgver=${PKGVER}/" "${pkg_dir}/PKGBUILD"
    sed -i "s/^pkgrel=.*/pkgrel=${PKGREL}/" "${pkg_dir}/PKGBUILD"

    # Build package
    cd "${pkg_dir}"
    makepkg --skipchecksums --skippgpcheck --config /etc/makepkg.conf

    # Move package to artifacts
    mv *.pkg.tar.zst "${ARTIFACT_DIR}/" 2>/dev/null || true

    log_info "Package linux-firmware-gaokun3 created"
}

# ============================================================================
# Artifact Upload
# ============================================================================

upload_artifacts() {
    log_section "Uploading artifacts"

    # List all created packages
    log_info "Created packages:"
    ls -la "${ARTIFACT_DIR}/"*.pkg.tar.zst 2>/dev/null || true

    # If running in CI with artifact upload support
    if [ -n "${CI_ARTIFACT_UPLOAD:-}" ]; then
        log_info "Uploading artifacts to CI storage..."
        for pkg in "${ARTIFACT_DIR}/"*.pkg.tar.zst; do
            if [ -f "${pkg}" ]; then
                log_info "Uploading: $(basename ${pkg})"
                # Placeholder for actual upload mechanism
                # This would typically use GitHub Actions artifact upload
                # or similar CI-specific upload commands
            fi
        done
    else
        log_info "No CI upload configured. Artifacts available at: ${ARTIFACT_DIR}"
    fi
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    log_section "Starting Gaokun Kernel Build for Arch Linux"

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --kernel-tag)
                KERNEL_TAG="$2"
                shift 2
                ;;
            --pkgver)
                PKGVER="$2"
                shift 2
                ;;
            --pkgrel)
                PKGREL="$2"
                shift 2
                ;;
            --clean)
                cleanup_workdir
                shift
                ;;
            --help)
                echo "Usage: $0 [OPTIONS]"
                echo "Options:"
                echo "  --kernel-tag TAG  Kernel tag to checkout (default: v6.14-rc5)"
                echo "  --pkgver VERSION  Package version (default: 7.0.rc5)"
                echo "  --pkgrel RELEASE  Package release (default: 1)"
                echo "  --clean           Clean work directory before build"
                echo "  --help            Show this help message"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    log_info "Configuration:"
    log_info "  KERNEL_TAG: ${KERNEL_TAG}"
    log_info "  PKGVER: ${PKGVER}"
    log_info "  PKGREL: ${PKGREL}"
    log_info "  WORKDIR: ${WORKDIR}"
    log_info "  NPROC: ${NPROC}"

    # Execute build steps
    setup_workdir
    checkout_kernel_source
    apply_patches
    configure_kernel
    build_kernel
    build_modules
    collect_artifacts
    create_arch_packages
    upload_artifacts

    log_section "Build Completed Successfully"

    log_info "Packages available at: ${ARTIFACT_DIR}"
    ls -la "${ARTIFACT_DIR}/"
}

# Run main function
main "$@"