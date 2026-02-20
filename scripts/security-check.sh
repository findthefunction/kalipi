#!/bin/bash
# KaliPi — On-demand security audit and device check
# Runs locally on the Pi. Checks self + any SSH-reachable devices.
# Usage: sudo ./scripts/security-check.sh [--cron] [--devices]

set -euo pipefail

CRON_MODE=false
CHECK_DEVICES=false
LOG_FILE="/var/log/kalipi-security.log"
REPORT_DIR="/var/log/kalipi-reports"
TIMESTAMP=$(date '+%Y-%m-%d_%H:%M:%S')
ALERT_COUNT=0

for arg in "$@"; do
    case "$arg" in
        --cron) CRON_MODE=true ;;
        --devices) CHECK_DEVICES=true ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# In cron mode, strip colors
if $CRON_MODE; then
    log()  { echo "[+] $1"; }
    warn() { echo "[!] $1"; ALERT_COUNT=$((ALERT_COUNT + 1)); }
    err()  { echo "[-] $1"; ALERT_COUNT=$((ALERT_COUNT + 1)); }
    section() { echo ""; echo "=== $1 ==="; }
else
    log()  { echo -e "${GREEN}[+]${NC} $1"; }
    warn() { echo -e "${YELLOW}[!]${NC} $1"; ALERT_COUNT=$((ALERT_COUNT + 1)); }
    err()  { echo -e "${RED}[-]${NC} $1"; ALERT_COUNT=$((ALERT_COUNT + 1)); }
    section() { echo ""; echo -e "${CYAN}=== $1 ===${NC}"; }
fi

mkdir -p "$REPORT_DIR"

section "KaliPi Security Check — ${TIMESTAMP}"

# ─── 1. System integrity ─────────────────────────────────────
section "System Integrity"

# Check if critical binaries have been modified
log "Checking critical binary hashes..."
BINARIES="/usr/bin/ssh /usr/sbin/sshd /usr/bin/sudo /usr/bin/passwd /usr/bin/su"
for bin in $BINARIES; do
    if [ -f "$bin" ]; then
        sha256sum "$bin" >> "${REPORT_DIR}/binary-hashes-${TIMESTAMP}.txt" 2>/dev/null
    fi
done

# Compare with previous run
PREV_HASHES=$(ls -t "${REPORT_DIR}"/binary-hashes-*.txt 2>/dev/null | sed -n '2p')
if [ -n "$PREV_HASHES" ]; then
    DIFF=$(diff "$PREV_HASHES" "${REPORT_DIR}/binary-hashes-${TIMESTAMP}.txt" 2>/dev/null || true)
    if [ -n "$DIFF" ]; then
        err "CRITICAL: Binary hashes changed since last check!"
        echo "$DIFF"
    else
        log "Binary hashes unchanged."
    fi
else
    log "First run — baseline binary hashes recorded."
fi

# ─── 2. Running processes ────────────────────────────────────
section "Process Audit"

# Check for unexpected SUID binaries
log "Scanning for SUID binaries..."
SUID_BINS=$(find / -perm -4000 -type f 2>/dev/null | sort)
echo "$SUID_BINS" > "${REPORT_DIR}/suid-${TIMESTAMP}.txt"

PREV_SUID=$(ls -t "${REPORT_DIR}"/suid-*.txt 2>/dev/null | sed -n '2p')
if [ -n "$PREV_SUID" ]; then
    NEW_SUID=$(diff "$PREV_SUID" "${REPORT_DIR}/suid-${TIMESTAMP}.txt" 2>/dev/null | grep "^>" || true)
    if [ -n "$NEW_SUID" ]; then
        warn "New SUID binaries detected:"
        echo "$NEW_SUID"
    else
        log "No new SUID binaries."
    fi
fi

# Check for unexpected listening ports
log "Checking listening ports..."
LISTENERS=$(ss -tlnp 2>/dev/null)
echo "$LISTENERS"
UNEXPECTED=$(echo "$LISTENERS" | grep -v -E ':(22|53|631|5355|9100)\s' | grep -v "127.0.0" | tail -n +2 || true)
if [ -n "$UNEXPECTED" ]; then
    warn "Unexpected listening ports detected (review above)"
fi

# ─── 3. Authentication ───────────────────────────────────────
section "Authentication Check"

# Recent failed logins
FAILED_LOGINS=$(journalctl -u ssh --since "6 hours ago" 2>/dev/null | grep -c "Failed password" || echo "0")
if [ "$FAILED_LOGINS" -gt 10 ]; then
    err "HIGH: ${FAILED_LOGINS} failed SSH login attempts in last 6 hours"
elif [ "$FAILED_LOGINS" -gt 0 ]; then
    warn "${FAILED_LOGINS} failed SSH login attempts in last 6 hours"
else
    log "No failed SSH logins in last 6 hours."
fi

