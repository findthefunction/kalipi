#!/bin/bash
# KaliPi — 3.5" SPI LCD driver installation
# Uses: https://github.com/findthefunction/LCD-show-kali
# WARNING: This script will reboot the system after installation.
# Usage: sudo ./scripts/install-lcd.sh [rotation]
#   rotation: 0 (default — X11 handles orientation), 90, 180, 270
#
# NOTE: The default is 0 (no LCD controller rotation). The X11 fbdev
# driver's "Rotate CW" option in 99-kalipi-lcd.conf handles landscape
# orientation. Using rotate=0 here avoids double-rotation issues.

set -euo pipefail

ROTATION="${1:-0}"
LCD_REPO="https://github.com/findthefunction/LCD-show-kali.git"
LCD_DIR="/home/kali/LCD-show-kali"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[-]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    err "Must run as root: sudo $0"
    exit 1
fi

# Validate rotation
case "$ROTATION" in
    0|90|180|270) ;;
    *)
        err "Invalid rotation: $ROTATION (must be 0, 90, 180, or 270)"
        exit 1
        ;;
esac

# Clone or update the LCD driver repo
if [ -d "$LCD_DIR" ]; then
    log "LCD driver repo already exists, pulling latest..."
    cd "$LCD_DIR"
    git pull || true
else
    log "Cloning LCD driver repo..."
    git clone "$LCD_REPO" "$LCD_DIR"
    cd "$LCD_DIR"
fi

# Make scripts executable
chmod +x LCD35-show
chmod +x system_backup.sh
[ -f rotate.sh ] && chmod +x rotate.sh

log "Installing 3.5\" SPI LCD driver (rotation: ${ROTATION})..."
warn "System will REBOOT after installation."
warn "Press Ctrl+C within 5 seconds to cancel..."
sleep 5

# Run the LCD installer
./LCD35-show "$ROTATION"

# Note: LCD35-show calls reboot, so we won't reach here
