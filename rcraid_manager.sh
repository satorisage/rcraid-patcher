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
# EPEL and CRB Repository Setup
#######################################

# Check if CRB (CodeReady Builder) repo is enabled
is_crb_enabled() {
    # Check for various CRB repo names across distributions
    if dnf repolist enabled 2>/dev/null | grep -qiE "(crb|codeready|powertools)"; then
        return 0
    fi
    return 1
}

# Check if EPEL repo is enabled
is_epel_enabled() {
    if dnf repolist enabled 2>/dev/null | grep -qi "epel"; then
        return 0
    fi
    return 1
}

# Enable CRB repository
enable_crb_repo() {
    print_status "Enabling CRB (CodeReady Builder) repository..."
    
    # Try different methods based on distribution
    if [ "$OS_ID" = "rhel" ]; then
        # Official RHEL uses subscription-manager
        if command -v subscription-manager &> /dev/null; then
            subscription-manager repos --enable "codeready-builder-for-rhel-${RHEL_MAJOR}-$(arch)-rpms" 2>/dev/null && return 0
        fi
    fi
    
    # For AlmaLinux, Rocky, CentOS Stream - use dnf config-manager
    if command -v dnf &> /dev/null; then
        # Try 'crb' first (EL9+)
        dnf config-manager --set-enabled crb 2>/dev/null && return 0
        
        # Try 'powertools' (EL8)
        dnf config-manager --set-enabled powertools 2>/dev/null && return 0
        
        # Try with full repo name patterns
        local crb_repo=$(dnf repolist --all 2>/dev/null | grep -iE "crb|codeready|powertools" | awk '{print $1}' | head -1)
        if [ -n "$crb_repo" ]; then
            dnf config-manager --set-enabled "$crb_repo" 2>/dev/null && return 0
        fi
    fi
    
    print_warning "Could not automatically enable CRB repository"
    echo "You may need to enable it manually:"
    echo "  sudo dnf config-manager --set-enabled crb"
    echo "  # or for RHEL:"
    echo "  sudo subscription-manager repos --enable codeready-builder-for-rhel-${RHEL_MAJOR}-\$(arch)-rpms"
    return 1
}

# Install EPEL repository
install_epel_repo() {
    print_status "Installing EPEL repository..."
    
    # First ensure CRB is enabled (required for many EPEL packages)
    if ! is_crb_enabled; then
        enable_crb_repo
    fi
    
    # Determine EPEL URL based on RHEL version
    local epel_url=""
    if [ "$RHEL_MAJOR" -ge 10 ]; then
        epel_url="https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm"
    else
        epel_url="https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
    fi
    
    print_status "Installing from: $epel_url"
    
    if dnf install -y "$epel_url"; then
        print_status "EPEL repository installed successfully!"
        return 0
    else
        print_error "Failed to install EPEL repository"
        return 1
    fi
}

# Check and offer to install DKMS with EPEL if needed
check_and_install_dkms() {
    if command -v dkms &> /dev/null; then
        print_status "DKMS is already installed"
        return 0
    fi
    
    print_warning "DKMS is not installed"
    echo ""
    echo "DKMS (Dynamic Kernel Module Support) is required for automatic"
    echo "module rebuilding when you update your kernel."
    echo ""
    echo "DKMS is available from the EPEL repository."
    echo ""
    
    # Check current repo status
    local need_crb=0
    local need_epel=0
    
    if ! is_crb_enabled; then
        echo "  - CRB repository: NOT ENABLED (required for EPEL)"
        need_crb=1
    else
        echo "  - CRB repository: enabled"
    fi
    
    if ! is_epel_enabled; then
        echo "  - EPEL repository: NOT INSTALLED"
        need_epel=1
    else
        echo "  - EPEL repository: enabled"
    fi
    
    echo ""
    
    if [ $need_crb -eq 1 ] || [ $need_epel -eq 1 ]; then
        read -p "Install required repositories and DKMS? (Y/n): " install_choice
        if [ "$install_choice" = "n" ] || [ "$install_choice" = "N" ]; then
            print_warning "DKMS installation skipped"
            return 1
        fi
        
        # Enable CRB if needed
        if [ $need_crb -eq 1 ]; then
            enable_crb_repo || print_warning "CRB enable failed, continuing anyway..."
        fi
        
        # Install EPEL if needed
        if [ $need_epel -eq 1 ]; then
            install_epel_repo || {
                print_error "EPEL installation failed"
                return 1
            }
        fi
    else
        read -p "Install DKMS? (Y/n): " install_choice
        if [ "$install_choice" = "n" ] || [ "$install_choice" = "N" ]; then
            print_warning "DKMS installation skipped"
            return 1
        fi
    fi
    
    # Now install DKMS
    print_status "Installing DKMS..."
    if dnf install -y dkms; then
        print_status "DKMS installed successfully!"
        return 0
    else
        print_error "Failed to install DKMS"
        return 1
    fi
}

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
    # This includes weak-modules symlinks which point to modules built for other kernels
    local locations=(
        "/lib/modules/$KVERS/extra/rcraid.ko"
        "/lib/modules/$KVERS/extra/rcraid/rcraid.ko"
        "/lib/modules/$KVERS/extra/rcraid.ko.xz"
        "/lib/modules/$KVERS/extra/rcraid/rcraid.ko.xz"
        "/lib/modules/$KVERS/updates/rcraid.ko"
        "/lib/modules/$KVERS/updates/rcraid.ko.xz"
        "/lib/modules/$KVERS/weak-updates/rcraid.ko"
        "/lib/modules/$KVERS/weak-updates/rcraid/rcraid.ko"
    )
    
    for loc in "${locations[@]}"; do
        if [ -f "$loc" ] || [ -L "$loc" ]; then
            # If it's a symlink, resolve it to show the actual module
            if [ -L "$loc" ]; then
                local real_path=$(readlink -f "$loc")
                if [ -f "$real_path" ]; then
                    echo "$loc"
                    return 0
                fi
            else
                echo "$loc"
                return 0
            fi
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

