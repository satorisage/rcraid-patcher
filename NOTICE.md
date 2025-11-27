# Important Notice About AMD Software

## Downloading AMD Software

This repository is designed to work with AMD's official rcraid driver SDK. Due to licensing restrictions, you may need to download AMD's software directly from AMD.

### AMD RAID Driver SDK

Download from: https://www.amd.com/en/support/chipsets/amd-socket-am4/x370

1. Go to the AMD support page
2. Select your chipset (X370, X470, X570, etc.)
3. Download "AMD RAID Driver (SATA, NVMe RAID)" for Linux
4. Extract to the `driver_sdk` directory in this repository

### RAIDXpert2 Management Utility

The RAIDXpert2 utility is optional but useful for managing RAID arrays.

Download from the same AMD support page, look for "RAIDXpert2" or "AMD RAID Utility".

## License Compliance

If you fork or redistribute this repository:

1. **Do NOT include AMD's binaries** (rcblob.x86_64, RAIDXpert2 binaries) without ensuring you comply with AMD's license terms

2. **Consider providing download instructions** instead of including AMD's files

3. **The patch scripts (MIT licensed) can be freely distributed** - they don't contain any AMD code

## Alternative Repository Structure

If you want to distribute without AMD files:
```
rcraid-patcher/
├── README.md
├── LICENSE
├── NOTICE.md
├── patch_and_install.sh
├── restore_originals.sh
├── rcraid_manager.sh
├── .gitignore
└── driver_sdk/           # Empty - user downloads from AMD
    └── .gitkeep
```

Then instruct users to:
1. Download AMD SDK from AMD's website
2. Extract to the `driver_sdk` directory
3. Run the patcher
