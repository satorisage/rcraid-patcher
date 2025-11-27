# AMD rcraid Driver Patcher for RHEL/Alma Linux 9.6+

This repository contains tools to patch and install the AMD RAIDXpert2 (rcraid) driver on RHEL, AlmaLinux, Rocky Linux 9.6 and later, where the driver fails to compile due to kernel API changes.

## The Problem

AMD's official rcraid driver SDK (version 9.3.3) fails to compile on RHEL 9.6+ kernels due to:

1. **Removed `linux/genhd.h` header** - This header was merged into `linux/blkdev.h` in newer kernels, and RHEL 9.6+ backported this change.

2. **Removed block queue functions** - The functions `blk_queue_max_hw_sectors()` and `blk_queue_virt_boundary()` were removed/changed in the kernel's block layer.

3. **Bugs in `mk_certs`** - The AMD signing script has a typo (`-outform DEV` instead of `-outform DER`) and only includes Ubuntu paths, not RHEL paths.

## Repository Contents
```
.
├── README.md                 # This file
├── LICENSE                   # MIT license for scripts (see NOTICE.md for AMD software)
├── NOTICE.md                 # Important licensing info about AMD software
├── patch_and_install.sh      # Simple patcher - patches SDK then runs AMD installer
├── restore_originals.sh      # Restores original SDK files
├── rcraid_manager.sh         # Full-featured management tool with menu
├── check_setup.sh            # Verify prerequisites before installing
├── driver_sdk/               # AMD's original driver SDK
└── RAIDXpert2/               # AMD RAIDXpert2 management utility (optional)
```

## Quick Start

### Prerequisites
```bash
# Install required packages
sudo dnf install kernel-devel-$(uname -r) gcc make elfutils-libelf-devel openssl mokutil

# Verify everything is ready
./check_setup.sh
```

### Option 1: Simple Patch and Install (Recommended)

This patches the AMD SDK files and runs the original AMD installer:
```bash
sudo ./patch_and_install.sh
```

### Option 2: Full Management Tool

For more control, use the interactive manager:
```bash
sudo ./rcraid_manager.sh
```

The manager provides:
- System status display
- Full install (patch, build, sign, install, enroll MOK)
- DKMS setup for automatic rebuilds on kernel updates
- Individual steps (patch, build, sign, install separately)
- Sign already-installed modules
- Build RPM packages
- Build Driver Update Disk ISOs for fresh installations

## Secure Boot

If Secure Boot is enabled, the module must be signed and the signing key enrolled in MOK (Machine Owner Key).

### Automatic Handling

Both scripts handle Secure Boot automatically:
1. Generate a signing key
2. Sign the module
3. Prompt you to enroll the key with MOK

### MOK Enrollment Process

After running the installer, you'll be prompted to create a MOK password. On next reboot:

1. The MOK Manager (blue screen) will appear
2. Select **"Enroll MOK"**
3. Select **"Continue"**
4. Select **"Yes"**
5. Enter the password you created
6. Select **"Reboot"**

### Manual Signing (if needed)

If you installed via DKMS and the module won't load:
```bash
sudo ./rcraid_manager.sh
# Select option 8: "Sign installed module"
# Select option 9: "Enroll MOK key"
# Reboot and complete MOK enrollment
```

## Verifying Installation

After installation and reboot:
```bash
# Check if module is loaded
lsmod | grep rcraid

# Check for RAID devices
lsblk

# View driver messages
dmesg | grep -i rcraid
```

## DKMS Setup

For automatic rebuilds when you update your kernel:
```bash
sudo ./rcraid_manager.sh
# Select option 3: "Setup DKMS"
```

Or manually:
```bash
sudo ./patch_and_install.sh  # First install
# DKMS will be configured automatically on supported systems
```

## Building an RPM Package

To create an RPM for distribution or fresh installs:
```bash
sudo ./rcraid_manager.sh
# Select option 13: "Build RPM package"
```

The RPM will be created in your home directory.

## Driver Update Disk for Fresh Installs

To install RHEL/Alma on a system with AMD RAID where the installer doesn't see the disks:
```bash
sudo ./rcraid_manager.sh
# Select option 14: "Build Driver Update Disk ISO"
```

Then boot the installer with:
```
inst.dd=hd:LABEL=<usb-label>:/rcraid-9.3.3.00122-<kernel>.iso
```

