#!/bin/bash
# KaliPi — SD Card Pre-Boot Provisioning
# Run this ON YOUR WORKSTATION after flashing the Kali image to the SD card.
# It mounts the boot and root partitions and writes WiFi, SSH, and first-boot
# configs so the Pi comes up on the network automatically — no monitor needed.
#
# Usage: sudo ./scripts/provision-sd.sh /dev/sdX
#   where /dev/sdX is the SD card device (NOT a partition)
#
# What it does:
#   1. Mounts boot + rootfs partitions from the SD card
#   2. Drops wpa_supplicant.conf on boot partition (WiFi on first boot)
#   3. Creates empty /boot/ssh file (enables SSH on first boot)
#   4. Writes WiFi config directly into rootfs /etc/ (belt AND suspenders)
#   5. Enables SSH service in rootfs systemd
#   6. Installs a first-boot service that re-ensures WiFi + SSH
#   7. Unmounts cleanly

set -euo pipefail

WIFI_SSID="TP-Link_A7FC"
WIFI_PSK="11511762"
WIFI_COUNTRY="US"
HOSTNAME="kalipi"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[-]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    err "Must run as root: sudo $0 /dev/sdX"
    exit 1
fi

if [ $# -lt 1 ]; then
    err "Usage: sudo $0 /dev/sdX"
    err "  where /dev/sdX is the SD card device (e.g., /dev/sdb, /dev/mmcblk0)"
    exit 1
fi

DEVICE="$1"

# Safety check — don't nuke the system drive
# Detect the actual root device and refuse to operate on it
ROOT_DEVICE=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)
if [ -n "$ROOT_DEVICE" ] && [ "/dev/${ROOT_DEVICE}" = "$DEVICE" ]; then
    err "Refusing to operate on $DEVICE — this is your root filesystem device."
    exit 1
fi

# Also check if the device has any mounted partitions (other than what we'll mount)
MOUNTED_PARTS=$(lsblk -no MOUNTPOINT "$DEVICE" 2>/dev/null | grep -v "^$" || true)
if [ -n "$MOUNTED_PARTS" ]; then
    warn "Device $DEVICE has mounted partitions:"
    echo "$MOUNTED_PARTS"
    warn "Unmount them first or verify this is the correct device."
    read -rp "Continue anyway? (y/N): " CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        err "Aborted."
        exit 1
    fi
fi

if [ ! -b "$DEVICE" ]; then
    err "$DEVICE is not a block device."
    exit 1
fi

# Detect partition naming scheme (sdX1 vs mmcblk0p1)
if echo "$DEVICE" | grep -q "mmcblk\|nvme"; then
    PART1="${DEVICE}p1"
    PART2="${DEVICE}p2"
else
    PART1="${DEVICE}1"
    PART2="${DEVICE}2"
fi

if [ ! -b "$PART1" ] || [ ! -b "$PART2" ]; then
    err "Cannot find partitions $PART1 and $PART2"
    err "Make sure the Kali image has been flashed to $DEVICE first."
    exit 1
fi

MOUNT_BOOT=$(mktemp -d /tmp/kalipi-boot.XXXX)
MOUNT_ROOT=$(mktemp -d /tmp/kalipi-root.XXXX)

cleanup() {
    log "Cleaning up mounts..."
    umount "$MOUNT_BOOT" 2>/dev/null || true
    umount "$MOUNT_ROOT" 2>/dev/null || true
    rmdir "$MOUNT_BOOT" 2>/dev/null || true
    rmdir "$MOUNT_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

# ─── Mount partitions ─────────────────────────────────────────
log "Mounting $PART1 (boot) → $MOUNT_BOOT"
mount "$PART1" "$MOUNT_BOOT"

log "Mounting $PART2 (rootfs) → $MOUNT_ROOT"
mount "$PART2" "$MOUNT_ROOT"

# Verify this looks like a Kali/Pi image
if [ ! -f "$MOUNT_BOOT/config.txt" ]; then
    err "$MOUNT_BOOT/config.txt not found — is this a Raspberry Pi image?"
    exit 1
fi

# ─── 1. Enable SSH (boot partition) ──────────────────────────
log "Enabling SSH (creating /boot/ssh)..."
touch "$MOUNT_BOOT/ssh"

# ─── 2. WiFi on boot partition ───────────────────────────────
# Some Kali ARM images pick this up and move it to /etc on first boot
log "Writing wpa_supplicant.conf to boot partition..."
cat > "$MOUNT_BOOT/wpa_supplicant.conf" << EOF
country=${WIFI_COUNTRY}
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="${WIFI_SSID}"
    psk="${WIFI_PSK}"
    key_mgmt=WPA-PSK
    priority=1
}
EOF

