#!/bin/bash
#
# AMD rcraid Driver Manager for RHEL 9.x and 10.x
# Handles patching, building, signing, DKMS setup, and MOK enrollment
# Dynamically detects OS version and applies appropriate patches
# Compatible with RHEL and derivatives (AlmaLinux, Rocky Linux, etc.)
#

set -e

# Configuration
DRIVER_NAME="rcraid"
DRIVER_VERSION="9.3.3"
KVERS=$(uname -r)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER_SDK_DIR="$SCRIPT_DIR/driver_sdk"
SRC_DIR="$DRIVER_SDK_DIR/src"
CERT_DIR="$DRIVER_SDK_DIR/certs"
DKMS_DIR="/usr/src/${DRIVER_NAME}-${DRIVER_VERSION}"

# Detect kernel source directory (RHEL vs Ubuntu style)
if [ -d "/usr/src/kernels/$KVERS" ]; then
    KERNEL_SRC_DIR="/usr/src/kernels/$KVERS"
    SIGN_TOOL="/usr/src/kernels/$KVERS/scripts/sign-file"
elif [ -d "/usr/src/linux-headers-$KVERS" ]; then
    KERNEL_SRC_DIR="/usr/src/linux-headers-$KVERS"
    SIGN_TOOL="/usr/src/linux-headers-$KVERS/scripts/sign-file"
else
    KERNEL_SRC_DIR=""
    SIGN_TOOL=""
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

#######################################
# OS/Kernel Version Detection
#######################################

# Detect RHEL major version (9 or 10)
detect_rhel_version() {
    local rhel_major=0
    
    if [ -f /etc/redhat-release ]; then
        rhel_major=$(grep -oP '(?<=release )\d+' /etc/redhat-release 2>/dev/null | head -1)
    elif [ -f /etc/os-release ]; then
        rhel_major=$(grep -oP '(?<=VERSION_ID=")\d+' /etc/os-release 2>/dev/null | head -1)
    fi
    
    # Default to 9 if detection fails
    if [ -z "$rhel_major" ] || [ "$rhel_major" -lt 9 ]; then
        rhel_major=9
    fi
    
    echo "$rhel_major"
}

# Detect kernel major.minor version
detect_kernel_version() {
    echo "$KVERS" | grep -oP '^\d+\.\d+' | head -1
}

# Get full OS name for display
get_os_name() {
    if [ -f /etc/redhat-release ]; then
        cat /etc/redhat-release
    elif [ -f /etc/os-release ]; then
        grep PRETTY_NAME /etc/os-release | cut -d'"' -f2
    else
        echo "Unknown"
    fi
}

# Get OS ID (rhel, almalinux, rocky, etc.)
get_os_id() {
    if [ -f /etc/os-release ]; then
        grep "^ID=" /etc/os-release | cut -d'"' -f2 | cut -d'=' -f2 | tr -d '"'
    else
        echo "unknown"
    fi
}

# Get OS version ID (e.g., 9.7, 10.1)
get_os_version_id() {
    if [ -f /etc/os-release ]; then
        grep "^VERSION_ID=" /etc/os-release | cut -d'"' -f2 | tr -d '"'
    else
        echo "unknown"
    fi
}

# Store detected versions globally
RHEL_MAJOR=$(detect_rhel_version)
KERNEL_VERSION=$(detect_kernel_version)
OS_NAME=$(get_os_name)
OS_ID=$(get_os_id)
OS_VERSION_ID=$(get_os_version_id)

#######################################
# Helper Functions
#######################################

print_header() {
    clear
    echo -e "${BLUE}=============================================${NC}"
    echo -e "${BLUE}  AMD rcraid Driver Manager${NC}"
    echo -e "${BLUE}  RHEL 9.x & 10.x Compatibility Tool${NC}"
    echo -e "${BLUE}=============================================${NC}"
    echo ""
}

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "This operation requires root privileges"
        echo "Please run: sudo $0"
        return 1
    fi
    return 0
}

check_driver_sdk() {
    if [ ! -d "$DRIVER_SDK_DIR" ]; then
        print_error "driver_sdk directory not found!"
        echo "Please extract the AMD RAID driver package first."
        echo "Expected location: $DRIVER_SDK_DIR"
        return 1
    fi
    return 0
}

check_kernel_devel() {
    if [ -z "$KERNEL_SRC_DIR" ] || [ ! -d "$KERNEL_SRC_DIR" ]; then
        print_warning "kernel-devel not installed for $KVERS"
        echo ""
        read -p "Install kernel-devel now? (Y/n): " install_kdev
        if [ "$install_kdev" != "n" ] && [ "$install_kdev" != "N" ]; then
            print_status "Installing kernel-devel..."
            dnf install -y kernel-devel-$KVERS || {
                print_error "Failed to install kernel-devel"
                return 1
            }
            # Re-detect after install
            if [ -d "/usr/src/kernels/$KVERS" ]; then
                KERNEL_SRC_DIR="/usr/src/kernels/$KVERS"
                SIGN_TOOL="/usr/src/kernels/$KVERS/scripts/sign-file"
            fi
        else
            print_error "kernel-devel is required to build the module"
            return 1
        fi
    fi
    return 0
}

check_secure_boot() {
    if command -v mokutil &> /dev/null; then
        if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
            return 0  # Secure Boot is enabled
        fi
    fi
    return 1  # Secure Boot disabled or unknown
}

find_installed_module() {
    # Check various locations for installed module
    local locations=(
        "/lib/modules/$KVERS/extra/rcraid.ko"
        "/lib/modules/$KVERS/extra/rcraid/rcraid.ko"
        "/lib/modules/$KVERS/extra/rcraid.ko.xz"
        "/lib/modules/$KVERS/extra/rcraid/rcraid.ko.xz"
        "/lib/modules/$KVERS/updates/rcraid.ko"
        "/lib/modules/$KVERS/updates/rcraid.ko.xz"
    )
    
    for loc in "${locations[@]}"; do
        if [ -f "$loc" ]; then
            echo "$loc"
            return 0
        fi
    done
    
    # Check DKMS
    local dkms_module=$(find /var/lib/dkms/rcraid -name "rcraid.ko" 2>/dev/null | head -1)
    if [ -n "$dkms_module" ]; then
        echo "$dkms_module"
        return 0
    fi
    
    return 1
}

