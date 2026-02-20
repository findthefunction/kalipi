#!/bin/bash
# KaliPi — Full provisioning script
# Run after first SSH login on a fresh Kali ARM install.
# WiFi should already be working (configured by provision-sd.sh or manually).
# This script hardens the setup and installs Tailscale.
#
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

# ─── Verify WiFi is up before doing anything ──────────────────
log "Checking WiFi connectivity..."
if ip addr show wlan0 2>/dev/null | grep -q "inet "; then
    CURRENT_IP=$(ip -4 addr show wlan0 | grep inet | awk '{print $2}' | cut -d/ -f1)
    log "WiFi is up: ${CURRENT_IP}"
else
    warn "WiFi not connected! Attempting to connect..."

    # Detect network manager in use
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        log "Using NetworkManager..."
        nmcli device wifi rescan 2>/dev/null || true
        sleep 3
        nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PSK" ifname wlan0 || true
        sleep 5
    else
        log "Using wpa_supplicant..."
        mkdir -p /etc/wpa_supplicant
        cat > /etc/wpa_supplicant/wpa_supplicant.conf << EOF
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="${WIFI_SSID}"
    psk="${WIFI_PSK}"
    key_mgmt=WPA-PSK
    priority=1
}
EOF
        systemctl restart wpa_supplicant || true
        sleep 5

        # Get DHCP lease if needed
        if ! ip addr show wlan0 | grep -q "inet "; then
            dhclient wlan0 2>/dev/null || dhcpcd wlan0 2>/dev/null || true
            sleep 5
        fi
    fi

    # Final check
    if ip addr show wlan0 2>/dev/null | grep -q "inet "; then
        CURRENT_IP=$(ip -4 addr show wlan0 | grep inet | awk '{print $2}' | cut -d/ -f1)
        log "WiFi connected: ${CURRENT_IP}"
    else
        err "WiFi still not connected. Check wpa_supplicant or NM config."
        err "Continuing anyway — some steps may fail without internet."
    fi
fi

# ─── Test internet connectivity ───────────────────────────────
log "Testing internet connectivity..."
if ping -c 2 -W 5 8.8.8.8 &>/dev/null; then
    log "Internet reachable."
else
    warn "Cannot reach internet. apt operations may fail."
fi

# ─── System Update ────────────────────────────────────────────
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
    python3-pip \
    jq \
    inotify-tools

apt autoremove -y
apt clean

# ─── Hostname ─────────────────────────────────────────────────
log "Setting hostname to ${HOSTNAME}..."
hostnamectl set-hostname "$HOSTNAME"
# Update /etc/hosts
sed -i "s/127\.0\.1\.1.*/127.0.1.1\t${HOSTNAME}/" /etc/hosts 2>/dev/null || true
if ! grep -q "127.0.1.1" /etc/hosts; then
    echo "127.0.1.1	${HOSTNAME}" >> /etc/hosts
fi

# ─── Harden WiFi persistence ─────────────────────────────────
# Make sure WiFi survives reboots regardless of which network stack is in use
log "Ensuring WiFi persists across reboots..."

if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    log "NetworkManager detected — ensuring connection profile exists..."
    # Check if the connection already exists
    if ! nmcli connection show "$WIFI_SSID" &>/dev/null; then
        nmcli connection add type wifi ifname wlan0 con-name "$WIFI_SSID" \
            ssid "$WIFI_SSID" \
            wifi-sec.key-mgmt wpa-psk \
            wifi-sec.psk "$WIFI_PSK" \
            connection.autoconnect yes \
            connection.autoconnect-priority 100 2>/dev/null || true
    fi
    nmcli connection modify "$WIFI_SSID" connection.autoconnect yes 2>/dev/null || true
else
    log "wpa_supplicant mode — ensuring configs are in place..."
    mkdir -p /etc/wpa_supplicant
    # Only write if not already correctly configured
    if ! grep -q "$WIFI_SSID" /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null; then
        cat > /etc/wpa_supplicant/wpa_supplicant.conf << EOF
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="${WIFI_SSID}"
    psk="${WIFI_PSK}"
    key_mgmt=WPA-PSK
    priority=1
}
EOF
    fi

    mkdir -p /etc/network/interfaces.d
    cat > /etc/network/interfaces.d/wlan0 << EOF
auto wlan0
allow-hotplug wlan0
iface wlan0 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF

    systemctl enable wpa_supplicant
fi

# ─── SSH ──────────────────────────────────────────────────────
log "Configuring SSH..."

# Generate host keys if missing
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    log "Generating SSH host keys..."
    ssh-keygen -A
fi

# Enable both names (Kali uses ssh.service or sshd.service)
for SVC in ssh sshd; do
    systemctl enable "$SVC" 2>/dev/null || true
    systemctl start "$SVC" 2>/dev/null || true
done

mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/hardened.conf << EOF
PermitRootLogin no
PasswordAuthentication yes
MaxAuthTries 5
ClientAliveInterval 120
ClientAliveCountMax 3
EOF

# Restart whichever is running
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

# ─── Tailscale ────────────────────────────────────────────────
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

# ─── Filesystem expansion ────────────────────────────────────
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

# ─── Clean up first-boot service if it ran ────────────────────
systemctl disable kalipi-firstboot.service 2>/dev/null || true

# ─── Summary ─────────────────────────────────────────────────
echo ""
log "============================================"
log "KaliPi provisioning complete!"
log "============================================"
log "  Hostname:  ${HOSTNAME}"
log "  WiFi:      ${WIFI_SSID} ($(ip -4 addr show wlan0 2>/dev/null | grep inet | awk '{print $2}' || echo 'check status'))"
log "  SSH:       enabled (port 22)"
if [ -n "$TAILSCALE_AUTHKEY" ]; then
    log "  Tailscale: connected ($(tailscale ip -4 2>/dev/null || echo 'check status'))"
else
    log "  Tailscale: installed (run: sudo tailscale up --ssh)"
fi
log "============================================"
log ""
log "Next steps:"
log "  1. Change default password:    passwd"
log "  2. Install security stack:     sudo ./scripts/install-security.sh"
log "  3. Install LCD driver:         sudo ./scripts/install-lcd.sh 90"
log "  4. Reboot:                     sudo reboot"
