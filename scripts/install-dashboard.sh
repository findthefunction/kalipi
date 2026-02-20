#!/bin/bash
# KaliPi — Install touchscreen dashboard and dependencies
# Installs pygame, minimal X11 components, and deploys the dashboard.
# Run AFTER install-lcd.sh (LCD driver must be installed first).
#
# Usage: sudo ./scripts/install-dashboard.sh

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

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="/opt/kalipi"
APPS_DIR="${INSTALL_DIR}/apps.d"

# ─── Verify LCD driver is installed ──────────────────────────
if [ ! -f /boot/overlays/tft35a.dtbo ] && [ ! -f /boot/overlays/tft35a-overlay.dtb ]; then
    warn "LCD driver overlay not found. Run install-lcd.sh first."
    warn "Continuing anyway — dashboard will work on HDMI for testing."
fi

# ─── Install system packages ────────────────────────────────
log "Installing dashboard dependencies..."
apt update

# Minimal X11 (needed for touch input via evdev and framebuffer rendering)
apt install -y \
    xserver-xorg-core \
    xserver-xorg-input-evdev \
    xserver-xorg-video-fbdev \
    xinit \
    x11-xserver-utils \
    x11-utils

# Python packages
apt install -y \
    python3-pygame \
    python3-dev

log "System packages installed."

# ─── Deploy dashboard to /opt/kalipi ─────────────────────────
log "Deploying dashboard to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
mkdir -p "${APPS_DIR}"

# Copy dashboard package
if [ -d "${REPO_DIR}/dashboard" ]; then
    cp -r "${REPO_DIR}/dashboard" "${INSTALL_DIR}/"
    log "Dashboard Python package deployed."
else
    err "Dashboard directory not found in ${REPO_DIR}"
    exit 1
fi

# Copy scripts (for the Apps view quick actions)
mkdir -p "${INSTALL_DIR}/scripts"
cp "${REPO_DIR}/scripts/security-check.sh" "${INSTALL_DIR}/scripts/"
cp "${REPO_DIR}/scripts/monitor-lcd.sh" "${INSTALL_DIR}/scripts/"
chmod +x "${INSTALL_DIR}/scripts/"*.sh

# ─── Deploy X11 config for SPI LCD + touch ───────────────────
# Only install if LCD35-show hasn't already set up xorg.conf.d.
# LCD35-show creates its own calibration and evdev configs — don't overwrite.
if [ ! -f /etc/X11/xorg.conf.d/99-calibration.conf ] && \
   [ ! -f /etc/X11/xorg.conf.d/45-evdev.conf ]; then
    log "No LCD35-show xorg config found, installing fallback..."
    mkdir -p /etc/X11/xorg.conf.d
    cp "${REPO_DIR}/config/xorg/99-kalipi-lcd.conf" /etc/X11/xorg.conf.d/
    cp "${REPO_DIR}/config/xorg/99-kalipi-touch.conf" /etc/X11/xorg.conf.d/
    log "Fallback X11 LCD and touch configs installed."
else
    log "LCD35-show xorg config found, skipping (not overwriting)."
fi

# ─── Create X11 startup wrapper ─────────────────────────────
log "Creating dashboard startup wrapper..."
cat > "${INSTALL_DIR}/start-dashboard.sh" << 'WRAPPER'
#!/bin/bash
# KaliPi Dashboard — X11 startup wrapper
# Starts a minimal X session on the SPI LCD and launches the dashboard.
# Used by the kalipi-dashboard.service systemd unit.

set -euo pipefail

INSTALL_DIR="/opt/kalipi"
FB_DEVICE="/dev/fb1"
LOG_FILE="/var/log/kalipi-dashboard.log"

# Determine which framebuffer to use
if [ -c "$FB_DEVICE" ]; then
    export FRAMEBUFFER="$FB_DEVICE"
else
    export FRAMEBUFFER="/dev/fb0"
    echo "$(date): WARNING - fb1 not found, falling back to fb0" >> "$LOG_FILE"
fi

# X11 server config for the SPI LCD
export DISPLAY=:0

# Check if X is already running
if ! xdpyinfo -display :0 >/dev/null 2>&1; then
    echo "$(date): Starting X server on ${FRAMEBUFFER}" >> "$LOG_FILE"

    # Start X on the LCD framebuffer with no cursor
    xinit /usr/bin/python3 -m dashboard.main -- :0 \
        -nocursor \
        -nolisten tcp \
        vt1 \
        2>> "$LOG_FILE" &

    sleep 2
else
    echo "$(date): X already running, starting dashboard" >> "$LOG_FILE"
    cd "${INSTALL_DIR}"
    exec python3 -m dashboard.main 2>> "$LOG_FILE"
