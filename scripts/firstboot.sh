#!/bin/bash
# KaliPi first-boot — ensures WiFi + SSH are up on a headless Pi
# This runs once via systemd on first boot, then disables itself.
# It's a safety net: if static configs (wpa_supplicant, NM profile,
# interfaces.d) don't fully take effect, this script forces connection.

set -uo pipefail

WIFI_SSID="TP-Link_A7FC"
WIFI_PSK="11511762"
LOG="/var/log/kalipi-firstboot.log"

exec > "$LOG" 2>&1
echo "=== KaliPi first-boot: $(date) ==="

# ─── Wait for hardware init ──────────────────────────────────
echo "Waiting for hardware initialization..."
sleep 10

# ─── Unblock WiFi (rfkill can block wlan0 on some images) ────
if command -v rfkill &>/dev/null; then
    rfkill unblock wifi 2>/dev/null || true
    echo "WiFi unblocked via rfkill."
fi

# ─── Ensure wlan0 is up ──────────────────────────────────────
if ip link show wlan0 &>/dev/null; then
    if ! ip link show wlan0 | grep -q "UP"; then
        echo "Bringing up wlan0..."
        ip link set wlan0 up
        sleep 3
    fi
else
    echo "ERROR: wlan0 interface not found!"
    echo "Available interfaces:"
    ip link show
    echo "Checking for WiFi hardware..."
    lsmod | grep -i wifi || true
    iw dev 2>/dev/null || true
fi

# ─── Method 1: NetworkManager ────────────────────────────────
wifi_connected() {
    ip addr show wlan0 2>/dev/null | grep -q "inet "
}

if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo "NetworkManager is active."

    if ! wifi_connected; then
        echo "Attempting NM wifi connection..."
        nmcli device wifi rescan 2>/dev/null || true
        sleep 5

        # Try connecting with nmcli
        nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PSK" ifname wlan0 2>/dev/null || true
        sleep 8
    fi

    if wifi_connected; then
        echo "Connected via NetworkManager."
    else
        echo "NM connection failed, trying wpa_supplicant..."
    fi
fi

# ─── Method 2: wpa_supplicant + dhcp ─────────────────────────
if ! wifi_connected; then
    echo "Trying wpa_supplicant directly..."

    # Make sure wpa_supplicant config exists
    if [ ! -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
        echo "Creating wpa_supplicant.conf..."
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
    fi

    # Kill any existing wpa_supplicant for wlan0
    killall wpa_supplicant 2>/dev/null || true
    sleep 1

    # Start wpa_supplicant
    wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null || true
    sleep 8

    # Get IP via DHCP
    if command -v dhclient &>/dev/null; then
        dhclient -v wlan0 2>/dev/null || true
    elif command -v dhcpcd &>/dev/null; then
        dhcpcd wlan0 2>/dev/null || true
    fi
    sleep 5
fi

# ─── Method 3: systemd-networkd (some minimal images) ────────
if ! wifi_connected; then
    echo "Trying systemctl restart networking..."
    systemctl restart networking 2>/dev/null || true
    sleep 10
fi

# ─── Final WiFi status ───────────────────────────────────────
if wifi_connected; then
    WLAN_IP=$(ip -4 addr show wlan0 | grep inet | awk '{print $2}' | cut -d/ -f1)
    echo "WiFi CONNECTED! IP: $WLAN_IP"
else
    echo "=========================================="
    echo "WARNING: WiFi NOT connected after all methods."
    echo "=========================================="
    echo ""
    echo "Debug info:"
    echo "--- ip addr ---"
    ip addr
    echo "--- wpa_cli status ---"
    wpa_cli -i wlan0 status 2>/dev/null || echo "(wpa_cli unavailable)"
    echo "--- nmcli ---"
    nmcli device status 2>/dev/null || echo "(nmcli unavailable)"
    echo "--- dmesg wifi ---"
    dmesg | grep -i -E "wifi|wlan|brcm|firmware" | tail -20
    echo ""
    echo "You may need to connect a keyboard+monitor to debug."
fi

# ─── Ensure SSH is running ────────────────────────────────────
echo "Ensuring SSH is running..."
systemctl enable ssh 2>/dev/null || true
systemctl start ssh 2>/dev/null || true

if systemctl is-active --quiet ssh; then
    echo "SSH is active."
else
    echo "WARNING: SSH failed to start!"
    systemctl status ssh 2>/dev/null || true

    # Last resort: start sshd directly
    /usr/sbin/sshd 2>/dev/null || true
fi

# ─── Ensure wpa_supplicant persists across reboots ────────────
systemctl enable wpa_supplicant 2>/dev/null || true

# ─── Summary ─────────────────────────────────────────────────
echo ""
echo "=== First-boot summary ==="
echo "  Hostname: $(hostname)"
echo "  WiFi:     $(wifi_connected && echo 'connected' || echo 'FAILED')"
echo "  SSH:      $(systemctl is-active ssh 2>/dev/null || echo 'FAILED')"
echo "  wlan0 IP: $(ip -4 addr show wlan0 2>/dev/null | grep inet | awk '{print $2}' || echo 'none')"
echo "=== $(date) ==="

# ─── Disable this service (one-shot) ─────────────────────────
systemctl disable kalipi-firstboot.service 2>/dev/null || true