Or interactively:
```
inst.dd
```

## Troubleshooting

### Module fails to load with "Key was rejected by service"

Secure Boot is blocking the unsigned module:
```bash
sudo ./rcraid_manager.sh
# Option 8: Sign installed module
# Option 9: Enroll MOK key
# Reboot and complete enrollment
```

### Build fails with "genhd.h: No such file or directory"

The patches weren't applied. Run:
```bash
./restore_originals.sh
sudo ./patch_and_install.sh
```

### Build fails with "blk_queue_max_hw_sectors" implicit declaration

Same as above - patches not applied correctly.

### RAID array not detected after successful install

1. Ensure the module is loaded: `lsmod | grep rcraid`
2. Check if AHCI is claiming the devices: `lsmod | grep ahci`
3. Try blacklisting AHCI:
```bash
   echo "blacklist ahci" | sudo tee /etc/modprobe.d/blacklist-ahci.conf
   sudo dracut -f
   sudo reboot
```

### "mokutil --import" fails

Ensure you have the signing key:
```bash
ls -la /var/lib/rccert/certs/
# or
ls -la driver_sdk/certs/
```

### Check setup script reports errors

Run the setup checker to diagnose issues:
```bash
./check_setup.sh
```

This will verify all prerequisites are met before you attempt installation.

## Tested Configurations

| Distribution | Kernel | Status |
|-------------|--------|--------|
| AlmaLinux 9.7 | 5.14.0-611.5.1.el9_7 | ✅ Working |
| AlmaLinux 9.6 | 5.14.0-570.x.el9_6 | ✅ Working |
| RHEL 9.6+ | 5.14.0-570+ | ✅ Working |
| Rocky Linux 9.6+ | 5.14.0-570+ | Should work (untested) |

## Technical Details

### Patches Applied

#### rc_config.c
```c
// Before (fails on RHEL 9.6+):
#if LINUX_VERSION_CODE < KERNEL_VERSION(5,14,0)
#include <linux/genhd.h>
#endif

// After (works on all versions):
#if LINUX_VERSION_CODE < KERNEL_VERSION(5,14,0) && !defined(RHEL_RELEASE_CODE)
#include <linux/genhd.h>
#elif defined(RHEL_RELEASE_CODE) && RHEL_RELEASE_CODE < RHEL_RELEASE_VERSION(9,6)
#include <linux/genhd.h>
#endif
#include <linux/blkdev.h>
```

#### rc_init.c
```c
// Before (removed functions):
blk_queue_max_hw_sectors(sdev->request_queue, 256);
blk_queue_virt_boundary(sdev->request_queue, NVME_CTRL_PAGE_SIZE - 1);

// After (version-aware):
#if defined(RHEL_RELEASE_CODE) && RHEL_RELEASE_CODE >= RHEL_RELEASE_VERSION(9,6)
    sdev->host->max_sectors = 256;
#else
    blk_queue_max_hw_sectors(sdev->request_queue, 256);
#endif
```

#### mk_certs
- Fixed typo: `-outform DEV` → `-outform DER`
- Added RHEL kernel paths: `/usr/src/kernels/$KVERS/scripts/sign-file`

## License & Legal

The patch scripts in this repository are licensed under the **MIT License** - see [LICENSE](LICENSE) for details.

**IMPORTANT:** This repository includes AMD's proprietary driver SDK and utilities. Please read [NOTICE.md](NOTICE.md) for important information about:
- AMD's software licensing terms
- Restrictions on redistribution
- Your obligations when using AMD's software

## Contributing

Issues and pull requests welcome! Please test on your specific configuration before submitting.

## Disclaimer

This is an unofficial community project. AMD does not support, endorse, or take any responsibility for these patches or tools.

The patches modify AMD's proprietary driver source code solely to fix compilation issues on newer kernels. No functional changes are made to the driver itself.

**USE AT YOUR OWN RISK.**

## Credits

- **AMD** - Original rcraid driver
- **Community contributors** - Identifying the kernel API changes and fixes
- Various rcraid-dkms projects for research and inspiration

## See Also

- [AMD RAID Driver Downloads](https://www.amd.com/en/support/chipsets/amd-socket-am4/x370)
- [rcraid-dkms (thopiekar)](https://github.com/thopiekar/rcraid-dkms)
- [rcraid-patches (martinkarlweber)](https://github.com/martinkarlweber/rcraid-patches)
