#!/bin/bash
#
# Check if everything is set up correctly
#

echo "=== AMD rcraid Patcher Setup Check ==="
echo ""

ERRORS=0

# Check for driver_sdk
if [ -d "driver_sdk" ]; then
    echo "✓ driver_sdk directory found"
    
    if [ -f "driver_sdk/src/rc_init.c" ]; then
        echo "✓ Source files present"
    else
        echo "✗ Source files missing - extract AMD SDK to driver_sdk/"
        ERRORS=$((ERRORS+1))
    fi
    
    if [ -f "driver_sdk/src/rcblob.x86_64" ]; then
        echo "✓ Binary blob present"
    else
        echo "✗ Binary blob missing (rcblob.x86_64)"
        ERRORS=$((ERRORS+1))
    fi
else
    echo "✗ driver_sdk directory not found"
    echo "  Download AMD RAID driver from:"
    echo "  https://www.amd.com/en/support/chipsets/amd-socket-am4/x370"
    ERRORS=$((ERRORS+1))
fi

# Check for kernel-devel
KVERS=$(uname -r)
if [ -d "/usr/src/kernels/$KVERS" ]; then
    echo "✓ kernel-devel installed for $KVERS"
else
    echo "✗ kernel-devel not installed"
    echo "  Run: sudo dnf install kernel-devel-$KVERS"
    ERRORS=$((ERRORS+1))
fi

# Check for required tools
for cmd in gcc make openssl mokutil; do
    if command -v $cmd &> /dev/null; then
        echo "✓ $cmd found"
    else
        echo "✗ $cmd not found"
        ERRORS=$((ERRORS+1))
    fi
done

# Check Secure Boot status
if command -v mokutil &> /dev/null; then
    if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
        echo "! Secure Boot is ENABLED - module signing required"
    else
        echo "✓ Secure Boot is disabled"
    fi
fi

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "=== All checks passed! Ready to run: sudo ./patch_and_install.sh ==="
else
    echo "=== $ERRORS issue(s) found. Please resolve before continuing. ==="
fi
