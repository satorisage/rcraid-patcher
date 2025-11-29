#!/bin/bash
#
# AMD rcraid Driver SDK Patcher for RHEL 9.x and 10.x
# Patches the original AMD files and runs the installer
#
# Compatible with RHEL and derivatives (AlmaLinux, Rocky Linux, etc.)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER_SDK_DIR="$SCRIPT_DIR/driver_sdk"
SRC_DIR="$DRIVER_SDK_DIR/src"
KVERS=$(uname -r)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

#######################################
# OS/Kernel Version Detection
#######################################

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

get_os_name() {
    if [ -f /etc/redhat-release ]; then
        cat /etc/redhat-release
    elif [ -f /etc/os-release ]; then
        grep PRETTY_NAME /etc/os-release | cut -d'"' -f2
    else
        echo "Unknown"
    fi
}

RHEL_MAJOR=$(detect_rhel_version)
OS_NAME=$(get_os_name)

echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}  AMD rcraid SDK Patcher for RHEL 9.x/10.x${NC}"
echo -e "${BLUE}=============================================${NC}"
echo ""
echo "OS:      $OS_NAME"
echo "RHEL:    $RHEL_MAJOR"
echo "Kernel:  $KVERS"
echo ""

# Check for root
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root"
    echo "Usage: sudo $0"
    exit 1
fi

# Check for driver_sdk
if [ ! -d "$DRIVER_SDK_DIR" ]; then
    print_error "driver_sdk directory not found!"
    echo "Please extract the AMD RAID driver package first."
    echo "Expected location: $DRIVER_SDK_DIR"
    exit 1
fi

# Check kernel-devel is installed
if [ ! -d "/usr/src/kernels/$KVERS" ]; then
    print_error "kernel-devel not installed for $KVERS"
    echo "Installing kernel-devel..."
    dnf install -y kernel-devel-$KVERS || {
        print_error "Failed to install kernel-devel"
        exit 1
    }
fi

#######################################
# Backup original files
#######################################
print_status "Creating backups of original files..."

backup_file() {
    if [ -f "$1" ] && [ ! -f "$1.orig" ]; then
        cp "$1" "$1.orig"
        echo "  Backed up: $(basename $1)"
    fi
}

backup_file "$SRC_DIR/rc_config.c"
backup_file "$SRC_DIR/rc_init.c"
backup_file "$DRIVER_SDK_DIR/mk_certs"

#######################################
# RHEL 9.x Patches (kernel 5.14.x)
#######################################

apply_patches_el9() {
    print_status "Applying RHEL 9.x patches..."
    
    # Patch rc_config.c - genhd.h fix
    if grep -q "RHEL_RELEASE_VERSION(9,6)" "$SRC_DIR/rc_config.c" 2>/dev/null; then
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
        echo "  Patched rc_config.c"
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
        echo "  Patched rc_init.c"
    fi
}

#######################################
# RHEL 10.x Patches (kernel 6.12.x)
#######################################

apply_patches_el10() {
    print_status "Applying RHEL 10.x patches..."
    
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
    if grep -q 'blk_queue_max_hw_sectors' rc_init.c; then
        sed -i 's/blk_queue_max_hw_sectors(sdev->request_queue, \([^)]*\));/lim->max_hw_sectors = \1;/' rc_init.c
        echo "  Fixed blk_queue_max_hw_sectors -> lim->max_hw_sectors"
    fi
    
    # Handle the RHEL version conditional we may have added for EL9
    if grep -q '#if defined(RHEL_RELEASE_CODE) && RHEL_RELEASE_CODE >= RHEL_RELEASE_VERSION(9,6)' rc_init.c; then
        sed -i '/#if defined(RHEL_RELEASE_CODE) && RHEL_RELEASE_CODE >= RHEL_RELEASE_VERSION(9,6)/,/#endif/c\
        lim->max_hw_sectors = 256;' rc_init.c
        echo "  Converted EL9 conditional to EL10 queue_limits style"
    fi
    
    # Remove blk_queue_virt_boundary
    if grep -q 'blk_queue_virt_boundary' rc_init.c; then
        sed -i '/blk_queue_virt_boundary/d' rc_init.c
        echo "  Removed blk_queue_virt_boundary (handled differently in 6.12+)"
    fi
    
    # 4. Fix sysctl registration for kernel 6.12+
    if grep -q 'rcraid_sysctl_hdr = register_sysctl("rcraid", rcraid_table);' rc_init.c; then
        sed -i 's/rcraid_sysctl_hdr = register_sysctl("rcraid", rcraid_table);/rcraid_sysctl_hdr = register_sysctl_sz("rcraid", rcraid_table, ARRAY_SIZE(rcraid_table) - 1);/' rc_init.c
        echo "  Fixed sysctl registration for kernel 6.12+"
    else
        echo "  sysctl registration already fixed or not present"
    fi
    
    cd - > /dev/null
    print_status "RHEL 10.x patches applied"
}

#######################################
# Common Patches (mk_certs fix)
#######################################

patch_mk_certs() {
    print_status "Patching mk_certs..."
    
    local mk_certs_file="$DRIVER_SDK_DIR/mk_certs"
    
    if grep -q "PATCHED_FOR_RHEL" "$mk_certs_file" 2>/dev/null; then
        print_warning "mk_certs already patched, skipping..."
        return 0
    fi
    
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
    
    # Add marker
    sed -i '1a# PATCHED_FOR_RHEL - AMD rcraid patcher applied RHEL 9.x/10.x fixes' "$mk_certs_file"
    
    echo "  Patched mk_certs"
}

#######################################
# Apply appropriate patches
#######################################

print_status "Detected RHEL major version: $RHEL_MAJOR"

if [ "$RHEL_MAJOR" -ge 10 ]; then
    apply_patches_el10
else
    apply_patches_el9
fi

patch_mk_certs

#######################################
# Create symlink for binary blob
#######################################
print_status "Ensuring binary blob symlink exists..."
cd "$SRC_DIR"
if [ ! -e rcblob.x86_64.o ]; then
    ln -sf rcblob.x86_64 rcblob.x86_64.o
    echo "  Created symlink: rcblob.x86_64.o -> rcblob.x86_64"
fi
cd - > /dev/null

#######################################
# Run AMD installer
#######################################
echo ""
print_status "All patches applied successfully!"
echo ""
print_status "Running AMD installer..."
echo ""

cd "$DRIVER_SDK_DIR"
if [ -f "install" ]; then
    chmod +x install
    ./install
else
    print_error "AMD installer not found!"
    echo "You can manually build with: cd $SRC_DIR && make"
    exit 1
fi

echo ""
print_status "Installation complete!"
echo ""

# Check if module loaded
if lsmod | grep -q "^rcraid"; then
    echo -e "${GREEN}The rcraid module is loaded and ready!${NC}"
else
    echo -e "${YELLOW}The rcraid module is not currently loaded.${NC}"
    
    # Check for Secure Boot
    if check_secure_boot; then
        echo ""
        echo "Secure Boot is enabled. If the AMD installer prompted you to"
        echo "set a MOK enrollment password, you'll need to reboot and"
        echo "complete the enrollment in the MOK Manager (blue screen)."
    fi
    
    echo ""
    echo "You can try loading it manually with:"
    echo "  sudo modprobe rcraid"
fi

echo ""
echo "To verify installation:"
echo "  lsmod | grep rcraid"
echo "  dmesg | grep -i rcraid"
echo ""
echo "For DKMS setup (auto-rebuild on kernel updates), run:"
echo "  sudo ./rcraid_manager.sh  # Select option 3"
echo ""