# Check for new users
CURRENT_USERS=$(awk -F: '$3 >= 1000 && $3 != 65534 {print $1}' /etc/passwd | sort)
echo "$CURRENT_USERS" > "${REPORT_DIR}/users-${TIMESTAMP}.txt"
PREV_USERS=$(ls -t "${REPORT_DIR}"/users-*.txt 2>/dev/null | sed -n '2p')
if [ -n "$PREV_USERS" ]; then
    NEW_USERS=$(diff "$PREV_USERS" "${REPORT_DIR}/users-${TIMESTAMP}.txt" 2>/dev/null | grep "^>" || true)
    if [ -n "$NEW_USERS" ]; then
        err "New user accounts detected: ${NEW_USERS}"
    else
        log "No new user accounts."
    fi
fi

# Check authorized_keys changes
if [ -f /home/kali/.ssh/authorized_keys ]; then
    KEYS_HASH=$(sha256sum /home/kali/.ssh/authorized_keys | awk '{print $1}')
    PREV_KEYS_HASH_FILE="${REPORT_DIR}/ssh-keys-hash.txt"
    if [ -f "$PREV_KEYS_HASH_FILE" ]; then
        PREV_HASH=$(cat "$PREV_KEYS_HASH_FILE")
        if [ "$KEYS_HASH" != "$PREV_HASH" ]; then
            err "authorized_keys file has been modified!"
        else
            log "authorized_keys unchanged."
        fi
    fi
    echo "$KEYS_HASH" > "$PREV_KEYS_HASH_FILE"
fi

# ─── 4. Service health ───────────────────────────────────────
section "Service Health"

SERVICES="ssh tailscaled fail2ban suricata auditd"
for svc in $SERVICES; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        log "${svc}: running"
    else
        err "${svc}: NOT running"
    fi
done

# ─── 5. Tailscale status ─────────────────────────────────────
section "Tailscale Network"

if command -v tailscale &>/dev/null; then
    TS_STATUS=$(tailscale status 2>/dev/null || echo "disconnected")
    echo "$TS_STATUS"
    if echo "$TS_STATUS" | grep -q "offline"; then
        err "Tailscale is offline!"
    else
        log "Tailscale connected."
    fi
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
    log "Tailscale IP: ${TAILSCALE_IP}"
else
    warn "Tailscale not installed."
fi

# ─── 6. Suricata alerts ──────────────────────────────────────
section "Suricata IDS Alerts (last 6 hours)"

if [ -f /var/log/suricata/eve.json ]; then
    CUTOFF=$(date -d '6 hours ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    ALERT_LINES=$(jq -r "select(.event_type==\"alert\" and .timestamp>=\"${CUTOFF}\") | \"\(.timestamp) [\(.alert.severity)] \(.alert.signature)\"" /var/log/suricata/eve.json 2>/dev/null | tail -20)
    if [ -n "$ALERT_LINES" ]; then
        warn "Suricata alerts detected:"
        echo "$ALERT_LINES"
    else
        log "No Suricata alerts in last 6 hours."
    fi
else
    warn "Suricata eve.json not found."
fi

# ─── 7. fail2ban status ──────────────────────────────────────
section "fail2ban Status"

if command -v fail2ban-client &>/dev/null; then
    fail2ban-client status 2>/dev/null
    BANNED=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" || echo "  Currently banned: 0")
    echo "$BANNED"
    BANNED_COUNT=$(echo "$BANNED" | awk '{print $NF}')
    if [ "$BANNED_COUNT" -gt 0 ]; then
        warn "${BANNED_COUNT} IPs currently banned by fail2ban"
    fi
else
    warn "fail2ban not installed."
fi

# ─── 8. Disk & resource check ────────────────────────────────
section "Resource Check"

DISK_USAGE=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')
if [ "$DISK_USAGE" -gt 90 ]; then
    err "Disk usage critical: ${DISK_USAGE}%"
elif [ "$DISK_USAGE" -gt 80 ]; then
    warn "Disk usage high: ${DISK_USAGE}%"
else
    log "Disk usage: ${DISK_USAGE}%"
fi

MEM_USAGE=$(free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}')
if [ "$MEM_USAGE" -gt 90 ]; then
    err "Memory usage critical: ${MEM_USAGE}%"
elif [ "$MEM_USAGE" -gt 80 ]; then
    warn "Memory usage high: ${MEM_USAGE}%"
else
    log "Memory usage: ${MEM_USAGE}%"
fi

CPU_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "0")
CPU_TEMP_C=$((CPU_TEMP / 1000))
if [ "$CPU_TEMP_C" -gt 80 ]; then
    err "CPU temperature critical: ${CPU_TEMP_C}°C"
elif [ "$CPU_TEMP_C" -gt 70 ]; then
    warn "CPU temperature high: ${CPU_TEMP_C}°C"
else
    log "CPU temperature: ${CPU_TEMP_C}°C"
fi

UPTIME=$(uptime -p)
log "Uptime: ${UPTIME}"

