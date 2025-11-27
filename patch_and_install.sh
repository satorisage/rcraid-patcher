#!/bin/bash
#
# AMD rcraid Driver SDK Patcher for RHEL/Alma 9.6+
# Patches the original AMD files and runs the installer
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER_SDK_DIR="$SCRIPT_DIR/driver_sdk"
SRC_DIR="$DRIVER_SDK_DIR/src"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}  AMD rcraid SDK Patcher for RHEL/Alma 9.6+${NC}"
echo -e "${BLUE}=============================================${NC}"
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
KVERS=$(uname -r)
if [ ! -d "/usr/src/kernels/$KVERS" ]; then
    print_error "kernel-devel not installed for $KVERS"
    echo "Installing kernel-devel..."
    dnf install -y kernel-devel-$KVERS || {
        print_error "Failed to install kernel-devel"
        exit 1
    }
fi

echo "Kernel: $KVERS"
echo ""

#######################################
# Backup original files
#######################################
print_status "Creating backups of original files..."

backup_file() {
    if [ -f "$1" ] && [ ! -f "$1.orig" ]; then
        cp "$1" "$1.orig"
        echo "  Backed up: $1"
    fi
}

backup_file "$SRC_DIR/rc_config.c"
backup_file "$SRC_DIR/rc_init.c"
backup_file "$DRIVER_SDK_DIR/mk_certs"

#######################################
# Patch rc_config.c - genhd.h fix
#######################################
print_status "Patching rc_config.c (genhd.h fix)..."

if grep -q "RHEL_RELEASE_VERSION(9,6)" "$SRC_DIR/rc_config.c" 2>/dev/null; then
    print_warning "rc_config.c already patched, skipping..."
else
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
        print_warning "Patch failed, applying manual fix..."
        cp rc_config.c.orig rc_config.c 2>/dev/null || true
        
        # Manual fix using sed
        sed -i '/#include <linux\/version.h>/,/^#include <linux\/sched.h>/{
            /#include <linux\/version.h>/b
            /#include <linux\/sched.h>/b
            d
        }' rc_config.c
        
        sed -i '/#include <linux\/version.h>/a\
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

#######################################
# Patch rc_init.c - blk_queue functions
#######################################
print_status "Patching rc_init.c (blk_queue functions fix)..."

if grep -q "RHEL_RELEASE_VERSION(9,6)" "$SRC_DIR/rc_init.c" 2>/dev/null; then
    print_warning "rc_init.c already patched, skipping..."
else
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

#######################################
# Patch mk_certs - Fix typo and add RHEL paths
#######################################
print_status "Patching mk_certs (DER typo and RHEL paths)..."

if grep -q "PATCHED_FOR_RHEL" "$DRIVER_SDK_DIR/mk_certs" 2>/dev/null; then
    print_warning "mk_certs already patched, skipping..."
else
    cd "$DRIVER_SDK_DIR"
    
    # Fix the -outform DEV typo -> DER
    if grep -q "\-outform DEV" mk_certs; then
        sed -i 's/-outform DEV/-outform DER/g' mk_certs
        echo "  Fixed -outform DEV -> DER typo"
    fi
    
    # Add RHEL kernel path for sign-file tool in the first location (around line 94)
    # We need to add the RHEL path before the Ubuntu path checks
    if ! grep -q "/usr/src/kernels/" mk_certs; then
        # Add RHEL path check before the Ubuntu checks in both locations
        sed -i 's|if \[ -f "/usr/src/linux-headers-\$KVERS/scripts/sign-file" \]; then|if [ -f "/usr/src/kernels/$KVERS/scripts/sign-file" ]; then\n\t\tSIGN_TOOL=/usr/src/kernels/$KVERS/scripts/sign-file\n\t    elif [ -f "/usr/src/linux-headers-$KVERS/scripts/sign-file" ]; then|g' mk_certs
        echo "  Added RHEL kernel paths for sign-file tool"
    fi
    
    # Add a marker so we know it's been patched
    sed -i '1a# PATCHED_FOR_RHEL - AMD rcraid patcher applied RHEL 9.6+ fixes' mk_certs
    
    cd - > /dev/null
    print_status "mk_certs patched successfully"
fi

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
# Run the original installer
#######################################
echo ""
echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}  All patches applied successfully!${NC}"
echo -e "${BLUE}=============================================${NC}"
echo ""
print_status "Running original AMD installer..."
echo ""

cd "$DRIVER_SDK_DIR"
exec ./install "$@"
