#!/bin/bash
# KaliPi — Tailscale connectivity watchdog
# Ensures Tailscale stays connected on a headless Pi.
# Restarts tailscaled if the tunnel is down, logs all recovery actions.
#
# Install: sudo cp scripts/tailscale-watchdog.sh /opt/kalipi/scripts/
# Cron:    */5 * * * * root /opt/kalipi/scripts/tailscale-watchdog.sh

LOG="/var/log/kalipi-tailscale-watchdog.log"
MAX_LOG_LINES=500

ts_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

# Trim log to prevent disk fill on a headless device
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt "$MAX_LOG_LINES" ]; then
    tail -n "$MAX_LOG_LINES" "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi

# 1. Is tailscaled running?
if ! systemctl is-active --quiet tailscaled; then
    ts_log "WARN tailscaled not running — restarting"
    systemctl start tailscaled
    sleep 5
fi

# 2. Is the tunnel up and connected?
TS_STATUS=$(tailscale status --json 2>/dev/null)
if [ $? -ne 0 ]; then
    ts_log "WARN tailscale status failed — restarting tailscaled"
    systemctl restart tailscaled
    sleep 10
    TS_STATUS=$(tailscale status --json 2>/dev/null) || exit 1
fi

BACKEND_STATE=$(echo "$TS_STATUS" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null)

case "$BACKEND_STATE" in
    Running)
        # All good — no log spam on success
        ;;
    NeedsLogin)
        ts_log "CRIT Tailscale needs re-authentication — cannot auto-fix"
        ts_log "CRIT Run: sudo tailscale up --ssh"
        # Still log to security status for dashboard
        mkdir -p /tmp/kalipi
        echo '{"tailscale_watchdog":"needs_login"}' > /tmp/kalipi/tailscale-watchdog.json
        ;;
    Stopped)
        ts_log "WARN Tailscale stopped — bringing up with --ssh"
        tailscale up --ssh 2>>"$LOG"
        sleep 5
        ;;
    *)
        ts_log "WARN unexpected state: ${BACKEND_STATE} — restarting"
        systemctl restart tailscaled
        sleep 10
        tailscale up --ssh 2>>"$LOG" || true
        ;;
esac
