# KaliPi — Headless Kali Linux on Raspberry Pi 4

Headless Kali Linux setup on a Raspberry Pi 4 (4GB/8GB) with a 128GB microSD card. Serves as auxiliary compute and a self-contained security node for a clawbot. Accessible over Tailscale SSH from a DigitalOcean server. Runs its own IDS, file integrity monitoring, and audit stack autonomously — no external SIEM dependency. Includes a 3.5" SPI LCD for real-time security/system monitoring.

---

## Table of Contents

1. [Hardware Requirements](#hardware-requirements)
2. [Download the Kali ARM Image](#download-the-kali-arm-image)
3. [Flash the SD Card](#flash-the-sd-card)
4. [Pre-Boot Configuration (Headless)](#pre-boot-configuration-headless)
5. [First Boot](#first-boot)
6. [System Update (Barebones)](#system-update-barebones)
7. [WiFi Configuration](#wifi-configuration)
8. [Enable and Configure SSH](#enable-and-configure-ssh)
9. [Install and Configure Tailscale](#install-and-configure-tailscale)
10. [Connect from DigitalOcean Server](#connect-from-digitalocean-server)
11. [Security Stack](#security-stack)
12. [LCD Screen Setup (3.5" SPI)](#lcd-screen-setup-35-spi)
13. [LCD Security Dashboard](#lcd-security-dashboard)
14. [Provisioning Scripts](#provisioning-scripts)
15. [Troubleshooting](#troubleshooting)

---

## Hardware Requirements

| Component | Spec |
|---|---|
| Board | Raspberry Pi 4 Model B (4GB or 8GB) |
| Storage | 128GB microSD (Class 10 / A2 recommended) |
| Display | 3.5" SPI TFT LCD (e.g., Waveshare/Goodtft) |
| Power | USB-C 5V/3A power supply |
| Network | Onboard WiFi (TP-Link_A7FC) |
| Access | Headless — SSH + Tailscale |

---

## Download the Kali ARM Image

Download the **64-bit** image (for 4GB/8GB Pi 4):

```bash
# From your workstation
wget https://kali.download/arm-images/kali-2025.1c/kali-linux-2025.1c-raspberry-pi-arm64.img.xz
```

Or visit: https://www.kali.org/get-kali/#kali-arm

> Use the **Raspberry Pi 2 (v1.2), 3, 4 and 400 (64-bit)** image.

Verify the download:
```bash
sha256sum kali-linux-2025.1c-raspberry-pi-arm64.img.xz
# Compare with the SHA256 checksum on the download page
```

---

## Flash the SD Card

### Option A: Using `dd` (Linux/macOS)

```bash
# Identify your SD card device (BE CAREFUL — wrong device = data loss)
lsblk

# Unmount any existing partitions
sudo umount /dev/sdX*

# Flash (replace /dev/sdX with your SD card device)
xzcat kali-linux-2025.1c-raspberry-pi-arm64.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
sudo sync
```

### Option B: Using Raspberry Pi Imager

1. Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Click **Choose OS** → **Use custom** → select the `.img.xz` file
3. Click **Choose Storage** → select your 128GB SD card
4. Click **Write**

> **Note:** Kali does NOT support the Raspberry Pi Imager "Advanced" menu for customization. Configuration is done manually below.

### Option C: Using balenaEtcher

1. Download [balenaEtcher](https://etcher.balena.io/)
2. Select the `.img.xz` file → select the SD card → Flash

---

## Pre-Boot Configuration (Headless)

After flashing, mount the SD card boot partition on your workstation to configure headless access.

### Enable SSH

```bash
# Mount the boot partition (it will show up as "boot" or the first partition)
# Create an empty ssh file to enable SSH on first boot
sudo touch /media/$USER/boot/ssh
```

### Configure WiFi (wpa_supplicant)

Create the WiFi configuration file:

```bash
sudo tee /media/$USER/boot/wpa_supplicant.conf << 'EOF'
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="TP-Link_A7FC"
    psk="11511762"
    key_mgmt=WPA-PSK
}
EOF
```

> This file is automatically moved to `/etc/wpa_supplicant/` on first boot.

### Unmount and eject

```bash
sudo sync
sudo umount /media/$USER/boot
sudo umount /media/$USER/rootfs  # if mounted
```

Insert the microSD into the Raspberry Pi 4 and power on.

---

## First Boot

**Default Kali credentials:**
- Username: `kali`
- Password: `kali`

### Find the Pi on your network

From another machine on the same WiFi network (TP-Link_A7FC):

```bash
# Option 1: nmap scan
sudo nmap -sn 192.168.0.0/24 | grep -B2 "Raspberry\|kali"

# Option 2: arp scan
sudo arp-scan --localnet | grep -i raspberry

# Option 3: Check your router's DHCP client list at the router admin page
```

### SSH in

```bash
ssh kali@<PI_IP_ADDRESS>
# Password: kali
```

### Change the default password immediately

```bash
passwd
```

### Expand filesystem to use full 128GB SD card

Kali ARM images usually auto-expand on first boot. Verify:

```bash
df -h /
```

If the root partition is not using the full card:

```bash
sudo raspi-config --expand-rootfs
sudo reboot
```

Or manually:

```bash
sudo parted /dev/mmcblk0 resizepart 2 100%
sudo resize2fs /dev/mmcblk0p2
```

---

## System Update (Barebones)

Minimal update — no desktop environment, no extras:

```bash
sudo apt update && sudo apt upgrade -y

# Install only essentials
sudo apt install -y \
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

# Clean up
sudo apt autoremove -y
sudo apt clean
```

---

## WiFi Configuration

If WiFi was not configured pre-boot or needs to be changed after boot:

### Using wpa_supplicant directly

```bash
# Edit the wpa_supplicant config
sudo tee /etc/wpa_supplicant/wpa_supplicant.conf << 'EOF'
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="TP-Link_A7FC"
    psk="11511762"
    key_mgmt=WPA-PSK
}
EOF

# Restart networking
sudo systemctl restart wpa_supplicant
sudo systemctl restart networking

# Verify connection
ip addr show wlan0
ping -c 3 8.8.8.8
```

### Using NetworkManager (if installed)

```bash
sudo nmcli device wifi connect "TP-Link_A7FC" password "11511762"
nmcli connection show
```

### Set WiFi to connect on boot

```bash
# Ensure wlan0 comes up automatically
sudo tee /etc/network/interfaces.d/wlan0 << 'EOF'
auto wlan0
iface wlan0 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF

sudo systemctl enable wpa_supplicant
```

---

## Enable and Configure SSH

SSH should already be enabled from the pre-boot step. Verify and harden:

```bash
# Ensure SSH is running and enabled on boot
sudo systemctl enable ssh
sudo systemctl start ssh
sudo systemctl status ssh

# Harden SSH config
sudo tee -a /etc/ssh/sshd_config.d/hardened.conf << 'EOF'
PermitRootLogin no
PasswordAuthentication yes
MaxAuthTries 5
ClientAliveInterval 120
ClientAliveCountMax 3
EOF

sudo systemctl restart ssh
```

### Set up SSH key authentication (from your workstation)

```bash
# On your workstation
ssh-keygen -t ed25519 -C "kalipi-access"
ssh-copy-id -i ~/.ssh/id_ed25519.pub kali@<PI_IP_ADDRESS>

# Then disable password auth if desired
# On the Pi: edit /etc/ssh/sshd_config.d/hardened.conf
# Change PasswordAuthentication to no
```

---

## Install and Configure Tailscale

Tailscale creates a WireGuard-based mesh VPN so the Pi is reachable from the DigitalOcean server (and any other Tailscale node) regardless of NAT or network topology.

### Install Tailscale

```bash
# Install using the official script
curl -fsSL https://tailscale.com/install.sh | sh

# Start Tailscale
sudo tailscale up
```

This will print a URL — open it in a browser to authenticate with your Tailscale account (Google/Microsoft/GitHub).

### Headless authentication (recommended)

Generate an auth key from the [Tailscale admin console](https://login.tailscale.com/admin/settings/keys):

1. Go to **Settings** → **Keys** → **Generate auth key**
2. Options:
   - **Reusable**: No (single use for this device)
   - **Ephemeral**: No (persistent device)
   - **Pre-approved**: Yes (skip manual approval)

```bash
sudo tailscale up --authkey=tskey-auth-XXXXXXXXXXXX --ssh
```

The `--ssh` flag enables Tailscale SSH, allowing SSH access over Tailscale without managing SSH keys separately.

### Enable Tailscale on boot

```bash
sudo systemctl enable tailscaled
```

### Verify Tailscale status

```bash
tailscale status
tailscale ip -4    # Get the Tailscale IP (100.x.x.x)
```

### Set hostname for easy access

```bash
sudo hostnamectl set-hostname kalipi
# The device will appear as "kalipi" in your Tailscale network
```

---

## Connect from DigitalOcean Server

### Install Tailscale on the DigitalOcean droplet

```bash
# On the DigitalOcean server
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --authkey=tskey-auth-XXXXXXXXXXXX --ssh
```

### SSH from DigitalOcean to the Pi

```bash
# Using Tailscale hostname
ssh kali@kalipi

# Or using Tailscale IP
ssh kali@100.x.x.x

# Using Tailscale SSH (no key management needed)
# Just works if --ssh was passed to tailscale up on both sides
```

### Verify connectivity

```bash
# From DigitalOcean server
tailscale ping kalipi
```

---

## Security Stack

The Pi runs a self-contained security stack — no external SIEM or heavy services required. The DigitalOcean droplet stays free for running the clawbot instance, and the laptop can SSH in to review reports when available.

### Why not full Kali Purple?

Kali Purple bundles Elasticsearch, Malcolm, TheHive, etc. These need 8GB+ RAM and amd64 architecture. The Pi 4 can't run the full stack, and the DO droplet is already occupied. Instead, we run the ARM-native tools that give the same coverage at a fraction of the resource cost.

### Install the security stack

```bash
sudo ./scripts/install-security.sh
```

### What gets installed

| Tool | Purpose | RAM |
|---|---|---|
| **fail2ban** | Blocks brute-force attacks on SSH and services | ~15MB |
| **auditd** | Kernel-level audit logging (file access, privilege escalation, module loading) | ~10MB |
| **rkhunter** | Rootkit detection — runs daily via cron | on-demand |
| **chkrootkit** | Secondary rootkit scanner | on-demand |
| **Lynis** | Security auditing and hardening recommendations | on-demand |
| **Suricata** | Network IDS — inspects traffic on wlan0 for attack signatures | ~200-400MB |
| **arpwatch** | Detects new/rogue devices joining the local network | ~5MB |
| **Wazuh Agent** | File integrity monitoring, log analysis, rootkit detection (local mode) | ~60MB |

Total persistent RAM overhead: **~300-500MB** (fits comfortably on 4GB Pi)

### What it monitors

**Self-monitoring (the Pi watches itself):**
- File integrity on `/etc`, `/boot`, `/usr/bin`, `/usr/sbin`, SSH keys, Tailscale state
- Rootkit detection (rkhunter daily cron + Wazuh real-time)
- Failed SSH attempts → auto-ban via fail2ban (3 strikes → 2hr ban, repeat → 24hr, recidive → 1 week)
- Kernel audit log: privilege escalation, module loading, cron changes, network config changes
- Suricata IDS on wlan0 with daily rule updates

**Network monitoring (devices connected via WiFi/Tailscale):**
- arpwatch detects new MAC addresses joining the local network
- Suricata inspects all traffic flowing through the Pi's interface
- Scheduled nmap scans of the local subnet (via `security-check.sh --devices`)
- Diff-based alerting: new devices, new SUID binaries, new users, changed authorized_keys

### Automated security checks

A cron job runs `security-check.sh` every 6 hours:

```bash
# Manual run
sudo ./scripts/security-check.sh

# With network device scan
sudo ./scripts/security-check.sh --devices

# View the latest report
cat /var/log/kalipi-security.log
```

The check outputs a JSON status file to `/tmp/kalipi/security-status.json` that the LCD dashboard reads.

### fail2ban jails

| Jail | Trigger | Ban time |
|---|---|---|
| `sshd` | 3 failed logins in 10min | 2 hours |
| `sshd-aggressive` | 2 failures in 1hr | 24 hours |
| `recidive` | 3 bans in 24hr | 1 week |

Tailscale IPs (100.64.0.0/10) and localhost are whitelisted.

### Audit rules (auditd)

Monitors for changes to:
- `/etc/ssh/`, `/home/kali/.ssh/` — SSH config & keys
- `/etc/passwd`, `/etc/shadow`, `/etc/sudoers` — identity files
- `/etc/crontab`, `/var/spool/cron/` — scheduled tasks
- `/etc/systemd/`, `/lib/systemd/` — service definitions
- `/boot/config.txt`, `/boot/cmdline.txt` — Pi boot config
- `/var/lib/tailscale/` — Tailscale state
- Kernel module loading (`insmod`, `rmmod`, `modprobe`)
- Any process run as root by a non-root user (privilege escalation)

Rules are locked (immutable) after load — requires reboot to modify.

### Suricata IDS

Tuned for Pi 4 resource constraints:

```
Stream memcap:      32MB
Reassembly memcap:  64MB
Flow memcap:        32MB
Detection profile:  low
```

Logs to `/var/log/suricata/eve.json` (JSON) and `/var/log/suricata/fast.log` (text). Rules auto-update daily at 3am via `suricata-update`.

### Log locations

| Log | Path |
|---|---|
| Security check reports | `/var/log/kalipi-security.log` |
| Security baselines | `/var/log/kalipi-reports/` |
| fail2ban | `/var/log/fail2ban.log` |
| Kernel audit | `/var/log/audit/audit.log` |
| Suricata alerts (JSON) | `/var/log/suricata/eve.json` |
| Suricata alerts (text) | `/var/log/suricata/fast.log` |
| rkhunter (daily) | `/var/log/rkhunter-daily.log` |
| Wazuh/OSSEC alerts | `/var/ossec/logs/alerts/alerts.log` |
| LCD status (JSON) | `/tmp/kalipi/security-status.json` |

### Review from laptop (when connected)

```bash
# SSH in via Tailscale
ssh kali@kalipi

# Quick status
sudo ./scripts/security-check.sh

# Review Suricata alerts
sudo jq 'select(.event_type=="alert")' /var/log/suricata/eve.json | tail -50

# Run a full Lynis audit
sudo lynis audit system

# Check audit log for privilege escalation
sudo ausearch -k privilege_exec --interpret
```

---

## LCD Screen Setup (3.5" SPI)

Uses the [LCD-show-kali](https://github.com/findthefunction/LCD-show-kali) driver package.

### Install the LCD driver

```bash
# Clone the LCD driver repo
cd /home/kali
git clone https://github.com/findthefunction/LCD-show-kali.git
cd LCD-show-kali

# Make scripts executable
chmod +x LCD35-show
chmod +x system_backup.sh
chmod +x rotate.sh

# Run the installer (this will reboot the Pi)
sudo ./LCD35-show
```

### What the LCD35-show script does

1. Backs up current system config
2. Installs the `tft35a` device tree overlay to `/boot/overlays/`
3. Configures `/boot/config.txt` with:
   - `hdmi_force_hotplug=1`
   - `dtparam=i2c_arm=on`
   - `dtparam=spi=on`
   - `enable_uart=1`
   - `dtoverlay=tft35a:rotate=90`
4. Sets up X11 calibration and framebuffer config
5. Installs `xserver-xorg-input-evdev` for touch support
6. Reboots

### After reboot

The LCD should display the console output. To rotate the display:

```bash
cd /home/kali/LCD-show-kali
sudo ./rotate.sh 90   # 0, 90, 180, 270
```

---

## LCD Security Dashboard

After the LCD driver is installed, deploy the security monitoring dashboard:

### Install the dashboard service

```bash
# Copy scripts and service to system paths
sudo cp scripts/monitor-lcd.sh /opt/kalipi/scripts/
sudo cp scripts/security-check.sh /opt/kalipi/scripts/
sudo chmod +x /opt/kalipi/scripts/*.sh

# Install the systemd service
sudo cp config/kalipi-monitor.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable kalipi-monitor
sudo systemctl start kalipi-monitor
```

### What the LCD shows

```
 ╔═══════════════════════════════════╗
 ║         K A L I P i               ║
 ║     Security Monitor  14:32:07   ║
 ╠═══════════════════════════════════╣
 ║ SYSTEM                           ║
 ║  CPU: 12%  Temp: 52°C            ║
 ║  RAM: 487/3904MB (12%)           ║
 ║  DSK: 8.2G/118G (7%)            ║
 ║  Up:  2 days, 14 hours           ║
 ╠═══════════════════════════════════╣
 ║ NETWORK                          ║
 ║  WiFi: 192.168.0.105             ║
 ║  T.S.: 100.64.0.12 (Running)    ║
 ╠═══════════════════════════════════╣
 ║ SERVICES                         ║
 ║  ssh:active ts:active f2b:active ║
 ╠═══════════════════════════════════╣
 ║ SECURITY                         ║
 ║  Alerts: 0  Banned: 2            ║
 ║  Failed SSH: 7 (6hr)             ║
 ║  Last check: 2026-02-19_14:00    ║
 ╚═══════════════════════════════════╝
```

Refreshes every 10 seconds. Reads security data from the last `security-check.sh` run and live system stats.

---

## Provisioning Scripts

This repo includes helper scripts to automate the post-boot setup:

### `scripts/setup.sh` — Full provisioning (system, WiFi, SSH, Tailscale)

```bash
git clone https://github.com/findthefunction/kalipi.git /home/kali/kalipi
cd /home/kali/kalipi
chmod +x scripts/*.sh
sudo ./scripts/setup.sh [TAILSCALE_AUTHKEY]
```

### `scripts/install-security.sh` — Security stack

```bash
sudo ./scripts/install-security.sh
```

### `scripts/install-tailscale.sh` — Tailscale only

```bash
sudo ./scripts/install-tailscale.sh [AUTHKEY]
```

### `scripts/install-lcd.sh` — LCD driver (reboots)

```bash
sudo ./scripts/install-lcd.sh [rotation]  # 0, 90, 180, 270
```

### `scripts/security-check.sh` — On-demand security audit

```bash
sudo ./scripts/security-check.sh              # Self-check
sudo ./scripts/security-check.sh --devices     # + network device scan
sudo ./scripts/security-check.sh --cron        # No color (for cron)
```

### `scripts/monitor-lcd.sh` — LCD dashboard

```bash
sudo ./scripts/monitor-lcd.sh          # One-shot render
sudo ./scripts/monitor-lcd.sh --loop   # Continuous (for systemd)
```

### Full provisioning order

```bash
# 1. Base system
sudo ./scripts/setup.sh tskey-auth-XXXX

# 2. Security stack
sudo ./scripts/install-security.sh

# 3. LCD driver (will reboot)
sudo ./scripts/install-lcd.sh 90

# 4. After reboot — start LCD dashboard
sudo systemctl enable kalipi-monitor
sudo systemctl start kalipi-monitor
```

---

## Troubleshooting

### Can't find the Pi on the network

```bash
# Plug in a monitor + keyboard temporarily, or
# Re-mount the SD card on your workstation and verify:
# - /boot/ssh file exists
# - /boot/wpa_supplicant.conf has correct SSID/password
# - Country code is correct in wpa_supplicant.conf
```

### WiFi not connecting

```bash
# Check interface status
ip link show wlan0
sudo wpa_cli -i wlan0 status

# Check for driver issues
dmesg | grep -i wifi
dmesg | grep -i wlan

# Restart networking stack
sudo systemctl restart wpa_supplicant
sudo systemctl restart networking
```

### SSH connection refused

```bash
sudo systemctl status ssh
sudo systemctl start ssh
sudo systemctl enable ssh

# Check if firewall is blocking
sudo iptables -L -n
```

### Tailscale not connecting

```bash
sudo systemctl status tailscaled
sudo systemctl restart tailscaled
tailscale status
tailscale netcheck  # Diagnose connectivity issues
```

### LCD not displaying

```bash
# Verify SPI is enabled
ls /dev/spi*
# Should show /dev/spidev0.0 and /dev/spidev0.1

# Check device tree overlay
cat /boot/config.txt | grep tft35a
# Should show: dtoverlay=tft35a:rotate=90

# Check framebuffer devices
ls /dev/fb*
# fb0 = HDMI, fb1 = SPI LCD

# Re-run the LCD installer
cd /home/kali/LCD-show-kali
sudo ./LCD35-show
```

### SD card not using full 128GB

```bash
df -h /
sudo parted /dev/mmcblk0 print
sudo parted /dev/mmcblk0 resizepart 2 100%
sudo resize2fs /dev/mmcblk0p2
```

---

## Network Architecture

```
 ┌──────────────────────┐
 │  Laptop (optional)   │
 │  SSH in to review    │
 │  reports & Lynis     │
 └──────────┬───────────┘
            │ Tailscale (when connected)
            │
 ┌──────────┴───────────┐     Tailscale Mesh VPN     ┌──────────────────────────┐
 │  DigitalOcean        │◄──────────────────────────► │  Raspberry Pi 4 (KaliPi) │
 │  Droplet             │       (WireGuard)           │                          │
 │                      │                             │  SECURITY STACK:         │
 │  - ClawBot instance  │                             │  - Suricata (IDS)        │
 │  - Tailscale node    │                             │  - fail2ban              │
 │                      │                             │  - auditd                │
 │  (small — no room    │                             │  - Wazuh agent (local)   │
 │   for SIEM)          │                             │  - rkhunter / Lynis      │
 │                      │                             │  - arpwatch              │
 └──────────────────────┘                             │  - LCD security dash     │
                                                      └────────────┬─────────────┘
                                                                   │
                                                              WiFi │ TP-Link_A7FC
                                                                   │
                                                      ┌────────────┴─────────────┐
                                                      │  ClawBot + other devices │
                                                      │  (monitored via network  │
                                                      │   scans + Suricata IDS)  │
                                                      └──────────────────────────┘
```

---

## Quick Reference

| Item | Value |
|---|---|
| Default user | `kali` |
| Default pass | `kali` (change immediately) |
| WiFi SSID | `TP-Link_A7FC` |
| WiFi Password | `11511762` |
| SSH | Port 22 (default) |
| Tailscale SSH | Enabled via `--ssh` flag |
| LCD | 3.5" SPI, 480x320, rotate=90 |
| Hostname | `kalipi` |