# Find module info including weak-modules status
find_module_info() {
    local module_path=""
    local module_source=""
    local is_weak_module=0
    
    # Check weak-updates first (this is where symlinks from other kernels appear)
    local weak_locations=(
        "/lib/modules/$KVERS/weak-updates/rcraid.ko"
        "/lib/modules/$KVERS/weak-updates/rcraid/rcraid.ko"
    )
    
    for loc in "${weak_locations[@]}"; do
        if [ -L "$loc" ]; then
            local real_path=$(readlink -f "$loc")
            if [ -f "$real_path" ]; then
                module_path="$loc"
                module_source="$real_path"
                is_weak_module=1
                break
            fi
        fi
    done
    
    # If not found in weak-updates, check regular locations
    if [ -z "$module_path" ]; then
        local regular_locations=(
            "/lib/modules/$KVERS/extra/rcraid.ko"
            "/lib/modules/$KVERS/extra/rcraid/rcraid.ko"
            "/lib/modules/$KVERS/extra/rcraid.ko.xz"
            "/lib/modules/$KVERS/extra/rcraid/rcraid.ko.xz"
            "/lib/modules/$KVERS/updates/rcraid.ko"
            "/lib/modules/$KVERS/updates/rcraid.ko.xz"
        )
        
        for loc in "${regular_locations[@]}"; do
            if [ -f "$loc" ]; then
                module_path="$loc"
                module_source="$loc"
                break
            fi
        done
    fi
    
    # Output results
    if [ -n "$module_path" ]; then
        echo "path:$module_path"
        echo "source:$module_source"
        echo "weak:$is_weak_module"
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
    
    # Check and install DKMS if needed (handles EPEL/CRB setup)
    check_and_install_dkms || {
        print_error "DKMS is required for this operation"
        return 1
    }
    
    # Check if module is already installed and signed
    local existing_module=$(find_installed_module)
    local module_is_signed=0
    local preserve_module=0
    
    if [ -n "$existing_module" ] && [ -f "$existing_module" ]; then
        if is_module_signed "$existing_module"; then
            module_is_signed=1
            print_status "Found existing signed module: $existing_module"
            echo ""
            echo "The current module is already signed. DKMS normally rebuilds modules,"
            echo "which would invalidate the signature and require re-signing."
            echo ""
            echo "Options:"
            echo "  1. Preserve current signed module for this kernel, only rebuild for new kernels"
            echo "  2. Set up DKMS normally (will need to re-sign after any rebuild)"
            echo ""
            read -p "Preserve current signed module? (Y/n): " preserve_choice
            if [ "$preserve_choice" != "n" ] && [ "$preserve_choice" != "N" ]; then
                preserve_module=1
            fi
        fi
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
    
    # Check if we have signing keys
    local has_signing_key=0
    if [ -f "$CERT_DIR/module_signing_key.der" ] && [ -f "$CERT_DIR/module_signing_key.priv" ]; then
        has_signing_key=1
    fi
    
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

    # Add POST_BUILD signing hook if we have keys and Secure Boot is enabled
    if [ $has_signing_key -eq 1 ] && check_secure_boot; then
        print_status "Adding automatic signing hook to DKMS..."
        cat >> "$DKMS_DIR/dkms.conf" << DKMSCONF
# Automatic module signing for Secure Boot
POST_BUILD="sign_module.sh \${kernelver}"
DKMSCONF
        
        # Create the signing script
        cat > "$DKMS_DIR/sign_module.sh" << 'SIGNSCRIPT'
#!/bin/bash
# DKMS POST_BUILD hook for module signing
KVER="$1"
CERT_DIR="/var/lib/rccert/certs"
SIGN_TOOL="/usr/src/kernels/$KVER/scripts/sign-file"

if [ -f "$SIGN_TOOL" ] && [ -f "$CERT_DIR/module_signing_key.priv" ]; then
    MODULE_PATH="$(dirname $0)/rcraid.ko"
    if [ -f "$MODULE_PATH" ]; then
        "$SIGN_TOOL" sha512 \
            "$CERT_DIR/module_signing_key.priv" \
            "$CERT_DIR/module_signing_key.der" \
            "$MODULE_PATH"
        echo "Module signed for kernel $KVER"
    fi
fi
SIGNSCRIPT
        chmod +x "$DKMS_DIR/sign_module.sh"
    fi

    # Add to DKMS
    print_status "Adding module to DKMS..."
    dkms add -m "$DRIVER_NAME" -v "$DRIVER_VERSION"
    
    if [ $preserve_module -eq 1 ]; then
        # Use the existing signed module instead of rebuilding
        print_status "Preserving existing signed module for kernel $KVERS..."
        
        # Create the DKMS build directory structure
        local dkms_build_dir="/var/lib/dkms/$DRIVER_NAME/$DRIVER_VERSION/$KVERS/x86_64"
        mkdir -p "$dkms_build_dir/module"
        
        # Copy the existing module (decompress if needed)
        if [[ "$existing_module" == *.xz ]]; then
            xz -dk "$existing_module" -c > "$dkms_build_dir/module/rcraid.ko"
        else
            cp "$existing_module" "$dkms_build_dir/module/rcraid.ko"
        fi
        
        # Install (will use the preserved module)
        print_status "Installing preserved module..."
        dkms install -m "$DRIVER_NAME" -v "$DRIVER_VERSION" -k "$KVERS" --force 2>/dev/null || {
            # If that fails, manually ensure module is in place
            print_warning "Standard install failed, ensuring module is in place..."
            mkdir -p "/lib/modules/$KVERS/extra/$DRIVER_NAME"
            if [[ "$existing_module" == *.xz ]]; then
                xz -dk "$existing_module" -c > "/lib/modules/$KVERS/extra/$DRIVER_NAME/rcraid.ko"
            else
                cp "$existing_module" "/lib/modules/$KVERS/extra/$DRIVER_NAME/rcraid.ko"
            fi
            depmod -a "$KVERS"
        }
        
        print_status "Existing signed module preserved. Future kernel updates will"
        print_status "trigger rebuilds which will be auto-signed with your MOK key."
    else
        # Build normally
        print_status "Building module with DKMS..."
        dkms build -m "$DRIVER_NAME" -v "$DRIVER_VERSION"
        
        # Install
        print_status "Installing module with DKMS..."
        dkms install -m "$DRIVER_NAME" -v "$DRIVER_VERSION"
    fi
    
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
    
    # Signing guidance
    if check_secure_boot; then
        echo -e "${YELLOW}Secure Boot is enabled!${NC}"
        echo ""
        if [ $has_signing_key -eq 1 ]; then
            echo "Automatic signing is configured. New kernel builds will be signed"
            echo "automatically using your existing MOK key."
            if [ $preserve_module -eq 0 ]; then
                echo ""
                echo "The module was just rebuilt and needs to be signed."
                read -p "Sign the module now? (Y/n): " sign_now
                if [ "$sign_now" != "n" ] && [ "$sign_now" != "N" ]; then
                    sign_installed_module
                fi
            fi
        else
            echo "No signing key found. For Secure Boot systems, you need to:"
            echo "  1. Generate a signing key (menu option 11)"
            echo "  2. Sign the module (menu option 8)"
            echo "  3. Enroll the key in MOK (menu option 9)"
            echo ""
            read -p "Set up module signing now? (Y/n): " setup_signing
            if [ "$setup_signing" != "n" ] && [ "$setup_signing" != "N" ]; then
                generate_signing_key
                sign_installed_module
                enroll_mok_key
            fi
        fi
    fi
    
    return 0
}

