#!/bin/bash
# KaliPi — Strip desktop bloat while preserving LCD touchscreen support
# Removes XFCE, browsers, office suite, and GUI apps.
# KEEPS: minimal X11 server, touch input drivers, framebuffer driver.
# These are required by LCD-show-kali (touch calibration via xserver-xorg-input-evdev)
# and by the pygame dashboard (renders via SDL on X11).
#
# Reclaims ~1-2GB on a stock Kali ARM image.
# Safe to run after setup.sh and install-lcd.sh complete.

set -euo pipefail

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

# ─── Packages we MUST keep for LCD touchscreen ────────────────
# These are installed/configured by LCD35-show and required for
# touch input and framebuffer rendering:
#   xserver-xorg-core        — minimal X server
#   xserver-xorg-input-evdev — touch input driver (LCD35-show installs this)
#   xserver-xorg-video-fbturbo — framebuffer acceleration for SPI LCD
#   xserver-xorg-input-libinput — fallback input driver
#   x11-xserver-utils        — xrandr, xset (used by rotate.sh)
#   xinit                    — startx / xinit for launching X session
#   x11-utils                — xdpyinfo, xprop (diagnostics)

log "Stripping desktop bloat (preserving X11 core + touch drivers)..."

# ─── XFCE desktop environment + display manager ───────────────
log "Removing XFCE desktop and display manager..."
apt purge -y kali-desktop-xfce 2>/dev/null || true
apt purge -y xfce4 xfce4-* 2>/dev/null || true
apt purge -y lightdm lightdm-* 2>/dev/null || true

# ─── Browsers ─────────────────────────────────────────────────
log "Removing browsers..."
apt purge -y firefox-esr chromium chromium-* 2>/dev/null || true

# ─── Office suite ─────────────────────────────────────────────
log "Removing LibreOffice..."
apt purge -y libreoffice* 2>/dev/null || true

# ─── Icon and theme packs (large, unused headless) ────────────
log "Removing icon themes..."
apt purge -y gnome-icon-theme adwaita-icon-theme* 2>/dev/null || true
apt purge -y papirus-icon-theme* 2>/dev/null || true
apt purge -y kali-themes* 2>/dev/null || true

# ─── GUI apps we don't need ───────────────────────────────────
log "Removing unused GUI applications..."
apt purge -y \
    evince* atril* \
    mousepad* ristretto* \
    thunar* tumbler* \
    xfburn* parole* \
    synaptic* \
    gnome-terminal* \
    xterm \
    qterminal* \
    dbus-x11 2>/dev/null || true

# ─── GUI toolkits we don't need (pygame uses SDL, not GTK) ───
# Be careful here — only remove the heavy desktop toolkits
log "Removing desktop notification daemons..."
apt purge -y notification-daemon xfce4-notifyd 2>/dev/null || true

# ─── Verify critical packages are still present ──────────────
log "Verifying X11 core + touch packages..."
CRITICAL_PKGS="xserver-xorg-core xserver-xorg-input-evdev xinit"
MISSING=""
for pkg in $CRITICAL_PKGS; do
    if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        MISSING="$MISSING $pkg"
    fi
done

if [ -n "$MISSING" ]; then
    warn "Reinstalling critical packages removed by dependency chain:$MISSING"
    apt install -y $MISSING
fi

# Ensure framebuffer driver is present
if ! dpkg -l xserver-xorg-video-fbturbo 2>/dev/null | grep -q "^ii"; then
    log "Installing framebuffer driver..."
    apt install -y xserver-xorg-video-fbturbo 2>/dev/null || true
fi

# ─── Clean up ─────────────────────────────────────────────────
log "Cleaning up orphaned dependencies..."
apt autoremove -y
apt clean

# ─── Report ───────────────────────────────────────────────────
log "Done. Kept packages for LCD touchscreen:"
log "  xserver-xorg-core (X11 server)"
log "  xserver-xorg-input-evdev (touch input)"
log "  xserver-xorg-video-fbturbo (framebuffer)"
log "  xinit (session launcher)"
echo ""
log "Removed: XFCE, LightDM, Firefox, Chromium, LibreOffice, icon themes, GUI apps"
log "Run 'df -h /' to check reclaimed space."
