#!/bin/bash
# KaliPi — Strip desktop/GUI packages for headless operation
# Reclaims ~1-2GB on a stock Kali ARM image.
# Safe to run after setup.sh completes.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[-]${NC} Must run as root: sudo $0"
    exit 1
fi

log "Removing desktop environment and GUI packages..."

# XFCE desktop + display manager
apt purge -y kali-desktop-xfce xfce4* lightdm* 2>/dev/null || true

# Browsers
apt purge -y firefox-esr chromium* 2>/dev/null || true

# Office suite
apt purge -y libreoffice* 2>/dev/null || true

# X11 / Xorg display server
apt purge -y xorg* xserver* x11-* xterm 2>/dev/null || true

# Icon themes (large)
apt purge -y gnome-icon-theme adwaita-icon-theme* 2>/dev/null || true

# Other GUI apps unlikely to be needed headless
apt purge -y evince* atril* mousepad* ristretto* thunar* 2>/dev/null || true

log "Cleaning up orphaned dependencies..."
apt autoremove -y
apt clean

FREED=$(apt clean --dry-run 2>/dev/null | tail -1 || echo "check df -h")
log "Done. Run 'df -h /' to check reclaimed space."