#######################################
# RPM/ISO Build Functions (Dynamic!)
#######################################

# Global variable to track selected kernel for RPM/ISO builds
SELECTED_KERNEL=""

# List available kernels with kernel-devel installed
list_available_kernels() {
    local kernels=()
    local i=1
    
    # Find all kernel-devel installations
    for kdir in /usr/src/kernels/*/; do
        if [ -d "$kdir" ]; then
            local kver=$(basename "$kdir")
            kernels+=("$kver")
        fi
    done
    
    if [ ${#kernels[@]} -eq 0 ]; then
        print_error "No kernel-devel packages found!"
        echo "Install kernel-devel with: sudo dnf install kernel-devel"
        return 1
    fi
    
    echo ""
    echo -e "${BLUE}=== Available Kernels (with kernel-devel) ===${NC}"
    echo ""
    
    for kver in "${kernels[@]}"; do
        local marker=""
        if [ "$kver" = "$KVERS" ]; then
            marker="${GREEN}(current)${NC}"
        fi
        echo "  $i) $kver $marker"
        ((i++))
    done
    
    echo ""
    echo "  0) Enter custom kernel version"
    echo ""
    
    # Return kernels array via global
    AVAILABLE_KERNELS=("${kernels[@]}")
    return 0
}

# Prompt user to select a kernel version for RPM/ISO building
select_kernel_for_build() {
    list_available_kernels || return 1
    
    local num_kernels=${#AVAILABLE_KERNELS[@]}
    
    while true; do
        read -p "Select kernel to build for [1-$num_kernels, or 0 for custom] (default: current): " selection
        
        # Default to current kernel
        if [ -z "$selection" ]; then
            SELECTED_KERNEL="$KVERS"
            print_status "Using current kernel: $SELECTED_KERNEL"
            return 0
        fi
        
        # Custom kernel entry
        if [ "$selection" = "0" ]; then
            read -p "Enter kernel version (e.g., 5.14.0-503.14.1.el9_5.x86_64): " custom_kernel
            if [ -z "$custom_kernel" ]; then
                print_error "No kernel version entered"
                continue
            fi
            # Verify kernel-devel exists for this version
            if [ ! -d "/usr/src/kernels/$custom_kernel" ]; then
                print_warning "kernel-devel not found for $custom_kernel"
                read -p "Continue anyway? (y/N): " cont
                if [ "$cont" != "y" ] && [ "$cont" != "Y" ]; then
                    continue
                fi
            fi
            SELECTED_KERNEL="$custom_kernel"
            print_status "Using custom kernel: $SELECTED_KERNEL"
            return 0
        fi
        
        # Validate numeric selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "$num_kernels" ]; then
            SELECTED_KERNEL="${AVAILABLE_KERNELS[$((selection-1))]}"
            print_status "Selected kernel: $SELECTED_KERNEL"
            return 0
        fi
        
        print_error "Invalid selection. Please enter 1-$num_kernels or 0 for custom."
    done
}

build_driver_rpm() {
    print_status "Building Driver Update Disk RPM..."
    
    # Prompt for kernel selection
    echo ""
    echo -e "${CYAN}You can build the RPM for any kernel with kernel-devel installed.${NC}"
    echo -e "${CYAN}This allows creating driver disks for installation media that use${NC}"
    echo -e "${CYAN}a different kernel version than your running system.${NC}"
    echo ""
    
    select_kernel_for_build || return 1
    
    local TARGET_KVERS="$SELECTED_KERNEL"
    
    # DYNAMIC: Generate release string from target kernel version
    local RELEASE=$(echo "$TARGET_KVERS" | sed 's/-/./g')
    local ARCH="x86_64"
    local BUILD_ROOT="$HOME/rpmbuild"
    local MODULE_PATH=""
    
    # Detect RHEL version from target kernel
    local TARGET_RHEL_MAJOR="$RHEL_MAJOR"
    if [[ "$TARGET_KVERS" == 6.* ]]; then
        TARGET_RHEL_MAJOR=10
    elif [[ "$TARGET_KVERS" == 5.* ]]; then
        TARGET_RHEL_MAJOR=9
    fi
    
    # DYNAMIC: Detect OS info for RPM metadata
    local OS_SUMMARY=""
    local OS_DESC=""
    
    if [ "$TARGET_RHEL_MAJOR" -ge 10 ]; then
        OS_SUMMARY="AMD RAID driver for RHEL 10.x"
        OS_DESC="This package provides the rcraid kernel module built for Linux kernel $TARGET_KVERS (EL10) for the $ARCH family of processors."
    else
        OS_SUMMARY="AMD RAID driver for RHEL 9.x"
        OS_DESC="This package provides the rcraid kernel module built for Linux kernel $TARGET_KVERS (EL9) for the $ARCH family of processors."
    fi
    
    print_status "Building for: $OS_NAME"
    print_status "Target kernel: $TARGET_KVERS"
    print_status "Release tag: $RELEASE"
    
    # Check if we need to build a new module for this kernel
    local need_build=1
    
    # Check for existing module in various locations
    if [ -f "$SRC_DIR/rcraid.ko" ]; then
        # Verify the module was built for our target kernel
        local mod_vermagic=$(modinfo -F vermagic "$SRC_DIR/rcraid.ko" 2>/dev/null | awk '{print $1}')
        if [ "$mod_vermagic" = "$TARGET_KVERS" ]; then
            MODULE_PATH="$SRC_DIR/rcraid.ko"
            need_build=0
            print_status "Found existing module built for $TARGET_KVERS"
        fi
    fi
    
    # Check DKMS for pre-built module
    if [ $need_build -eq 1 ]; then
        local dkms_module="/var/lib/dkms/rcraid/$DRIVER_VERSION/$TARGET_KVERS/x86_64/module/rcraid.ko"
        if [ -f "$dkms_module" ]; then
            MODULE_PATH="$dkms_module"
            need_build=0
            print_status "Found DKMS module for $TARGET_KVERS"
        fi
    fi
    
    # Check installed modules
    if [ $need_build -eq 1 ]; then
        for ext in "" ".xz" ".gz"; do
            local installed_mod="/lib/modules/$TARGET_KVERS/extra/rcraid.ko$ext"
            if [ -f "$installed_mod" ]; then
                MODULE_PATH="$installed_mod"
                need_build=0
                print_status "Found installed module for $TARGET_KVERS"
                break
            fi
        done
    fi
    
    # Need to build a new module
    if [ $need_build -eq 1 ]; then
        print_warning "No pre-built module found for $TARGET_KVERS"
        
        # Check if kernel-devel is available for target
        if [ ! -d "/usr/src/kernels/$TARGET_KVERS" ]; then
            print_error "kernel-devel not installed for $TARGET_KVERS"
            echo "Install with: sudo dnf install kernel-devel-$TARGET_KVERS"
            return 1
        fi
        
        print_status "Building module for $TARGET_KVERS..."
        
        check_driver_sdk || return 1
        
        # Apply patches if needed
        if ! is_patches_applied; then
            apply_patches || return 1
        fi
        
        # Create symlink for binary blob
        cd "$SRC_DIR"
        if [ ! -e rcblob.x86_64.o ]; then
            ln -sf rcblob.x86_64 rcblob.x86_64.o
        fi
        cd - > /dev/null
        
        # Build for target kernel
        print_status "Compiling module for kernel $TARGET_KVERS..."
        make -C /usr/src/kernels/$TARGET_KVERS M="$SRC_DIR" modules
        
        if [ ! -f "$SRC_DIR/rcraid.ko" ]; then
            print_error "Build failed!"
            return 1
        fi
        
        MODULE_PATH="$SRC_DIR/rcraid.ko"
        print_status "Build successful!"
    fi
    
    print_status "Using module: $MODULE_PATH"
    
    # Handle compressed modules
    if [[ "$MODULE_PATH" == *.xz ]]; then
        print_status "Decompressing module..."
        xz -dk "$MODULE_PATH" -c > /tmp/rcraid.ko
        MODULE_PATH="/tmp/rcraid.ko"
    elif [[ "$MODULE_PATH" == *.gz ]]; then
        print_status "Decompressing module..."
        gzip -dk "$MODULE_PATH" -c > /tmp/rcraid.ko
        MODULE_PATH="/tmp/rcraid.ko"
    fi
    
    # Install build dependencies
    print_status "Installing build dependencies..."
    dnf install -y rpm-build rpmdevtools createrepo_c 2>/dev/null || true
    
    # Install ISO tools based on RHEL version
    if [ "$RHEL_MAJOR" -ge 10 ]; then
        dnf install -y xorriso 2>/dev/null || true
    else
        dnf install -y genisoimage 2>/dev/null || true
    fi
    
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
%define kernel_version ${TARGET_KVERS}

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
Target kernel: ${TARGET_KVERS}

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
- Target kernel: ${TARGET_KVERS}
- Patched for compatibility
SPEC

    # Build the RPM
    print_status "Building RPM..."
    rpmbuild -bb $BUILD_ROOT/SPECS/${DRIVER_NAME}.spec
    
    # Find the built RPM
    local RPM_FILE=$(find $BUILD_ROOT/RPMS -name "kmod-${DRIVER_NAME}*.rpm" | head -1)
    
    if [ -f "$RPM_FILE" ]; then
        print_status "RPM built successfully!"
        
        # Copy RPM to home directory with descriptive name
        local FINAL_RPM_NAME="kmod-rcraid-${DRIVER_VERSION}-${TARGET_KVERS}.rpm"
        cp "$RPM_FILE" "$HOME/$FINAL_RPM_NAME"
        
        echo ""
        print_status "RPM created: $HOME/$FINAL_RPM_NAME"
        echo ""
        echo "To install on an existing system:"
        echo "  sudo rpm -ivh $HOME/$FINAL_RPM_NAME"
        echo ""
        
        return 0
    else
        print_error "RPM build failed!"
        return 1
    fi
}

build_driver_iso() {
    print_status "Building Driver Update Disk ISO..."
    
    # First build the RPM (will prompt for kernel selection)
    build_driver_rpm || return 1
    
    local BUILD_ROOT="$HOME/rpmbuild"
    local RPM_FILE=$(find $BUILD_ROOT/RPMS -name "kmod-${DRIVER_NAME}*.rpm" | head -1)
    
    if [ ! -f "$RPM_FILE" ]; then
        print_error "RPM not found!"
        return 1
    fi
    
    # Install ISO creation tools based on RHEL version
    print_status "Installing ISO creation tools..."
    if [ "$RHEL_MAJOR" -ge 10 ]; then
        dnf install -y createrepo_c xorriso 2>/dev/null || true
    else
        dnf install -y createrepo_c genisoimage 2>/dev/null || true
    fi
    
    print_status "Creating Driver Update Disk ISO..."
    
    # Create DUD directory structure
    local DUD_DIR="/tmp/rcraid-dud"
    rm -rf $DUD_DIR
    mkdir -p $DUD_DIR/rpms/x86_64
    
    # Copy RPM
    cp "$RPM_FILE" $DUD_DIR/rpms/x86_64/
    
    # Create rhdd3 file (identifies this as a driver disk)
    echo -e "Driver Update Disk version 3\n" > $DUD_DIR/rhdd3
    
    # Create empty ks.cfg stub to prevent "can't find ks.cfg" warnings
    # Anaconda sometimes interprets the DUD drive as a kickstart source
    cat > $DUD_DIR/ks.cfg << 'KSCFG'
# Stub kickstart file for AMD rcraid Driver Update Disk
# This file exists to prevent "can't find ks.cfg" warnings during inst.dd
# It contains no actual kickstart configuration
KSCFG

    # Create post-install helper script for Secure Boot setup
    cat > $DUD_DIR/rcraid_post_install.sh << 'POSTINSTALL'
#!/bin/bash
#
# AMD rcraid Post-Installation Helper
# Run this after fresh install to set up DKMS and Secure Boot signing
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}  AMD rcraid Post-Installation Setup${NC}"
echo -e "${BLUE}=============================================${NC}"
echo ""

# Check for root
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root"
    echo "Usage: sudo $0"
    exit 1
fi

KVERS=$(uname -r)

# Check if Secure Boot is enabled
check_secure_boot() {
    if command -v mokutil &> /dev/null; then
        if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
            return 0
        fi
    fi
    return 1
}

# Check if module is loaded
if ! lsmod | grep -q "^rcraid"; then
    print_warning "rcraid module is not currently loaded"
    print_warning "If Secure Boot is enabled, you may need to disable it temporarily"
    print_warning "or enroll the module signing key before the driver will load."
fi

# Secure Boot handling
if check_secure_boot; then
    print_warning "Secure Boot is ENABLED"
    echo ""
    echo "The driver module from the installation ISO is not signed with your"
    echo "system's MOK (Machine Owner Key). You have several options:"
    echo ""
    echo "  1. Generate a signing key, sign the module, and enroll in MOK"
    echo "  2. Temporarily disable Secure Boot in BIOS/UEFI"
    echo "  3. Use the full rcraid_manager.sh tool for complete setup"
    echo ""
    read -p "Would you like to set up module signing now? (Y/n): " setup_signing
    
    if [ "$setup_signing" != "n" ] && [ "$setup_signing" != "N" ]; then
        # Generate signing key
        CERT_DIR="/var/lib/rccert/certs"
        mkdir -p "$CERT_DIR"
        chmod 700 "$CERT_DIR"
        
        if [ ! -f "$CERT_DIR/module_signing_key.der" ]; then
            print_status "Generating module signing key..."
            openssl req -new -x509 -newkey rsa:4096 \
                -keyout "$CERT_DIR/module_signing_key.priv" \
                -outform DER \
                -out "$CERT_DIR/module_signing_key.der" \
                -nodes -days 3650 \
                -subj "/CN=rcraid module signing key $(hostname)/"
            chmod 600 "$CERT_DIR/module_signing_key.priv"
        fi
        
        # Find and sign the module
        MODULE_PATH="/lib/modules/$KVERS/extra/rcraid/rcraid.ko"
        if [ ! -f "$MODULE_PATH" ]; then
            MODULE_PATH=$(find /lib/modules/$KVERS -name "rcraid.ko*" | head -1)
        fi
        
        if [ -n "$MODULE_PATH" ] && [ -f "$MODULE_PATH" ]; then
            # Handle compressed module
            if [[ "$MODULE_PATH" == *.xz ]]; then
                print_status "Decompressing module..."
                xz -d "$MODULE_PATH"
                MODULE_PATH="${MODULE_PATH%.xz}"
            fi
            
            # Sign the module
            SIGN_TOOL="/usr/src/kernels/$KVERS/scripts/sign-file"
            if [ -f "$SIGN_TOOL" ]; then
                print_status "Signing module..."
                "$SIGN_TOOL" sha512 \
                    "$CERT_DIR/module_signing_key.priv" \
                    "$CERT_DIR/module_signing_key.der" \
                    "$MODULE_PATH"
                print_status "Module signed successfully!"
            else
                print_error "sign-file tool not found. Install kernel-devel:"
                echo "  sudo dnf install kernel-devel-$KVERS"
            fi
        fi
        
        # Enroll MOK key
        print_status "Enrolling MOK key..."
        echo ""
        echo "You will be prompted to create a password."
        echo "Remember this password - you'll need it during the next reboot!"
        echo ""
        mokutil --import "$CERT_DIR/module_signing_key.der"
        
        echo ""
        print_status "MOK enrollment initiated!"
        echo ""
        echo -e "${YELLOW}IMPORTANT: You must reboot to complete enrollment!${NC}"
        echo ""
        echo "During reboot, the MOK Manager (blue screen) will appear."
        echo "  1. Select 'Enroll MOK'"
        echo "  2. Select 'Continue'"
        echo "  3. Select 'Yes'"
        echo "  4. Enter the password you just created"
        echo "  5. Select 'Reboot'"
    fi
else
    print_status "Secure Boot is DISABLED - no signing required"
fi

echo ""
print_status "Post-installation setup complete!"
echo ""
echo "For DKMS setup (auto-rebuild on kernel updates), use the full"
echo "rcraid_manager.sh tool from the rcraid-patcher repository."
echo ""
POSTINSTALL
    chmod +x $DUD_DIR/rcraid_post_install.sh
    
    # Create repo metadata
    cd $DUD_DIR/rpms/x86_64
    createrepo_c . 2>/dev/null || createrepo .
    cd - > /dev/null
    
    # Create ISO - use the target kernel version from RPM build
    local TARGET_KVERS="${SELECTED_KERNEL:-$KVERS}"
    local ISO_NAME="rcraid-${DRIVER_VERSION}-${TARGET_KVERS}.iso"
    local ISO_PATH="$HOME/$ISO_NAME"
    
    # OEMDRV is the magic label that Anaconda auto-detects for driver disks
    local VOLUME_LABEL="OEMDRV"
    
    print_status "Creating ISO with volume label: $VOLUME_LABEL"
    
    # Determine which ISO tool to use and create the ISO
    if command -v xorriso >/dev/null 2>&1; then
        # Use xorriso native syntax for cleaner output
        print_status "Using xorriso (native mode)..."
        xorriso -outdev "$ISO_PATH" \
            -volid "$VOLUME_LABEL" \
            -joliet on \
            -rockridge on \
            -map "$DUD_DIR" / \
            -commit
    elif command -v genisoimage >/dev/null 2>&1; then
        print_status "Using genisoimage..."
        genisoimage -o "$ISO_PATH" -R -J -V "$VOLUME_LABEL" "$DUD_DIR"
    elif command -v mkisofs >/dev/null 2>&1; then
        print_status "Using mkisofs..."
        mkisofs -o "$ISO_PATH" -R -J -V "$VOLUME_LABEL" "$DUD_DIR"
    else
        print_error "No ISO creation tool found!"
        if [ "$RHEL_MAJOR" -ge 10 ]; then
            echo "Please install xorriso: sudo dnf install xorriso"
        else
            echo "Please install genisoimage: sudo dnf install genisoimage"
        fi
        rm -rf $DUD_DIR
        return 1
    fi
    
    rm -rf $DUD_DIR
    
    if [ -f "$ISO_PATH" ]; then
        echo ""
        print_status "Driver Update Disk ISO created successfully!"
        echo ""
        echo -e "${BLUE}=============================================${NC}"
        echo -e "${BLUE}  Files created in $HOME/${NC}"
        echo -e "${BLUE}=============================================${NC}"
        echo ""
        echo "  - $(basename $RPM_FILE)"
        echo "  - $ISO_NAME (Volume Label: $VOLUME_LABEL)"
        echo ""
        echo -e "${BLUE}=== USAGE INSTRUCTIONS ===${NC}"
        echo ""
        echo -e "${GREEN}Method 1: Automatic detection (recommended)${NC}"
        echo "  The ISO is labeled 'OEMDRV' which Anaconda auto-detects."
        echo "  1. Write ISO to USB or make available via HTTP"
        echo "  2. Boot installer normally - driver loads automatically"
        echo ""
        echo -e "${GREEN}Method 2: Boot with inst.dd (explicit)${NC}"
        echo "  1. Copy ISO to USB drive"
        echo "  2. Boot installer"
        echo "  3. At boot menu, press Tab/e to edit"
        echo "  4. Add: inst.dd=hd:LABEL=OEMDRV:/$ISO_NAME"
        echo ""
        echo -e "${GREEN}Method 3: Interactive driver disk${NC}"
        echo "  1. Boot installer with: inst.dd"
        echo "  2. When prompted, select the drive with the ISO"
        echo ""
        echo -e "${GREEN}Method 4: HTTP server${NC}"
        echo "  1. Host ISO on web server"
        echo "  2. Boot with: inst.dd=http://server/$ISO_NAME"
        echo ""
        echo -e "${GREEN}Method 5: Install on existing system${NC}"
        echo "  sudo rpm -ivh $HOME/$(basename $RPM_FILE)"
        echo ""
        echo -e "${CYAN}=== SECURE BOOT NOTE ===${NC}"
        echo ""
        echo "The ISO includes 'rcraid_post_install.sh' to help with Secure Boot"
        echo "setup after a fresh installation. Mount the ISO and run:"
        echo "  sudo /path/to/mount/rcraid_post_install.sh"
        echo ""
        echo -e "${CYAN}Note: The ISO includes a stub ks.cfg file to prevent${NC}"
        echo -e "${CYAN}'can't find ks.cfg' warnings during installation.${NC}"
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
    
    # Installed module status with weak-modules detection
    local module_info=$(find_module_info)
    if [ -n "$module_info" ]; then
        local mod_path=$(echo "$module_info" | grep "^path:" | cut -d: -f2)
        local mod_source=$(echo "$module_info" | grep "^source:" | cut -d: -f2)
        local is_weak=$(echo "$module_info" | grep "^weak:" | cut -d: -f2)
        
        if [ "$is_weak" = "1" ]; then
            echo -e "Installed:      ${GREEN}YES${NC} (via weak-modules)"
            echo -e "  Symlink:      $mod_path"
            echo -e "  Source:       ${CYAN}$mod_source${NC}"
            # Get the kernel version this was built for
            local built_for=$(echo "$mod_source" | grep -oP '(?<=/lib/modules/)[^/]+')
            if [ -n "$built_for" ] && [ "$built_for" != "$KVERS" ]; then
                echo -e "  Built for:    ${YELLOW}$built_for${NC} (compatible with $KVERS)"
            fi
        else
            echo -e "Installed:      ${GREEN}YES${NC} ($mod_path)"
        fi
        
        if is_module_signed "$mod_source"; then
            echo -e "Inst. Signed:   ${GREEN}YES${NC}"
        else
            echo -e "Inst. Signed:   ${YELLOW}NO${NC}"
        fi
    else
        # Check if module is loaded even though we can't find the file
        if lsmod | grep -q "^rcraid"; then
            echo -e "Installed:      ${YELLOW}UNKNOWN${NC} (module loaded but file not found)"
        else
            echo -e "Installed:      ${YELLOW}NO${NC}"
        fi
    fi
    
    # Module loaded status
    if lsmod | grep -q "^rcraid"; then
        local mod_size=$(lsmod | grep "^rcraid" | awk '{print $2}')
        echo -e "Module Loaded:  ${GREEN}YES${NC} (size: ${mod_size})"
    else
        echo -e "Module Loaded:  ${YELLOW}NO${NC}"
    fi
    
    # DKMS status
    if command -v dkms &> /dev/null; then
        local dkms_status=$(dkms status 2>/dev/null | grep "$DRIVER_NAME")
        if [ -n "$dkms_status" ]; then
            echo -e "DKMS Status:    ${GREEN}CONFIGURED${NC}"
            # Show which kernels DKMS has built for
            local dkms_kernels=$(dkms status 2>/dev/null | grep "$DRIVER_NAME" | grep -oP '\d+\.\d+\.[^,]+' | tr '\n' ' ')
            if [ -n "$dkms_kernels" ]; then
                echo -e "  DKMS Kernels: $dkms_kernels"
            fi
        else
            echo -e "DKMS Status:    ${YELLOW}NOT CONFIGURED${NC}"
        fi
    else
        echo -e "DKMS Status:    ${YELLOW}NOT INSTALLED${NC}"
        if ! is_epel_enabled; then
            echo -e "  EPEL Repo:    ${YELLOW}NOT INSTALLED${NC} (required for DKMS)"
        fi
    fi
    
    # Available kernels for building
    local kernel_count=$(ls -d /usr/src/kernels/*/ 2>/dev/null | wc -l)
    if [ "$kernel_count" -gt 0 ]; then
        echo -e "Build Targets:  ${GREEN}$kernel_count kernel(s) available${NC}"
    else
        echo -e "Build Targets:  ${RED}NO kernel-devel installed${NC}"
    fi
    
    # ISO tools status
    if command -v xorriso &> /dev/null; then
        echo -e "ISO Tool:       ${GREEN}xorriso${NC}"
    elif command -v genisoimage &> /dev/null; then
        echo -e "ISO Tool:       ${GREEN}genisoimage${NC}"
    else
        echo -e "ISO Tool:       ${YELLOW}NOT INSTALLED${NC}"
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