# ─── 3. WiFi directly in rootfs (belt + suspenders) ──────────
# This guarantees WiFi config exists even if the boot-partition copy
# mechanism doesn't trigger (which varies by Kali ARM version)
log "Writing wpa_supplicant.conf directly to rootfs /etc/..."
mkdir -p "$MOUNT_ROOT/etc/wpa_supplicant"
cat > "$MOUNT_ROOT/etc/wpa_supplicant/wpa_supplicant.conf" << EOF
country=${WIFI_COUNTRY}
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="${WIFI_SSID}"
    psk="${WIFI_PSK}"
    key_mgmt=WPA-PSK
    priority=1
}
EOF

# ─── 4. Network interfaces config ────────────────────────────
log "Configuring wlan0 auto-connect in /etc/network/interfaces.d/..."
mkdir -p "$MOUNT_ROOT/etc/network/interfaces.d"
cat > "$MOUNT_ROOT/etc/network/interfaces.d/wlan0" << EOF
auto wlan0
allow-hotplug wlan0
iface wlan0 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF

# ─── 5. NetworkManager connection (covers NM-based Kali images) ──
# Newer Kali ARM images use NetworkManager instead of /etc/network/interfaces
log "Creating NetworkManager WiFi connection profile..."
mkdir -p "$MOUNT_ROOT/etc/NetworkManager/system-connections"
cat > "$MOUNT_ROOT/etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection" << EOF
[connection]
id=${WIFI_SSID}
type=wifi
autoconnect=true
autoconnect-priority=100

[wifi]
ssid=${WIFI_SSID}
mode=infrastructure

[wifi-security]
key-mgmt=wpa-psk
psk=${WIFI_PSK}

[ipv4]
method=auto

[ipv6]
method=auto
EOF
chmod 600 "$MOUNT_ROOT/etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection"

# ─── 6. Enable SSH in rootfs systemd ─────────────────────────
log "Enabling SSH service in rootfs..."
mkdir -p "$MOUNT_ROOT/etc/systemd/system/multi-user.target.wants"

# Kali uses either ssh.service or sshd.service depending on version — enable both
for SVC in ssh sshd; do
    if [ -f "$MOUNT_ROOT/lib/systemd/system/${SVC}.service" ]; then
        ln -sf "/lib/systemd/system/${SVC}.service" \
            "$MOUNT_ROOT/etc/systemd/system/multi-user.target.wants/${SVC}.service" 2>/dev/null || true
        log "  Enabled ${SVC}.service"
    fi
done

# Also ensure the sshd generates host keys on first boot
for KEYSVC in regenerate_ssh_host_keys ssh-keygen; do
    if [ -f "$MOUNT_ROOT/lib/systemd/system/${KEYSVC}.service" ]; then
        ln -sf "/lib/systemd/system/${KEYSVC}.service" \
            "$MOUNT_ROOT/etc/systemd/system/multi-user.target.wants/${KEYSVC}.service" 2>/dev/null || true
        log "  Enabled ${KEYSVC}.service"
    fi
done

# Pre-generate host keys if they don't exist (some images skip this)
if [ ! -f "$MOUNT_ROOT/etc/ssh/ssh_host_ed25519_key" ]; then
    log "Generating SSH host keys..."
    ssh-keygen -A -f "$MOUNT_ROOT" 2>/dev/null || true
fi

# Ensure SSH is configured to accept connections
if [ -f "$MOUNT_ROOT/etc/ssh/sshd_config" ]; then
    # Remove any "PermitRootLogin no" that might block initial login
    # (default Kali user is 'kali' not root, but just in case)
    if ! grep -q "^PermitRootLogin" "$MOUNT_ROOT/etc/ssh/sshd_config"; then
        echo "PermitRootLogin yes" >> "$MOUNT_ROOT/etc/ssh/sshd_config"
    fi
fi

# ─── 7. Set hostname ─────────────────────────────────────────
log "Setting hostname to '${HOSTNAME}'..."
echo "$HOSTNAME" > "$MOUNT_ROOT/etc/hostname"

# Update /etc/hosts
if [ -f "$MOUNT_ROOT/etc/hosts" ]; then
    sed -i "s/127\.0\.1\.1.*/127.0.1.1\t${HOSTNAME}/" "$MOUNT_ROOT/etc/hosts"
    # If no 127.0.1.1 line exists, add one
    if ! grep -q "127.0.1.1" "$MOUNT_ROOT/etc/hosts"; then
        echo "127.0.1.1	${HOSTNAME}" >> "$MOUNT_ROOT/etc/hosts"
    fi
