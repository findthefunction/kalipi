#!/bin/bash
# KaliPi — LCD security dashboard
# Renders system + security status to the 3.5" SPI framebuffer (fb1)
# Reads from /tmp/kalipi/security-status.json (written by security-check.sh)
# Usage: sudo ./scripts/monitor-lcd.sh [--loop]
#   --loop: refresh every 10 seconds (run as systemd service)

set -euo pipefail

LOOP_MODE=false
REFRESH_INTERVAL=10
STATUS_FILE="/tmp/kalipi/security-status.json"
FB_DEVICE="/dev/fb1"   # SPI LCD framebuffer (fb0 = HDMI)

for arg in "$@"; do
    case "$arg" in
        --loop) LOOP_MODE=true ;;
    esac
done

# ─── Check for framebuffer console tools ──────────────────────
# We use basic console output to fb1 via con2fbmap or fbterm
# If neither is available, fall back to writing a text status file

USE_FBTERM=false
USE_CON2FB=false

if command -v fbterm &>/dev/null && [ -c "$FB_DEVICE" ]; then
    USE_FBTERM=true
elif command -v con2fbmap &>/dev/null && [ -c "$FB_DEVICE" ]; then
    USE_CON2FB=true
fi

# ─── Gather live system stats ─────────────────────────────────
gather_stats() {
    # CPU
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d. -f1 2>/dev/null || echo "?")
    CPU_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "0")
    CPU_TEMP_C=$((CPU_TEMP / 1000))

    # Memory
    MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
    MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL))

    # Disk
    DISK_PCT=$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')
    DISK_USED=$(df -h / | tail -1 | awk '{print $3}')
    DISK_TOTAL=$(df -h / | tail -1 | awk '{print $2}')

    # Network
    WLAN_IP=$(ip -4 addr show wlan0 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 || echo "disconnected")
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "offline")
    TS_STATE=$(tailscale status --self --json 2>/dev/null | jq -r '.BackendState' 2>/dev/null || echo "unknown")

    # Uptime
    UPTIME=$(uptime -p 2>/dev/null | sed 's/up //' || echo "?")

    # Services
    SVC_SSH=$(systemctl is-active ssh 2>/dev/null || echo "?")
    SVC_TS=$(systemctl is-active tailscaled 2>/dev/null || echo "?")
    SVC_F2B=$(systemctl is-active fail2ban 2>/dev/null || echo "?")
    SVC_SURI=$(systemctl is-active suricata 2>/dev/null || echo "?")

    # Security status from last check
    if [ -f "$STATUS_FILE" ]; then
        SEC_ALERTS=$(jq -r '.alerts // 0' "$STATUS_FILE" 2>/dev/null || echo "?")
        SEC_FAILED_SSH=$(jq -r '.failed_ssh // 0' "$STATUS_FILE" 2>/dev/null || echo "?")
        SEC_LAST_CHECK=$(jq -r '.timestamp // "never"' "$STATUS_FILE" 2>/dev/null || echo "never")
    else
        SEC_ALERTS="?"
        SEC_FAILED_SSH="?"
        SEC_LAST_CHECK="no data"
    fi

    # fail2ban banned count
    F2B_BANNED=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}' || echo "0")

    NOW=$(date '+%H:%M:%S')
}

# ─── Render dashboard ────────────────────────────────────────
render_dashboard() {
    clear 2>/dev/null || true

    cat << EOF
 ╔═══════════════════════════════════╗
 ║         K A L I P i               ║
 ║     Security Monitor  ${NOW}   ║
 ╠═══════════════════════════════════╣
 ║ SYSTEM                           ║
 ║  CPU: ${CPU_USAGE}%  Temp: ${CPU_TEMP_C}°C            ║
 ║  RAM: ${MEM_USED}/${MEM_TOTAL}MB (${MEM_PCT}%)           ║
 ║  DSK: ${DISK_USED}/${DISK_TOTAL} (${DISK_PCT}%)             ║
 ║  Up:  ${UPTIME}          ║
 ╠═══════════════════════════════════╣
 ║ NETWORK                          ║
 ║  WiFi: ${WLAN_IP}            ║
 ║  T.S.: ${TS_IP} (${TS_STATE})    ║
 ╠═══════════════════════════════════╣
 ║ SERVICES                         ║
 ║  ssh:${SVC_SSH} ts:${SVC_TS} f2b:${SVC_F2B} ids:${SVC_SURI}║
 ╠═══════════════════════════════════╣
 ║ SECURITY                         ║
 ║  Alerts: ${SEC_ALERTS}  Banned: ${F2B_BANNED}         ║
 ║  Failed SSH: ${SEC_FAILED_SSH} (6hr)          ║
 ║  Last check: ${SEC_LAST_CHECK}    ║
 ╚═══════════════════════════════════╝
EOF
}

# ─── Output to LCD framebuffer ────────────────────────────────
output_to_lcd() {
    if $USE_CON2FB; then
        # Map a virtual console to fb1
        con2fbmap 2 1 2>/dev/null || true
        # Write to that console
        render_dashboard > /dev/tty2
    elif $USE_FBTERM; then
        render_dashboard | FRAMEBUFFER=$FB_DEVICE fbterm 2>/dev/null
    else
        # Fallback: just output to stdout (works if console is on fb1)
        render_dashboard
    fi
}

# ─── Main ─────────────────────────────────────────────────────
if $LOOP_MODE; then
    while true; do
        gather_stats
        output_to_lcd
        sleep "$REFRESH_INTERVAL"
    done
else
    gather_stats
    output_to_lcd
fi