find_any_module() {
    # Find module from any location - for RPM building
    local module_path=""
    
    # Check source directory first
    if [ -f "$SRC_DIR/rcraid.ko" ]; then
        echo "$SRC_DIR/rcraid.ko"
        return 0
    fi
    
    # Check DKMS build directory
    local dkms_module=$(find /var/lib/dkms/rcraid -name "rcraid.ko" 2>/dev/null | head -1)
    if [ -n "$dkms_module" ]; then
        echo "$dkms_module"
        return 0
    fi
    
    # Check installed modules (may be compressed)
    if [ -f "/lib/modules/$KVERS/extra/rcraid.ko.xz" ]; then
        echo "/lib/modules/$KVERS/extra/rcraid.ko.xz"
        return 0
    elif [ -f "/lib/modules/$KVERS/extra/rcraid.ko" ]; then
        echo "/lib/modules/$KVERS/extra/rcraid.ko"
        return 0
    elif [ -f "/lib/modules/$KVERS/extra/rcraid/rcraid.ko.xz" ]; then
        echo "/lib/modules/$KVERS/extra/rcraid/rcraid.ko.xz"
        return 0
    elif [ -f "/lib/modules/$KVERS/extra/rcraid/rcraid.ko" ]; then
        echo "/lib/modules/$KVERS/extra/rcraid/rcraid.ko"
        return 0
    fi
    
    return 1
}