fi

# Keep wrapper alive while xinit runs
wait
WRAPPER
chmod +x "${INSTALL_DIR}/start-dashboard.sh"

# ─── Create .xinitrc for the dashboard ───────────────────────
log "Creating .xinitrc..."
cat > "${INSTALL_DIR}/.xinitrc" << 'XINITRC'
#!/bin/sh
# KaliPi — Minimal X session for the dashboard
# No window manager, no desktop — just the pygame dashboard.

LOG="/var/log/kalipi-dashboard.log"

# Disable screen blanking and power management
xset s off
xset -dpms
xset s noblank

# Log actual X resolution for debugging
xdpyinfo | grep dimensions >> "$LOG" 2>&1 || true
xinput list >> "$LOG" 2>&1 || true

# Launch the dashboard
cd /opt/kalipi
exec python3 -m dashboard.main
XINITRC
chmod +x "${INSTALL_DIR}/.xinitrc"

# Update wrapper to use .xinitrc
cat > "${INSTALL_DIR}/start-dashboard.sh" << 'WRAPPER'
#!/bin/bash
# KaliPi Dashboard — X11 startup wrapper
# Starts a minimal X session on the SPI LCD and launches the dashboard.

set -euo pipefail

INSTALL_DIR="/opt/kalipi"
FB_DEVICE="/dev/fb1"
LOG_FILE="/var/log/kalipi-dashboard.log"

# Determine framebuffer
if [ -c "$FB_DEVICE" ]; then
    export FRAMEBUFFER="$FB_DEVICE"
    export SDL_FBDEV="$FB_DEVICE"
else
    export FRAMEBUFFER="/dev/fb0"
    export SDL_FBDEV="/dev/fb0"
    echo "$(date): WARNING - fb1 not found, falling back to fb0" >> "$LOG_FILE"
fi

cd "${INSTALL_DIR}"
echo "$(date): Starting dashboard on ${FRAMEBUFFER}" >> "$LOG_FILE"

# Kill any display manager or stale X server holding :0
if pidof Xorg >/dev/null 2>&1 || pidof X >/dev/null 2>&1; then
    echo "$(date): Killing stale X server..." >> "$LOG_FILE"
    killall Xorg 2>/dev/null || true
    killall X 2>/dev/null || true
    sleep 1
fi

# Start minimal X session with dashboard
# xinit reads .xinitrc from $HOME
export HOME="${INSTALL_DIR}"
exec xinit "${INSTALL_DIR}/.xinitrc" -- :0 \
    -nocursor \
    -nolisten tcp \
    vt1 \
    2>> "$LOG_FILE"
WRAPPER
chmod +x "${INSTALL_DIR}/start-dashboard.sh"

# ─── Disable display manager (login screen) ─────────────────
# The dashboard runs its own X session on the SPI LCD framebuffer.
# A display manager (LightDM/GDM/SDDM) would grab :0 and block xinit.
DM_SERVICE=$(systemctl get-default 2>/dev/null)
if [ "$DM_SERVICE" = "graphical.target" ]; then
    log "Switching default target to multi-user (no GUI login)..."
    systemctl set-default multi-user.target
fi

# Disable any active display manager
for dm in lightdm gdm3 gdm sddm lxdm xdm; do
    if systemctl is-enabled "${dm}.service" >/dev/null 2>&1; then
        log "Disabling ${dm} display manager..."
        systemctl disable "${dm}.service"
        systemctl stop "${dm}.service" 2>/dev/null || true
    fi
done

# ─── Install systemd service ─────────────────────────────────
log "Installing systemd service..."
cp "${REPO_DIR}/config/kalipi-dashboard.service" /etc/systemd/system/

# Disable old monitor service if present
systemctl disable kalipi-monitor.service 2>/dev/null || true
systemctl stop kalipi-monitor.service 2>/dev/null || true

systemctl daemon-reload
systemctl enable kalipi-dashboard.service

log "Dashboard service installed and enabled."

# ─── Summary ─────────────────────────────────────────────────
echo ""
log "============================================"
log "KaliPi Dashboard installed!"
log "============================================"
log "  Location:  ${INSTALL_DIR}/dashboard/"
log "  Service:   kalipi-dashboard.service"
log "  Wrapper:   ${INSTALL_DIR}/start-dashboard.sh"
log "  Apps dir:  ${APPS_DIR}/"
log "  Log:       /var/log/kalipi-dashboard.log"
log "============================================"
echo ""
log "Start now:     sudo systemctl start kalipi-dashboard"
log "View log:      journalctl -u kalipi-dashboard -f"
log ""
log "Add custom apps by placing JSON files in ${APPS_DIR}/"
log "See README.md for the app descriptor format."
