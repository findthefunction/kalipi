#!/bin/bash
# KaliPi — Lightweight self-contained security stack
# Designed to run autonomously on a Pi 4 (4GB/8GB) without external SIEM
# Usage: sudo ./scripts/install-security.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="${REPO_DIR}/config"

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

# ─── System prep ───────────────────────────────────────────────
log "Updating package lists..."
apt update

log "Installing base dependencies..."
apt install -y \
    curl \
    gnupg \
    lsb-release \
    apt-transport-https \
    ca-certificates \
    python3 \
    python3-pip \
    jq \
    inotify-tools

# ─── fail2ban ──────────────────────────────────────────────────
log "Installing fail2ban..."
apt install -y fail2ban

if [ -f "${CONFIG_DIR}/fail2ban/jail.local" ]; then
    cp "${CONFIG_DIR}/fail2ban/jail.local" /etc/fail2ban/jail.local
    log "Deployed custom jail.local"
fi

systemctl enable fail2ban
systemctl restart fail2ban
log "fail2ban active. Jails:"
fail2ban-client status

# ─── auditd ───────────────────────────────────────────────────
log "Installing auditd..."
apt install -y auditd audispd-plugins

if [ -f "${CONFIG_DIR}/auditd/audit.rules" ]; then
    cp "${CONFIG_DIR}/auditd/audit.rules" /etc/audit/rules.d/kalipi.rules
    log "Deployed custom audit rules"
fi

systemctl enable auditd
systemctl restart auditd
log "auditd active."

# ─── rkhunter ─────────────────────────────────────────────────
log "Installing rkhunter..."
apt install -y rkhunter

# Update rkhunter database
rkhunter --update || true
rkhunter --propupd

# Set up daily cron
cat > /etc/cron.daily/rkhunter-check << 'CRON'
#!/bin/bash
/usr/bin/rkhunter --check --skip-keypress --report-warnings-only \
    --logfile /var/log/rkhunter-daily.log 2>&1
CRON
chmod +x /etc/cron.daily/rkhunter-check
log "rkhunter installed + daily cron created."

# ─── chkrootkit ───────────────────────────────────────────────
log "Installing chkrootkit..."
apt install -y chkrootkit
log "chkrootkit installed."

# ─── Lynis ────────────────────────────────────────────────────
log "Installing Lynis..."
apt install -y lynis
log "Lynis installed. Run: sudo lynis audit system"

# ─── Suricata (IDS) ──────────────────────────────────────────
log "Installing Suricata..."
apt install -y suricata suricata-update

# Determine the active network interface
IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
if [ -z "$IFACE" ]; then
    IFACE="wlan0"
    warn "Could not detect default interface, defaulting to wlan0"
fi
log "Network interface for Suricata: ${IFACE}"

# Deploy custom config if available, otherwise patch the default
if [ -f "${CONFIG_DIR}/suricata/suricata-kalipi.yaml" ]; then
    cp "${CONFIG_DIR}/suricata/suricata-kalipi.yaml" /etc/suricata/suricata.yaml
    log "Deployed custom suricata config"
else
    # Patch default config for the Pi's interface
    sed -i "s/^\(  - interface: \).*/\1${IFACE}/" /etc/suricata/suricata.yaml
fi

# Update Suricata rules
log "Updating Suricata rulesets..."
suricata-update || warn "suricata-update had warnings (may need internet)"

systemctl enable suricata
systemctl restart suricata || warn "Suricata failed to start — check /var/log/suricata/suricata.log"
log "Suricata IDS active on ${IFACE}."

# ─── arpwatch ─────────────────────────────────────────────────
log "Installing arpwatch (rogue device detection)..."
apt install -y arpwatch

# Configure for wifi interface
if [ -f /etc/default/arpwatch ]; then
    sed -i "s/^INTERFACES=.*/INTERFACES=\"${IFACE}\"/" /etc/default/arpwatch 2>/dev/null || true
fi