is_module_signed() {
    local module="$1"
    
    # Handle compressed modules
    if [[ "$module" == *.xz ]]; then
        if xz -dc "$module" 2>/dev/null | grep -q "~Module signature appended~"; then
            return 0
        fi
    else
        if grep -q "~Module signature appended~" "$module" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

is_patches_applied() {
    # Check for EL9 patches
    if [ -f "$SRC_DIR/rc_config.c" ]; then
        if grep -q "RHEL_RELEASE_VERSION(9,6)" "$SRC_DIR/rc_config.c"; then
            return 0
        fi
    fi
    # Check for EL10 patches
    if [ -f "$SRC_DIR/rc_init.c" ]; then
        if grep -q "sdev_configure" "$SRC_DIR/rc_init.c" 2>/dev/null; then
            return 0
        fi
    fi
    return 1  # Patches not applied
}

is_mk_certs_patched() {
    if [ -f "$DRIVER_SDK_DIR/mk_certs" ]; then
        if grep -q "PATCHED_FOR_RHEL" "$DRIVER_SDK_DIR/mk_certs"; then
            return 0
        fi
    fi
    return 1
}

#######################################
# Patching Functions
#######################################

patch_mk_certs() {
    local mk_certs_file="$1/mk_certs"
    
    if [ ! -f "$mk_certs_file" ]; then
        print_warning "mk_certs not found at $mk_certs_file"
        return 1
    fi
    
    if grep -q "PATCHED_FOR_RHEL" "$mk_certs_file"; then
        print_warning "mk_certs already patched, skipping..."
        return 0
    fi
    
    print_status "Patching mk_certs..."
    
    # Fix the -outform DEV typo -> DER
    if grep -q "\-outform DEV" "$mk_certs_file"; then
        sed -i 's/-outform DEV/-outform DER/g' "$mk_certs_file"
        echo "  Fixed -outform DEV -> DER typo"
    fi
    
    # Add RHEL kernel path for sign-file tool
    if ! grep -q "/usr/src/kernels/" "$mk_certs_file"; then
        sed -i 's|if \[ -f "/usr/src/linux-headers-\$KVERS/scripts/sign-file" \]; then|if [ -f "/usr/src/kernels/$KVERS/scripts/sign-file" ]; then\n\t\tSIGN_TOOL=/usr/src/kernels/$KVERS/scripts/sign-file\n\t    elif [ -f "/usr/src/linux-headers-$KVERS/scripts/sign-file" ]; then|g' "$mk_certs_file"
        echo "  Added RHEL kernel paths for sign-file tool"
    fi
    
    # Add a marker so we know it's been patched
    sed -i '1a# PATCHED_FOR_RHEL - AMD rcraid patcher applied RHEL 9.x/10.x fixes' "$mk_certs_file"
    
    print_status "mk_certs patched successfully"
    return 0
}

apply_patches_el9() {
    print_status "Applying patches for RHEL 9.x (kernel 5.14.x)..."
    
    # Patch rc_config.c - genhd.h fix
    if grep -q "RHEL_RELEASE_VERSION(9,6)" "$SRC_DIR/rc_config.c"; then
        print_warning "rc_config.c already patched, skipping..."
    else
        print_status "Patching rc_config.c (genhd.h fix)..."
        
        cat > /tmp/rc_config_fix.patch << 'PATCH'
--- a/rc_config.c
+++ b/rc_config.c
@@ -8,13 +8,12 @@
 #include <linux/fs.h>
 #include <linux/miscdevice.h>
 #include <linux/version.h>
-#if LINUX_VERSION_CODE < KERNEL_VERSION(5,14,0)
-#ifndef RHEL_RCBUILD
+#if LINUX_VERSION_CODE < KERNEL_VERSION(5,14,0) && !defined(RHEL_RELEASE_CODE)
 #include <linux/genhd.h>
-#endif
-#else
-//#include <blkdev.h>
+#elif defined(RHEL_RELEASE_CODE) && RHEL_RELEASE_CODE < RHEL_RELEASE_VERSION(9,6)
+#include <linux/genhd.h>
 #endif
+#include <linux/blkdev.h>
 #include <linux/sched.h>
 #include <linux/completion.h>
 #include <linux/vmalloc.h>
PATCH
        cd "$SRC_DIR"
        if ! patch -p1 --forward < /tmp/rc_config_fix.patch 2>/dev/null; then
            print_warning "Patch command failed, trying manual fix..."
            cp rc_config.c.orig rc_config.c 2>/dev/null || true
            sed -i '11,17d' rc_config.c
            sed -i '10a\
#if LINUX_VERSION_CODE < KERNEL_VERSION(5,14,0) \&\& !defined(RHEL_RELEASE_CODE)\
#include <linux/genhd.h>\
#elif defined(RHEL_RELEASE_CODE) \&\& RHEL_RELEASE_CODE < RHEL_RELEASE_VERSION(9,6)\
#include <linux/genhd.h>\
#endif\
#include <linux/blkdev.h>' rc_config.c
        fi
        cd - > /dev/null
        print_status "rc_config.c patched successfully"
    fi
    
    # Patch rc_init.c - blk_queue functions fix
    if grep -q "RHEL_RELEASE_VERSION(9,6)" "$SRC_DIR/rc_init.c"; then
        print_warning "rc_init.c already patched for EL9, skipping..."
    else
        print_status "Patching rc_init.c (blk_queue functions fix)..."
        
        cd "$SRC_DIR"
        
        # Patch blk_queue_max_hw_sectors
        if grep -q "blk_queue_max_hw_sectors(sdev->request_queue, 256);" rc_init.c; then
            sed -i '/blk_queue_max_hw_sectors(sdev->request_queue, 256);/c\
#if defined(RHEL_RELEASE_CODE) && RHEL_RELEASE_CODE >= RHEL_RELEASE_VERSION(9,6)\
        sdev->host->max_sectors = 256;\
#else\
        blk_queue_max_hw_sectors(sdev->request_queue, 256);\
#endif' rc_init.c
            echo "  Fixed blk_queue_max_hw_sectors"
        fi

        # Patch blk_queue_virt_boundary
        if grep -q "blk_queue_virt_boundary(sdev->request_queue, NVME_CTRL_PAGE_SIZE - 1);" rc_init.c; then
            sed -i '/blk_queue_virt_boundary(sdev->request_queue, NVME_CTRL_PAGE_SIZE - 1);/c\
#if defined(RHEL_RELEASE_CODE) && RHEL_RELEASE_CODE >= RHEL_RELEASE_VERSION(9,6)\
    /* virt_boundary handled differently in RHEL 9.6+ */\
#else\
    blk_queue_virt_boundary(sdev->request_queue, NVME_CTRL_PAGE_SIZE - 1);\
#endif' rc_init.c
            echo "  Fixed blk_queue_virt_boundary"
        fi
        
        cd - > /dev/null
        print_status "rc_init.c patched successfully"
    fi
}

apply_patches_el10() {
    print_status "Applying patches for RHEL 10.x (kernel 6.12.x)..."
    
    cd "$SRC_DIR"
    
    # 1. Add vmalloc.h include (required for vmalloc in kernel 6.12+)
    if ! grep -q '#include <linux/vmalloc.h>' rc_init.c; then
        sed -i '/#include <linux\/sysctl.h>/a #include <linux/vmalloc.h>' rc_init.c
        echo "  Added vmalloc.h include"
    else
        echo "  vmalloc.h include already present"
    fi
    
    # 2. Fix sdev_configure rename (was slave_configure in older kernels)
    # 2a. Update forward declaration
    if grep -q '^static int  rc_slave_cfg(struct scsi_device \*sdev);' rc_init.c; then
        sed -i 's/^static int  rc_slave_cfg(struct scsi_device \*sdev);/static int rc_slave_cfg(struct scsi_device *sdev, struct queue_limits *lim);/' rc_init.c
        echo "  Updated rc_slave_cfg forward declaration"
    fi
    
    # 2b. Update function definition (multi-line format)
    if grep -q '^rc_slave_cfg(struct scsi_device \*sdev)$' rc_init.c; then
        sed -i 's/^rc_slave_cfg(struct scsi_device \*sdev)$/rc_slave_cfg(struct scsi_device *sdev, struct queue_limits *lim)/' rc_init.c
        echo "  Updated rc_slave_cfg function definition"
    fi
    
    # 2c. Update struct member from .slave_configure to .sdev_configure
    if grep -q '\.slave_configure' rc_init.c; then
        sed -i 's/\.slave_configure/.sdev_configure/' rc_init.c
        echo "  Updated .slave_configure to .sdev_configure"
    else
        echo "  .sdev_configure already updated"
    fi
    
    # 3. Fix blk_queue_* calls - now use queue_limits struct (lim parameter)
    # Replace blk_queue_max_hw_sectors(sdev->request_queue, 256);
    # With    lim->max_hw_sectors = 256;
    if grep -q 'blk_queue_max_hw_sectors' rc_init.c; then
        sed -i 's/blk_queue_max_hw_sectors(sdev->request_queue, \([^)]*\));/lim->max_hw_sectors = \1;/' rc_init.c
        echo "  Fixed blk_queue_max_hw_sectors -> lim->max_hw_sectors"
    fi
    
    # Handle the RHEL version conditional we may have added for EL9
    # Replace the whole conditional block with simple lim assignment
    if grep -q '#if defined(RHEL_RELEASE_CODE) && RHEL_RELEASE_CODE >= RHEL_RELEASE_VERSION(9,6)' rc_init.c; then
        # Remove the EL9 conditional and replace with EL10 style
        sed -i '/#if defined(RHEL_RELEASE_CODE) && RHEL_RELEASE_CODE >= RHEL_RELEASE_VERSION(9,6)/,/#endif/c\
        lim->max_hw_sectors = 256;' rc_init.c
        echo "  Converted EL9 conditional to EL10 queue_limits style"
    fi
    
    # Remove blk_queue_virt_boundary entirely or convert to lim->virt_boundary_mask
    if grep -q 'blk_queue_virt_boundary' rc_init.c; then
        sed -i '/blk_queue_virt_boundary/d' rc_init.c
        echo "  Removed blk_queue_virt_boundary (handled differently in 6.12+)"
    fi
    
    # 4. Fix sysctl registration for kernel 6.12+
    # Use register_sysctl_sz instead of register_sysctl
    if grep -q 'rcraid_sysctl_hdr = register_sysctl("rcraid", rcraid_table);' rc_init.c; then
        sed -i 's/rcraid_sysctl_hdr = register_sysctl("rcraid", rcraid_table);/rcraid_sysctl_hdr = register_sysctl_sz("rcraid", rcraid_table, ARRAY_SIZE(rcraid_table) - 1);/' rc_init.c
        echo "  Fixed sysctl registration for kernel 6.12+"
    else
        echo "  sysctl registration already fixed or not present"
    fi
    
    cd - > /dev/null
    print_status "EL10 patches applied successfully"
}

apply_patches() {
    print_status "Applying patches for $(get_os_name) compatibility..."
    print_status "Detected: RHEL major=$RHEL_MAJOR, Kernel=$KERNEL_VERSION"
    
    check_driver_sdk || return 1
    
    # Backup original files
    print_status "Creating backups of original files..."
    cp -n "$SRC_DIR/rc_config.c" "$SRC_DIR/rc_config.c.orig" 2>/dev/null || true
    cp -n "$SRC_DIR/rc_init.c" "$SRC_DIR/rc_init.c.orig" 2>/dev/null || true
    cp -n "$DRIVER_SDK_DIR/mk_certs" "$DRIVER_SDK_DIR/mk_certs.orig" 2>/dev/null || true
    
    # Apply version-specific patches
    if [ "$RHEL_MAJOR" -ge 10 ]; then
        # RHEL 10.x / kernel 6.x
        apply_patches_el10
    else
        # RHEL 9.x / kernel 5.14.x
        apply_patches_el9
    fi
    
    # Patch mk_certs (common to all versions)
    patch_mk_certs "$DRIVER_SDK_DIR"
    
    # Create symlink for binary blob if needed
    print_status "Ensuring binary blob symlink exists..."
    cd "$SRC_DIR"
    if [ ! -e rcblob.x86_64.o ]; then
        ln -sf rcblob.x86_64 rcblob.x86_64.o
        echo "  Created symlink: rcblob.x86_64.o -> rcblob.x86_64"
    fi
    cd - > /dev/null
    
    print_status "All patches applied successfully!"
    return 0
}

#######################################
# Build Functions
#######################################

build_module() {
    print_status "Building rcraid module..."
    
    check_driver_sdk || return 1
    check_kernel_devel || return 1
    
    # Check if patches are applied
    if ! is_patches_applied; then
        print_warning "Patches not applied. Applying now..."
        apply_patches || return 1
    fi
    
    # Create symlink for binary blob if needed
    cd "$SRC_DIR"
    if [ ! -e rcblob.x86_64.o ]; then
        ln -sf rcblob.x86_64 rcblob.x86_64.o
    fi
    cd - > /dev/null
    
    # Build
    print_status "Compiling module for kernel $KVERS..."
    make -C /lib/modules/$KVERS/build M="$SRC_DIR" modules
    
    if [ -f "$SRC_DIR/rcraid.ko" ]; then
        print_status "Build successful: $SRC_DIR/rcraid.ko"
        return 0
    else
        print_error "Build failed!"
        return 1
    fi
}

#######################################
# Signing Functions
#######################################

generate_signing_key() {
    print_status "Generating module signing key..."
    
    mkdir -p "$CERT_DIR"
    chmod 700 "$CERT_DIR"
    
    if [ -f "$CERT_DIR/module_signing_key.der" ]; then
        echo ""
        read -p "Signing key already exists. Regenerate? (y/N): " regen
        if [ "$regen" != "y" ] && [ "$regen" != "Y" ]; then
            print_status "Using existing key."
            return 0
        fi
        rm -f "$CERT_DIR/module_signing_key.der" "$CERT_DIR/module_signing_key.priv"
    fi
    
    openssl req -new -x509 -newkey rsa:4096 \
        -keyout "$CERT_DIR/module_signing_key.priv" \
        -outform DER \
        -out "$CERT_DIR/module_signing_key.der" \
        -nodes -days 3650 \
        -subj "/CN=rcraid module signing key $(hostname)/"
    
    chmod 600 "$CERT_DIR/module_signing_key.priv"
    
    print_status "Signing key generated successfully!"
    return 0
}

sign_module() {
    local module_path="$1"
    
    check_root || return 1
    
    if [ -z "$module_path" ]; then
        # Try to find module
        if [ -f "$SRC_DIR/rcraid.ko" ]; then
            module_path="$SRC_DIR/rcraid.ko"
        else
            module_path=$(find_installed_module)
        fi
    fi
    
    if [ -z "$module_path" ] || [ ! -f "$module_path" ]; then
        print_error "No module found to sign!"
        return 1
    fi
    
    # Handle compressed modules
    if [[ "$module_path" == *.xz ]]; then
        print_status "Decompressing module..."
        local temp_module="/tmp/rcraid.ko"
        xz -dk "$module_path" -c > "$temp_module"
        module_path="$temp_module"
    fi
    
    print_status "Signing module: $module_path"
    
    # Generate key if needed
    if [ ! -f "$CERT_DIR/module_signing_key.der" ]; then
        generate_signing_key || return 1
    fi
    
    # Check for sign-file tool
    if [ ! -f "$SIGN_TOOL" ]; then
        print_error "sign-file tool not found at $SIGN_TOOL"
        echo "Please ensure kernel-devel is installed."
        return 1
    fi
    
    # Sign the module
    "$SIGN_TOOL" sha512 \
        "$CERT_DIR/module_signing_key.priv" \
        "$CERT_DIR/module_signing_key.der" \
        "$module_path"
    
    print_status "Module signed successfully!"
    return 0
}

sign_installed_module() {
    check_root || return 1
    
    local module_path=$(find_installed_module)
    
    if [ -z "$module_path" ]; then
        print_error "No installed module found!"
        return 1
    fi
    
    print_status "Found installed module: $module_path"
    
    # Handle compressed modules
    local was_compressed=0
    if [[ "$module_path" == *.xz ]]; then
        was_compressed=1
        print_status "Decompressing module..."
        xz -d "$module_path"
        module_path="${module_path%.xz}"
    fi
    
    # Sign it
    sign_module "$module_path" || return 1
    
    # Re-compress if it was compressed
    if [ $was_compressed -eq 1 ]; then
        print_status "Re-compressing module..."
        xz "$module_path"
    fi
    
    print_status "Installed module signed successfully!"
    return 0
}

enroll_mok_key() {
    check_root || return 1
    
    if [ ! -f "$CERT_DIR/module_signing_key.der" ]; then
        print_error "Signing key not found!"
        echo "Please generate a signing key first (menu option 11)."
        return 1
    fi
    
    print_status "Enrolling MOK key..."
    echo ""
    echo "You will be prompted to create a password."
    echo "Remember this password - you'll need it during the next reboot!"
    echo ""
    
    if mokutil --import "$CERT_DIR/module_signing_key.der"; then
        echo ""
        print_status "Key enrollment initiated!"
        echo ""
        echo -e "${YELLOW}IMPORTANT: You must reboot to complete enrollment!${NC}"
        echo ""
        echo "During reboot, the MOK Manager (blue screen) will appear."
        echo "Follow these steps:"
        echo "  1. Select 'Enroll MOK'"
        echo "  2. Select 'Continue'"
        echo "  3. Select 'Yes'"
        echo "  4. Enter the password you just created"
        echo "  5. Select 'Reboot'"
        echo ""
        return 0
    else
        print_error "MOK enrollment failed!"
        return 1
    fi
}

#######################################
# Installation Functions
#######################################

install_module() {
    check_root || return 1
    
    local module_path="$SRC_DIR/rcraid.ko"
    
    if [ ! -f "$module_path" ]; then
        print_error "Built module not found at $module_path"
        echo "Please build the module first."
        return 1
    fi
    
    print_status "Installing module..."
    
    # Create directory and copy module
    mkdir -p "/lib/modules/$KVERS/extra"
    cp "$module_path" "/lib/modules/$KVERS/extra/"
    
    # Update module dependencies
    depmod -a
    
    # Configure module to load at boot
    cat > /etc/modules-load.d/rcraid.conf << EOF
# Load AMD RAID driver
rcraid
EOF

    # Configure modprobe
    cat > /etc/modprobe.d/rcraid.conf << EOF
# Ensure rcraid loads before ahci claims the devices
softdep ahci pre: rcraid
EOF

    # Update initramfs
    print_status "Updating initramfs..."
    dracut -f
    
    print_status "Module installed successfully!"
    return 0
}

full_install() {
    check_root || return 1
    check_driver_sdk || return 1
    check_kernel_devel || return 1
    
    echo ""
    print_status "Starting full installation process..."
    print_status "Target: $(get_os_name) / Kernel $KVERS"
    echo ""
    
    # Step 1: Apply patches
    print_status "Step 1/5: Applying patches..."
    apply_patches || return 1
    
    # Step 2: Build module
    print_status "Step 2/5: Building module..."
    build_module || return 1
    
    # Step 3: Generate signing key and sign module
    if check_secure_boot; then
        print_status "Step 3/5: Signing module (Secure Boot enabled)..."
        generate_signing_key || return 1
        sign_module "$SRC_DIR/rcraid.ko" || return 1
    else
        print_status "Step 3/5: Skipping signing (Secure Boot disabled)..."
    fi
    
    # Step 4: Install module
    print_status "Step 4/5: Installing module..."
    install_module || return 1
    
    # Step 5: Enroll MOK key if Secure Boot enabled
    if check_secure_boot; then
        print_status "Step 5/5: Enrolling MOK key..."
        enroll_mok_key || return 1
    else
        print_status "Step 5/5: Skipping MOK enrollment (Secure Boot disabled)..."
    fi
    
    echo ""
    print_status "Full installation complete!"
    echo ""
    if check_secure_boot; then
        echo -e "${YELLOW}REBOOT REQUIRED to complete MOK enrollment!${NC}"
    else
        echo "You can try loading the module now with: sudo modprobe rcraid"
    fi
    
    return 0
}

#######################################
# DKMS Functions
#######################################

setup_dkms() {
    check_root || return 1
    check_driver_sdk || return 1
    check_kernel_devel || return 1
    
    print_status "Setting up DKMS for automatic rebuilds..."
    
    # Install DKMS if not present
    if ! command -v dkms &> /dev/null; then
        print_status "Installing DKMS..."
        dnf install -y dkms
    fi
    
    # Remove old DKMS module if exists
    if dkms status | grep -q "$DRIVER_NAME"; then
        print_status "Removing old DKMS module..."
        dkms remove -m "$DRIVER_NAME" -v "$DRIVER_VERSION" --all 2>/dev/null || true
    fi
    
    # Remove old directory if exists
    if [ -d "$DKMS_DIR" ]; then
        rm -rf "$DKMS_DIR"
    fi
    
    print_status "Creating DKMS source directory..."
    mkdir -p "$DKMS_DIR"
    
    # Copy source files
    print_status "Copying source files..."
    for file in build_number.h common_shell install_rh Makefile mk_certs \
                rc_adapter.h rc_ahci.h rcblob.x86_64 rc_config.c \
                rc_event.c rc.h rc_init.c rc_mem_ops.c rc_msg.c \
                rc_msg_platform.h rc_pci_ids.h rc_scsi.h rc_srb.h \
                rc_types_platform.h uninstall_rh version.h; do
        if [ -f "$SRC_DIR/$file" ]; then
            cp "$SRC_DIR/$file" "$DKMS_DIR/"
        elif [ -f "$DRIVER_SDK_DIR/$file" ]; then
            cp "$DRIVER_SDK_DIR/$file" "$DKMS_DIR/"
        fi
    done
    
    # Create symlink for binary blob
    cd "$DKMS_DIR"
    ln -sf rcblob.x86_64 rcblob.x86_64.o
    cd - > /dev/null
    
    # Apply patches to DKMS source
    print_status "Applying patches to DKMS source..."
    
    # Temporarily set SRC_DIR to DKMS_DIR for patching
    local orig_src_dir="$SRC_DIR"
    SRC_DIR="$DKMS_DIR"
    
    if [ "$RHEL_MAJOR" -ge 10 ]; then
        apply_patches_el10
    else
        apply_patches_el9
    fi
    
    SRC_DIR="$orig_src_dir"
    
    # Patch mk_certs in DKMS dir
    patch_mk_certs "$DKMS_DIR"
    
    # Create DKMS configuration
    print_status "Creating DKMS configuration..."
    cat > "$DKMS_DIR/dkms.conf" << DKMSCONF
PACKAGE_NAME="$DRIVER_NAME"
PACKAGE_VERSION="$DRIVER_VERSION"
BUILT_MODULE_NAME[0]="$DRIVER_NAME"
DEST_MODULE_LOCATION[0]="/extra"
AUTOINSTALL="yes"
MAKE[0]="ln -sf rcblob.x86_64 rcblob.x86_64.o; make -C \${kernel_source_dir} M=\${dkms_tree}/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build modules"
DKMSCONF

    # Add to DKMS
    print_status "Adding module to DKMS..."
    dkms add -m "$DRIVER_NAME" -v "$DRIVER_VERSION"
    
    # Build
    print_status "Building module with DKMS..."
    dkms build -m "$DRIVER_NAME" -v "$DRIVER_VERSION"
    
    # Install
    print_status "Installing module with DKMS..."
    dkms install -m "$DRIVER_NAME" -v "$DRIVER_VERSION"
    
    # Configure module to load at boot
    cat > /etc/modules-load.d/rcraid.conf << EOF
# Load AMD RAID driver
rcraid
EOF

    cat > /etc/modprobe.d/rcraid.conf << EOF
# Ensure rcraid loads before ahci claims the devices
softdep ahci pre: rcraid
EOF

    # Update initramfs
    print_status "Updating initramfs..."
    dracut -f
    
    echo ""
    print_status "DKMS setup complete!"
    echo ""
    dkms status
    echo ""
    
    # Check if we need to sign for Secure Boot
    if check_secure_boot; then
        echo -e "${YELLOW}Secure Boot is enabled!${NC}"
        echo ""
        echo "DKMS may have its own MOK key. Check with:"
        echo "  sudo mokutil --list-enrolled"
        echo ""
        echo "If the module fails to load, you may need to:"
        echo "  1. Sign the module manually (use menu option 8)"
        echo "  2. Enroll your signing key (use menu option 9)"
        echo ""
        read -p "Sign and enroll key now? (Y/n): " sign_now
        if [ "$sign_now" != "n" ] && [ "$sign_now" != "N" ]; then
            generate_signing_key
            sign_installed_module
            enroll_mok_key
        fi
    fi
    
    return 0
}

#######################################
# RPM/ISO Build Functions (Dynamic!)
#######################################

build_driver_rpm() {
    print_status "Building Driver Update Disk RPM..."
    
    # DYNAMIC: Generate release string from actual kernel version
    local RELEASE=$(echo "$KVERS" | sed 's/-/./g')
    local ARCH="x86_64"
    local BUILD_ROOT="$HOME/rpmbuild"
    local MODULE_PATH=""
    
    # DYNAMIC: Detect OS info for RPM metadata
    local OS_SUMMARY=""
    local OS_DESC=""
    
    if [ "$RHEL_MAJOR" -ge 10 ]; then
        OS_SUMMARY="AMD RAID driver for RHEL 10.x"
        OS_DESC="This package provides the rcraid kernel module built for Linux kernel $KVERS (EL10) for the $ARCH family of processors."
    else
        OS_SUMMARY="AMD RAID driver for RHEL 9.x"
        OS_DESC="This package provides the rcraid kernel module built for Linux kernel $KVERS (EL9) for the $ARCH family of processors."
    fi
    
    print_status "Building for: $OS_NAME"
    print_status "Kernel: $KVERS"
    print_status "Release tag: $RELEASE"
    
    # Find the module
    MODULE_PATH=$(find_any_module)
    
    if [ -z "$MODULE_PATH" ]; then
        print_warning "No module found. Building one first..."
        check_driver_sdk || return 1
        check_kernel_devel || return 1
        apply_patches || return 1
        build_module || return 1
        MODULE_PATH="$SRC_DIR/rcraid.ko"
    fi
    
    print_status "Using module: $MODULE_PATH"
    
    # Handle compressed modules
    if [[ "$MODULE_PATH" == *.xz ]]; then
        print_status "Decompressing module..."
        xz -dk "$MODULE_PATH" -c > /tmp/rcraid.ko
        MODULE_PATH="/tmp/rcraid.ko"
    fi
    
    # Install build dependencies
    print_status "Installing build dependencies..."
    dnf install -y rpm-build rpmdevtools createrepo_c genisoimage 2>/dev/null || true
    
    # Setup RPM build environment
    rm -f $BUILD_ROOT/RPMS/x86_64/kmod-rcraid*.rpm 2>/dev/null || true
    print_status "Setting up RPM build environment..."
    rpmdev-setuptree 2>/dev/null || mkdir -p $BUILD_ROOT/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
    
    # Create source tarball
    print_status "Creating source tarball..."
    local TARBALL_DIR="${DRIVER_NAME}-${DRIVER_VERSION}"
    rm -rf /tmp/$TARBALL_DIR
    mkdir -p /tmp/$TARBALL_DIR
    
    # Copy the built module
    cp "$MODULE_PATH" /tmp/$TARBALL_DIR/rcraid.ko
    
    # Create the tarball
    cd /tmp
    tar czf $BUILD_ROOT/SOURCES/${DRIVER_NAME}-${DRIVER_VERSION}.tar.gz $TARBALL_DIR
    rm -rf /tmp/$TARBALL_DIR
    cd - > /dev/null

    # Generate kernel module dependencies
    print_status "Generating kernel symbol dependencies..."
    local KSYM_REQUIRES=""
    if [ -f "$MODULE_PATH" ]; then
        KSYM_REQUIRES=$(modprobe --dump-modversions "$MODULE_PATH" 2>/dev/null | \
            awk '{printf "Requires: kernel(%s) = 0x%s\n", $2, substr($1, 3)}' | \
            sort -u)
    fi
    
    # Create spec file (FULLY DYNAMIC!)
    print_status "Creating RPM spec file..."
    cat > $BUILD_ROOT/SPECS/${DRIVER_NAME}.spec << SPEC
# Disable debuginfo package - we're using pre-built binary module
%global debug_package %{nil}
%define __strip /bin/true

%define kmod_name rcraid
%define kmod_version ${DRIVER_VERSION}
%define kernel_version ${KVERS}

Name:           kmod-%{kmod_name}
Version:        %{kmod_version}
Release:        ${RELEASE}
Summary:        ${OS_SUMMARY}
License:        Proprietary (AMD)
Group:          System Environment/Kernel
URL:            https://www.amd.com

Source0:        %{kmod_name}-%{kmod_version}.tar.gz

Requires:       /usr/sbin/depmod
Requires:       /usr/sbin/weak-modules
${KSYM_REQUIRES}

Provides:       kmod(%{kmod_name}) = %{version}
Provides:       kmod(%{kmod_name}.ko)
Provides:       kernel-modules >= %{kernel_version}
Provides:       %{kmod_name}-kmod = %{version}-%{release}
Provides:       modalias(pci:v00001022d000043BDsv*sd*bc*sc*i*)
Provides:       modalias(pci:v00001022d00007905sv*sd*bc*sc*i*)
Provides:       modalias(pci:v00001022d0000791[67]sv*sd*bc*sc*i*)
Provides:       modalias(pci:v00001022d0000B000sv*sd*bc01sc08i02*)

%description
${OS_DESC}

Built on: $(date)
Built by: $(whoami)@$(hostname)

%prep
%setup -q -n %{kmod_name}-%{kmod_version}

%build
# Module is pre-built

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/lib/modules/%{kernel_version}/extra/%{kmod_name}
install -m 644 rcraid.ko %{buildroot}/lib/modules/%{kernel_version}/extra/%{kmod_name}/

# Create modprobe config
mkdir -p %{buildroot}/etc/modprobe.d
cat > %{buildroot}/etc/modprobe.d/%{kmod_name}.conf << MODPROBE
# Ensure rcraid loads before ahci claims the devices
softdep ahci pre: rcraid
MODPROBE

# Create modules-load config
mkdir -p %{buildroot}/etc/modules-load.d
cat > %{buildroot}/etc/modules-load.d/%{kmod_name}.conf << MODLOAD
# Load AMD RAID driver at boot
rcraid
MODLOAD

%post
if [ -e "/boot/System.map-%{kernel_version}" ]; then
    /usr/sbin/depmod -aeF "/boot/System.map-%{kernel_version}" "%{kernel_version}" > /dev/null || :
fi
modules=( \$(find /lib/modules/%{kernel_version}/extra/%{kmod_name} | grep -E '\.ko(\.gz|\.bz2|\.xz|\.zst)?\$') )
if [ -x "/usr/sbin/weak-modules" ]; then
    printf '%s\\n' "\${modules[@]}" | /usr/sbin/weak-modules --add-modules
fi

%preun
rpm -ql kmod-%{kmod_name}-%{version}-%{release}.%{_arch} | grep -E '\.ko(\.gz|\.bz2|\.xz|\.zst)?\$' > /var/run/rpm-kmod-%{kmod_name}-modules

%postun
if [ -e "/boot/System.map-%{kernel_version}" ]; then
    /usr/sbin/depmod -aeF "/boot/System.map-%{kernel_version}" "%{kernel_version}" > /dev/null || :
fi
modules=( \$(cat /var/run/rpm-kmod-%{kmod_name}-modules) )
rm /var/run/rpm-kmod-%{kmod_name}-modules
if [ -x "/usr/sbin/weak-modules" ]; then
    printf '%s\\n' "\${modules[@]}" | /usr/sbin/weak-modules --remove-modules
fi

%files
%defattr(-,root,root,-)
/lib/modules/%{kernel_version}/extra/%{kmod_name}/rcraid.ko
%config(noreplace) /etc/modprobe.d/%{kmod_name}.conf
%config(noreplace) /etc/modules-load.d/%{kmod_name}.conf

%changelog
* $(date "+%a %b %d %Y") $(whoami)@$(hostname) - ${DRIVER_VERSION}-${RELEASE}
- Built for ${OS_NAME}
- Kernel: ${KVERS}
- Patched for compatibility with kernel ${KERNEL_VERSION}
SPEC

    # Build the RPM
    print_status "Building RPM..."
    rpmbuild -bb $BUILD_ROOT/SPECS/${DRIVER_NAME}.spec
    
    # Find the built RPM
    local RPM_FILE=$(find $BUILD_ROOT/RPMS -name "kmod-${DRIVER_NAME}*.rpm" | head -1)
    
    if [ -f "$RPM_FILE" ]; then
        print_status "RPM built successfully!"
        
        # Copy RPM to home directory
        cp "$RPM_FILE" "$HOME/"
        
        echo ""
        print_status "RPM created: $HOME/$(basename $RPM_FILE)"
        echo ""
        echo "To install on an existing system:"
        echo "  sudo rpm -ivh $HOME/$(basename $RPM_FILE)"
        echo ""
        
        return 0
    else
        print_error "RPM build failed!"
        return 1
    fi
}

build_driver_iso() {
    print_status "Building Driver Update Disk ISO..."
    
    # First build the RPM
    build_driver_rpm || return 1
    
    local BUILD_ROOT="$HOME/rpmbuild"
    local RPM_FILE=$(find $BUILD_ROOT/RPMS -name "kmod-${DRIVER_NAME}*.rpm" | head -1)
    
    if [ ! -f "$RPM_FILE" ]; then
        print_error "RPM not found!"
        return 1
    fi
    
    # Install ISO creation tools
    print_status "Installing ISO creation tools..."
    dnf install -y createrepo_c genisoimage 2>/dev/null || true
    
    print_status "Creating Driver Update Disk ISO..."
    
    # Create DUD directory structure
    local DUD_DIR="/tmp/rcraid-dud"
    rm -rf $DUD_DIR
    mkdir -p $DUD_DIR/rpms/x86_64
    
    # Copy RPM
    cp "$RPM_FILE" $DUD_DIR/rpms/x86_64/
    
    # Create rhdd3 file (identifies this as a driver disk)
    echo -e "Driver Update Disk version 3\n" > $DUD_DIR/rhdd3
    
    # Create repo metadata
    cd $DUD_DIR/rpms/x86_64
    createrepo_c . 2>/dev/null || createrepo .
    cd - > /dev/null
    
    # Create ISO - DYNAMIC naming
    local ISO_NAME="rcraid-${DRIVER_VERSION}-${KVERS}.iso"
    
    # Find an ISO creation tool
    local ISO_TOOL=""
    if which genisoimage >/dev/null 2>&1; then
        ISO_TOOL="genisoimage"
    elif which mkisofs >/dev/null 2>&1; then
        ISO_TOOL="mkisofs"
    else
        print_error "No ISO creation tool found!"
        echo "Please install genisoimage: sudo dnf install genisoimage"
        rm -rf $DUD_DIR
        return 1
    fi
    
    print_status "Creating ISO with $ISO_TOOL..."
    $ISO_TOOL -o "$HOME/$ISO_NAME" -R -J -V "RCRAID_DUD" $DUD_DIR
    
    rm -rf $DUD_DIR
    
    if [ -f "$HOME/$ISO_NAME" ]; then
        echo ""
        print_status "Driver Update Disk ISO created successfully!"
        echo ""
        echo -e "${BLUE}=============================================${NC}"
        echo -e "${BLUE}  Files created in $HOME/${NC}"
        echo -e "${BLUE}=============================================${NC}"
        echo ""
        echo "  - $(basename $RPM_FILE)"
        echo "  - $ISO_NAME"
        echo ""
        echo -e "${BLUE}=== USAGE INSTRUCTIONS ===${NC}"
        echo ""
        echo -e "${GREEN}Method 1: Boot with inst.dd (specify location)${NC}"
        echo "  1. Copy ISO to USB drive"
        echo "  2. Boot installer"
        echo "  3. At boot menu, press Tab/e to edit"
        echo "  4. Add: inst.dd=hd:LABEL=<usb-label>:/$ISO_NAME"
        echo ""
        echo -e "${GREEN}Method 2: Interactive driver disk${NC}"
        echo "  1. Boot installer with: inst.dd"
        echo "  2. When prompted, select the drive with the ISO"
        echo ""
        echo -e "${GREEN}Method 3: HTTP server${NC}"
        echo "  1. Host ISO on web server"
        echo "  2. Boot with: inst.dd=http://server/$ISO_NAME"
        echo ""
        echo -e "${GREEN}Method 4: Install on existing system${NC}"
        echo "  sudo rpm -ivh $HOME/$(basename $RPM_FILE)"
        echo ""
        
        return 0
    else
        print_error "ISO creation failed!"
        return 1
    fi
}

#######################################
# Utility Functions
#######################################

try_load_module() {
    check_root || return 1
    
    print_status "Attempting to load rcraid module..."
    
    # Unload if already loaded
    if lsmod | grep -q "^rcraid"; then
        print_status "Unloading existing module..."
        modprobe -r rcraid 2>/dev/null || true
    fi
    
    # Try to load
    if modprobe rcraid; then
        print_status "Module loaded successfully!"
        echo ""
        lsmod | grep rcraid
        echo ""
        
        # Check for RAID devices
        print_status "Checking for RAID devices..."
        if ls /dev/sd* 2>/dev/null | grep -q sd; then
            lsblk
        else
            print_warning "No block devices found. RAID array may need to be configured."
        fi
        return 0
    else
        print_error "Failed to load module!"
        echo ""
        echo "Check dmesg for errors:"
        dmesg | tail -20
        echo ""
        
        if check_secure_boot; then
            echo -e "${YELLOW}Secure Boot is enabled.${NC}"
            echo "The module may need to be signed and the key enrolled."
            echo "Use menu options 8 and 9 to sign and enroll."
        fi
        return 1
    fi
}

restore_original_files() {
    check_driver_sdk || return 1
    
    print_status "Restoring original source files..."
    
    if [ -f "$SRC_DIR/rc_config.c.orig" ]; then
        cp "$SRC_DIR/rc_config.c.orig" "$SRC_DIR/rc_config.c"
        print_status "Restored rc_config.c"
    else
        print_warning "No backup found for rc_config.c"
    fi
    
    if [ -f "$SRC_DIR/rc_init.c.orig" ]; then
        cp "$SRC_DIR/rc_init.c.orig" "$SRC_DIR/rc_init.c"
        print_status "Restored rc_init.c"
    else
        print_warning "No backup found for rc_init.c"
    fi
    
    if [ -f "$DRIVER_SDK_DIR/mk_certs.orig" ]; then
        cp "$DRIVER_SDK_DIR/mk_certs.orig" "$DRIVER_SDK_DIR/mk_certs"
        print_status "Restored mk_certs"
    else
        print_warning "No backup found for mk_certs"
    fi
    
    # Clean build artifacts
    print_status "Cleaning build artifacts..."
    cd "$SRC_DIR"
    rm -f *.o *.ko .*.cmd .*.d 2>/dev/null || true
    rm -f rcraid.mod.c Module.symvers Modules.symvers 2>/dev/null || true
    rm -rf .tmp_versions Module.markers modules.order 2>/dev/null || true
    cd - > /dev/null
    
    print_status "Original files restored!"
    return 0
}

#######################################
# Status Display
#######################################

show_system_status() {
    echo ""
    echo -e "${BLUE}=== System Status ===${NC}"
    echo ""
    echo -e "OS:             ${CYAN}$OS_NAME${NC}"
    echo -e "OS ID:          $OS_ID $OS_VERSION_ID"
    echo -e "RHEL Major:     ${CYAN}$RHEL_MAJOR${NC}"
    echo -e "Kernel Version: ${CYAN}$KVERS${NC}"
    echo -e "Kernel Series:  $KERNEL_VERSION"
    
    # Secure Boot status
    if check_secure_boot; then
        echo -e "Secure Boot:    ${YELLOW}ENABLED${NC} (module signing required)"
    else
        echo -e "Secure Boot:    ${GREEN}DISABLED${NC}"
    fi
    
    # kernel-devel status
    if [ -n "$KERNEL_SRC_DIR" ] && [ -d "$KERNEL_SRC_DIR" ]; then
        echo -e "Kernel Devel:   ${GREEN}INSTALLED${NC}"
    else
        echo -e "Kernel Devel:   ${RED}NOT INSTALLED${NC}"
    fi
    
    # Driver SDK status
    if [ -d "$DRIVER_SDK_DIR" ]; then
        echo -e "Driver SDK:     ${GREEN}FOUND${NC}"
        if is_patches_applied; then
            echo -e "Source Patches: ${GREEN}APPLIED${NC}"
        else
            echo -e "Source Patches: ${YELLOW}NOT APPLIED${NC}"
        fi
        if is_mk_certs_patched; then
            echo -e "mk_certs Patch: ${GREEN}APPLIED${NC}"
        else
            echo -e "mk_certs Patch: ${YELLOW}NOT APPLIED${NC}"
        fi
    else
        echo -e "Driver SDK:     ${RED}NOT FOUND${NC}"
    fi
    
    # Built module status
    if [ -f "$SRC_DIR/rcraid.ko" ]; then
        echo -e "Built Module:   ${GREEN}FOUND${NC} ($SRC_DIR/rcraid.ko)"
        if is_module_signed "$SRC_DIR/rcraid.ko"; then
            echo -e "Module Signed:  ${GREEN}YES${NC}"
        else
            echo -e "Module Signed:  ${YELLOW}NO${NC}"
        fi
    else
        echo -e "Built Module:   ${YELLOW}NOT BUILT${NC}"
    fi
    
    # Installed module status
    local installed=$(find_installed_module)
    if [ -n "$installed" ]; then
        echo -e "Installed:      ${GREEN}YES${NC} ($installed)"
        if is_module_signed "$installed"; then
            echo -e "Inst. Signed:   ${GREEN}YES${NC}"
        else
            echo -e "Inst. Signed:   ${YELLOW}NO${NC}"
        fi
    else
        echo -e "Installed:      ${YELLOW}NO${NC}"
    fi
    
    # Module loaded status
    if lsmod | grep -q "^rcraid"; then
        echo -e "Module Loaded:  ${GREEN}YES${NC}"
    else
        echo -e "Module Loaded:  ${YELLOW}NO${NC}"
    fi
    
    # DKMS status
    if command -v dkms &> /dev/null; then
        if dkms status 2>/dev/null | grep -q "$DRIVER_NAME"; then
            echo -e "DKMS Status:    ${GREEN}CONFIGURED${NC}"
        else
            echo -e "DKMS Status:    ${YELLOW}NOT CONFIGURED${NC}"
        fi
    else
        echo -e "DKMS Status:    ${YELLOW}NOT INSTALLED${NC}"
    fi
    
    echo ""
}

#######################################
# Main Menu
#######################################

show_menu() {
    echo -e "${BLUE}=== Main Menu ===${NC}"
    echo ""
    echo "  --- Quick Install Options ---"
    echo "  1) Show system status"
    echo "  2) Full install (patch, build, sign, install, enroll)"
    echo "  3) Setup DKMS (auto-rebuild on kernel updates)"
    echo ""
    echo "  --- Individual Steps ---"
    echo "  4) Apply patches only"
    echo "  5) Build module only"
    echo "  6) Sign built module"
    echo "  7) Install built module"
    echo "  8) Sign installed module"
    echo "  9) Enroll MOK key"
    echo ""
    echo "  --- Utilities ---"
    echo " 10) Try loading module"
    echo " 11) Generate new signing key"
    echo " 12) Restore original source files"
    echo ""
    echo "  --- Distribution / RPM ---"
    echo " 13) Build RPM package"
    echo " 14) Build Driver Update Disk ISO (for fresh installs)"
    echo ""
    echo "  q) Quit"
    echo ""
}

main() {
    while true; do
        print_header
        show_system_status
        show_menu
        
        read -p "Select option: " choice
        echo ""
        
        case $choice in
            1)
                # Status already shown, just pause
                read -p "Press Enter to continue..."
                ;;
            2)
                full_install
                read -p "Press Enter to continue..."
                ;;
            3)
                setup_dkms
                read -p "Press Enter to continue..."
                ;;
            4)
                apply_patches
                read -p "Press Enter to continue..."
                ;;
            5)
                build_module
                read -p "Press Enter to continue..."
                ;;
            6)
                check_root && sign_module "$SRC_DIR/rcraid.ko"
                read -p "Press Enter to continue..."
                ;;
            7)
                install_module
                read -p "Press Enter to continue..."
                ;;
            8)
                sign_installed_module
                read -p "Press Enter to continue..."
                ;;
            9)
                enroll_mok_key
                read -p "Press Enter to continue..."
                ;;
            10)
                try_load_module
                read -p "Press Enter to continue..."
                ;;
            11)
                check_root && generate_signing_key
                read -p "Press Enter to continue..."
                ;;
            12)
                restore_original_files
                read -p "Press Enter to continue..."
                ;;
            13)
                build_driver_rpm
                read -p "Press Enter to continue..."
                ;;
            14)
                build_driver_iso
                read -p "Press Enter to continue..."
                ;;
            q|Q)
                echo "Goodbye!"
                exit 0
                ;;
            *)
                print_error "Invalid option: $choice"
                read -p "Press Enter to continue..."
                ;;
        esac
    done
}

# Run main if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