fi

# ─── 8. First-boot safety net service ────────────────────────
# This runs once on first boot to ensure WiFi is up, even if
# the above static configs don't fully take effect
log "Installing first-boot service (WiFi safety net)..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Copy firstboot script
mkdir -p "$MOUNT_ROOT/opt/kalipi/scripts"
cp "$SCRIPT_DIR/firstboot.sh" "$MOUNT_ROOT/opt/kalipi/scripts/firstboot.sh" 2>/dev/null || \
cat > "$MOUNT_ROOT/opt/kalipi/scripts/firstboot.sh" << 'FBEOF'
#!/bin/bash
# KaliPi first-boot — ensures WiFi + SSH are up
# Runs once, then disables itself

LOG="/var/log/kalipi-firstboot.log"
exec > "$LOG" 2>&1
echo "=== KaliPi first-boot: $(date) ==="

# Wait for hardware to initialize
sleep 10

# Ensure wlan0 is up
if ! ip link show wlan0 | grep -q "UP"; then
    echo "Bringing up wlan0..."
    ip link set wlan0 up
    sleep 2
fi

# Try NetworkManager first
if systemctl is-active --quiet NetworkManager; then
    echo "NetworkManager is active, triggering WiFi connection..."
    nmcli device wifi rescan 2>/dev/null || true
    sleep 3
    nmcli device wifi connect "TP-Link_A7FC" password "11511762" 2>/dev/null || true
    sleep 5
fi

# Try wpa_supplicant if NM didn't connect
if ! ip addr show wlan0 | grep -q "inet "; then
    echo "No IP on wlan0, trying wpa_supplicant..."
    systemctl restart wpa_supplicant 2>/dev/null || true
    wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null || true
    sleep 5
    dhclient wlan0 2>/dev/null || dhcpcd wlan0 2>/dev/null || true
    sleep 5
fi

# Final check
if ip addr show wlan0 | grep -q "inet "; then
    WLAN_IP=$(ip -4 addr show wlan0 | grep inet | awk '{print $2}' | cut -d/ -f1)
    echo "WiFi connected! IP: $WLAN_IP"
else
    echo "WARNING: WiFi still not connected after all attempts."
    echo "Network interfaces:"
    ip addr
fi

# Ensure SSH is running
systemctl enable ssh 2>/dev/null || true
systemctl start ssh 2>/dev/null || true
echo "SSH status: $(systemctl is-active ssh)"

echo "=== First-boot complete ==="

# Disable this service — only run once
systemctl disable kalipi-firstboot.service 2>/dev/null || true
FBEOF
chmod +x "$MOUNT_ROOT/opt/kalipi/scripts/firstboot.sh"

# Install the systemd service
cat > "$MOUNT_ROOT/etc/systemd/system/kalipi-firstboot.service" << EOF
[Unit]
Description=KaliPi First Boot WiFi + SSH Setup
After=network-pre.target systemd-networkd.service NetworkManager.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/opt/kalipi/scripts/firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable the first-boot service
ln -sf /etc/systemd/system/kalipi-firstboot.service \
    "$MOUNT_ROOT/etc/systemd/system/multi-user.target.wants/kalipi-firstboot.service" 2>/dev/null || true

# ─── Sync and report ─────────────────────────────────────────
log "Syncing filesystem..."
sync

echo ""
log "============================================"
log "SD card provisioned successfully!"
log "============================================"
log ""
log "  Device:    $DEVICE"
log "  Hostname:  $HOSTNAME"
log "  WiFi SSID: $WIFI_SSID"
log "  SSH:       enabled"
log ""
log "  WiFi configured via:"
log "    - /boot/wpa_supplicant.conf (boot-time copy)"
log "    - /etc/wpa_supplicant/wpa_supplicant.conf (direct)"
log "    - /etc/NetworkManager/system-connections/ (NM profile)"
log "    - /etc/network/interfaces.d/wlan0 (ifupdown)"
log "    - First-boot service (safety net)"
log ""
log "  Insert SD card into Pi 4 and power on."
log "  Wait ~60 seconds, then:"
log "    ssh kali@${HOSTNAME}      (if mDNS works)"
log "    ssh kali@<IP_ADDRESS>     (find via router/nmap)"
log ""
log "  Default credentials: kali / kali"
log "============================================"