# ─── 9. Connected device scan (optional) ─────────────────────
if $CHECK_DEVICES; then
    section "Network Device Scan"
    log "Scanning local network for devices..."

    # Get subnet from wlan0
    SUBNET=$(ip -4 addr show wlan0 2>/dev/null | grep inet | awk '{print $2}')
    if [ -n "$SUBNET" ]; then
        if command -v nmap &>/dev/null; then
            nmap -sn "$SUBNET" --exclude "$(hostname -I | awk '{print $1}')" 2>/dev/null | \
                grep -E "Nmap scan report|MAC Address" | \
                tee "${REPORT_DIR}/network-scan-${TIMESTAMP}.txt"

            PREV_SCAN=$(ls -t "${REPORT_DIR}"/network-scan-*.txt 2>/dev/null | sed -n '2p')
            if [ -n "$PREV_SCAN" ]; then
                NEW_DEVICES=$(diff "$PREV_SCAN" "${REPORT_DIR}/network-scan-${TIMESTAMP}.txt" 2>/dev/null | grep "^>" || true)
                if [ -n "$NEW_DEVICES" ]; then
                    warn "New devices detected on network:"
                    echo "$NEW_DEVICES"
                fi
            fi
        else
            warn "nmap not installed — skipping network scan"
        fi
    fi
fi

# ─── Summary ─────────────────────────────────────────────────
section "Summary"
if [ "$ALERT_COUNT" -eq 0 ]; then
    log "All checks passed. No alerts."
else
    warn "${ALERT_COUNT} alert(s) raised. Review above."
fi

# Write expanded status file for the dashboard to consume
mkdir -p /tmp/kalipi

# Collect fail2ban banned IPs as JSON array
F2B_BANNED_IPS="[]"
if command -v fail2ban-client &>/dev/null; then
    F2B_BANNED_IPS=$(fail2ban-client status sshd 2>/dev/null | \
        grep "Banned IP list:" | sed 's/.*Banned IP list://' | \
        awk '{gsub(/^ +| +$/,""); n=split($0,a," "); printf "["; for(i=1;i<=n;i++){printf "\"%s\"",a[i]; if(i<n) printf ","} printf "]"}' \
        2>/dev/null || echo "[]")
    [ -z "$F2B_BANNED_IPS" ] && F2B_BANNED_IPS="[]"
fi

F2B_BANNED_COUNT=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}' 2>/dev/null || echo "0")
[ -z "$F2B_BANNED_COUNT" ] && F2B_BANNED_COUNT=0

# Collect recent Suricata alerts as JSON array (last 6 hours, max 20)
SURICATA_ALERTS="[]"
if [ -f /var/log/suricata/eve.json ]; then
    CUTOFF_TS=$(date -d '6 hours ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    SURICATA_ALERTS=$(jq -c "[
        .[] |
        select(.event_type==\"alert\" and .timestamp>=\"${CUTOFF_TS}\") |
        {timestamp: .timestamp, signature: .alert.signature, severity: .alert.severity}
    ] | .[-20:]" /var/log/suricata/eve.json 2>/dev/null || echo "[]")
    [ -z "$SURICATA_ALERTS" ] && SURICATA_ALERTS="[]"
fi

# Collect network devices if a recent scan exists
NETWORK_DEVICES="[]"
LATEST_SCAN=$(ls -t "${REPORT_DIR}"/network-scan-*.txt 2>/dev/null | head -1)
if [ -n "$LATEST_SCAN" ]; then
    NETWORK_DEVICES=$(grep "Nmap scan report for" "$LATEST_SCAN" 2>/dev/null | \
        awk '{ip=$NF; gsub(/[()]/, "", ip); printf "{\"ip\":\"%s\"},", ip}' | \
        sed 's/,$//' | awk '{printf "[%s]", $0}' 2>/dev/null || echo "[]")
    [ -z "$NETWORK_DEVICES" ] && NETWORK_DEVICES="[]"
fi

cat > /tmp/kalipi/security-status.json << EOF
{
    "timestamp": "${TIMESTAMP}",
    "alerts": ${ALERT_COUNT},
    "disk_pct": ${DISK_USAGE},
    "mem_pct": ${MEM_USAGE},
    "cpu_temp": ${CPU_TEMP_C},
    "failed_ssh": ${FAILED_LOGINS},
    "f2b_banned": ${F2B_BANNED_COUNT},
    "banned_ips": ${F2B_BANNED_IPS},
    "recent_alerts": ${SURICATA_ALERTS},
    "network_devices": ${NETWORK_DEVICES},
    "tailscale": "$(tailscale status --self --json 2>/dev/null | jq -r '.BackendState' 2>/dev/null || echo 'unknown')",
    "services": {
        "ssh": "$(systemctl is-active ssh 2>/dev/null || echo 'unknown')",
        "tailscaled": "$(systemctl is-active tailscaled 2>/dev/null || echo 'unknown')",
        "fail2ban": "$(systemctl is-active fail2ban 2>/dev/null || echo 'unknown')",
        "suricata": "$(systemctl is-active suricata 2>/dev/null || echo 'unknown')"
    }
}
EOF
log "Status written to /tmp/kalipi/security-status.json"

# Clean up old reports (keep last 30 days)
find "$REPORT_DIR" -type f -mtime +30 -delete 2>/dev/null || true
