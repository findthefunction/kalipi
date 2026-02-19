#!/bin/bash
# KaliPi — Full provisioning script
# Run after first SSH login on a fresh Kali ARM install
# Usage: sudo ./scripts/setup.sh [TAILSCALE_AUTHKEY]

set -euo pipefail

TAILSCALE_AUTHKEY="${1:-}"
WIFI_SSID="TP-Link_A7FC"
WIFI_PSK="11511762"
HOSTNAME="kalipi"

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

# --- System Update ---
log "Updating system packages (barebones)..."
apt update && apt upgrade -y

log "Installing essential packages..."
apt install -y \
    git \
    curl \
    wget \
    vim \
    htop \
    tmux \
    net-tools \
    wireless-tools \
    wpasupplicant \
    raspi-config \
    python3 \
    python3-pip

apt autoremove -y
apt clean

# --- Hostname ---
log "Setting hostname to ${HOSTNAME}..."
hostnamectl set-hostname "$HOSTNAME"

# --- WiFi ---
log "Configuring WiFi (${WIFI_SSID})..."
cat > /etc/wpa_supplicant/wpa_supplicant.conf << EOF
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="${WIFI_SSID}"
    psk="${WIFI_PSK}"
    key_mgmt=WPA-PSK
}
EOF

cat > /etc/network/interfaces.d/wlan0 << EOF
auto wlan0
iface wlan0 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF

systemctl enable wpa_supplicant
systemctl restart wpa_supplicant || true

# --- SSH ---
log "Configuring SSH..."
systemctl enable ssh
systemctl start ssh

mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/hardened.conf << EOF
PermitRootLogin no
PasswordAuthentication yes
MaxAuthTries 5
ClientAliveInterval 120
ClientAliveCountMax 3
EOF

systemctl restart ssh

# --- Tailscale ---
log "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable tailscaled

if [ -n "$TAILSCALE_AUTHKEY" ]; then
    log "Authenticating Tailscale with provided auth key..."
    tailscale up --authkey="$TAILSCALE_AUTHKEY" --ssh
    log "Tailscale connected. IP: $(tailscale ip -4)"
else
    warn "No Tailscale auth key provided."
    warn "Run manually: sudo tailscale up --authkey=tskey-auth-XXXX --ssh"
    warn "Or interactive: sudo tailscale up --ssh"
fi

# --- Filesystem expansion ---
log "Checking filesystem size..."
ROOT_SIZE=$(df -BG / | tail -1 | awk '{print $2}' | tr -d 'G')
if [ "$ROOT_SIZE" -lt 100 ]; then
    warn "Root partition is ${ROOT_SIZE}GB — expanding to fill 128GB card..."
    raspi-config --expand-rootfs || {
        warn "raspi-config failed, trying manual expansion..."
        parted /dev/mmcblk0 resizepart 2 100% || true
        resize2fs /dev/mmcblk0p2 || true
    }
fi

# --- Done ---
log "============================================"
log "KaliPi provisioning complete!"
log "Hostname: ${HOSTNAME}"
log "WiFi:     ${WIFI_SSID}"
log "SSH:      enabled (port 22)"
if [ -n "$TAILSCALE_AUTHKEY" ]; then
    log "Tailscale: connected ($(tailscale ip -4))"
else
    log "Tailscale: installed (needs auth)"
fi
log "============================================"
log ""
log "Next steps:"
log "  1. Change default password: passwd"
log "  2. Set up LCD: sudo ./scripts/install-lcd.sh"
log "  3. Reboot: sudo reboot"
