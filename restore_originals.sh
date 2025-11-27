#!/bin/bash
#
# Restore original AMD SDK files (undo patches)
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER_SDK_DIR="$SCRIPT_DIR/driver_sdk"
SRC_DIR="$DRIVER_SDK_DIR/src"

echo "Restoring original AMD SDK files..."

restore_file() {
    if [ -f "$1.orig" ]; then
        cp "$1.orig" "$1"
        echo "  Restored: $1"
    else
        echo "  No backup found for: $1"
    fi
}

restore_file "$SRC_DIR/rc_config.c"
restore_file "$SRC_DIR/rc_init.c"
restore_file "$DRIVER_SDK_DIR/mk_certs"

# Clean build artifacts
echo "Cleaning build artifacts..."
cd "$SRC_DIR"
make clean 2>/dev/null || rm -f *.o *.ko .*.cmd 2>/dev/null
cd - > /dev/null

echo "Done! Original files restored."