systemctl enable arpwatch
systemctl restart arpwatch || warn "arpwatch may not start on wifi until associated"
log "arpwatch active."

# ─── OSSEC/Wazuh agent (local mode) ──────────────────────────
# Wazuh agent in local mode — no manager needed, logs locally
log "Installing Wazuh agent (local/standalone mode)..."

# Add Wazuh repo
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
    > /etc/apt/sources.list.d/wazuh.list
apt update

# Install agent — set WAZUH_MANAGER to localhost for local mode
WAZUH_MANAGER="127.0.0.1" apt install -y wazuh-agent || {
    warn "Wazuh agent install failed (ARM package may not be available)."
    warn "Falling back to OSSEC HIDS..."
    apt install -y ossec-hids-local 2>/dev/null || {
        warn "OSSEC also unavailable. Skipping host IDS agent."
        warn "Security monitoring will rely on auditd + rkhunter + Lynis."
    }
}

# Deploy local Wazuh config if available
if [ -f "${CONFIG_DIR}/wazuh/ossec.conf" ] && [ -d /var/ossec/etc ]; then
    cp "${CONFIG_DIR}/wazuh/ossec.conf" /var/ossec/etc/ossec.conf
    log "Deployed custom Wazuh/OSSEC config"
fi

if [ -d /var/ossec ]; then
    systemctl enable wazuh-agent 2>/dev/null || true
    systemctl start wazuh-agent 2>/dev/null || true
    log "Wazuh agent running in local mode."
fi

# ─── SSH device monitoring helper ─────────────────────────────
log "Setting up SSH device scanner..."
mkdir -p /opt/kalipi/scripts
cp "${SCRIPT_DIR}/security-check.sh" /opt/kalipi/scripts/ 2>/dev/null || true
cp "${SCRIPT_DIR}/tailscale-watchdog.sh" /opt/kalipi/scripts/ 2>/dev/null || true
chmod +x /opt/kalipi/scripts/*.sh 2>/dev/null || true

# Cron: run security check every 6 hours + Tailscale watchdog every 5 min
cat > /etc/cron.d/kalipi-security << 'CRON'
# KaliPi security checks — every 6 hours
0 */6 * * * root /opt/kalipi/scripts/security-check.sh --cron >> /var/log/kalipi-security.log 2>&1
# Suricata rule update — daily at 3am
0 3 * * * root /usr/bin/suricata-update && systemctl restart suricata
# Tailscale watchdog — every 5 minutes, restart if tunnel is down
*/5 * * * * root /opt/kalipi/scripts/tailscale-watchdog.sh
CRON
log "Cron jobs configured (6hr security check, daily rule update)."

# ─── Log rotation ────────────────────────────────────────────
cat > /etc/logrotate.d/kalipi << 'LOGROTATE'
/var/log/kalipi-security.log
/var/log/rkhunter-daily.log
{
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
LOGROTATE
log "Log rotation configured."

# ─── Summary ─────────────────────────────────────────────────
echo ""
log "============================================"
log "KaliPi Security Stack — Installed"
log "============================================"
log ""
log "  fail2ban     — SSH/service brute-force protection"
log "  auditd       — Kernel-level audit logging"
log "  rkhunter     — Rootkit detection (daily cron)"
log "  chkrootkit   — Rootkit detection (manual)"
log "  Lynis        — Security auditing & hardening"
log "  Suricata     — Network IDS on ${IFACE}"
log "  arpwatch     — Rogue device detection"
log "  Wazuh/OSSEC  — Host intrusion detection (local)"
log ""
log "Logs:"
log "  /var/log/fail2ban.log"
log "  /var/log/audit/audit.log"
log "  /var/log/rkhunter-daily.log"
log "  /var/log/suricata/fast.log"
log "  /var/log/suricata/eve.json"
log "  /var/ossec/logs/alerts/alerts.log"
log "  /var/log/kalipi-security.log"
log ""
log "Run a manual audit:  sudo ./scripts/security-check.sh"
log "Run Lynis audit:     sudo lynis audit system"
log "============================================"
