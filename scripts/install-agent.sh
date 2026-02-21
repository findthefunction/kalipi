#!/bin/bash
# KaliPi — Install the remote monitoring agent (HTTP API + SSH access)
#
# Deploys the agent to /opt/kalipi/agent/ and enables the systemd service.
# Sets up SSH key auth for the OpenClaw bot on the Droplet.
#
# Usage: sudo ./scripts/install-agent.sh [droplet-pubkey]
#   droplet-pubkey: optional path to the Droplet's SSH public key file
#                   If omitted, you can add it manually later.

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
DROPLET_PUBKEY="${1:-}"

# ─── Verify Tailscale is running ─────────────────────────────
if ! tailscale ip -4 >/dev/null 2>&1; then
    err "Tailscale is not running. Install and connect Tailscale first."
    exit 1
fi

TS_IP=$(tailscale ip -4)
log "Tailscale IP: ${TS_IP}"

# ─── Deploy agent to /opt/kalipi ─────────────────────────────
log "Deploying agent to ${INSTALL_DIR}/agent/..."
mkdir -p "${INSTALL_DIR}"
cp -r "${REPO_DIR}/agent" "${INSTALL_DIR}/"
log "Agent Python package deployed."

# ─── Generate API token (if not exists) ──────────────────────
TOKEN_DIR="${INSTALL_DIR}/agent"
TOKEN_FILE="${TOKEN_DIR}/.token"
if [ ! -f "${TOKEN_FILE}" ]; then
    TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
    echo "${TOKEN}" > "${TOKEN_FILE}"
    chmod 600 "${TOKEN_FILE}"
    log "API token generated: ${TOKEN_FILE}"
    echo ""
    warn "=== SAVE THIS TOKEN — needed for OpenClaw config ==="
    warn "Token: ${TOKEN}"
    warn "===================================================="
    echo ""
else
    log "API token already exists, keeping current token."
fi

# ─── Set up SSH key auth for Droplet ─────────────────────────
KALI_HOME="/home/kali"
SSH_DIR="${KALI_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
chown kali:kali "${SSH_DIR}"

if [ -n "${DROPLET_PUBKEY}" ] && [ -f "${DROPLET_PUBKEY}" ]; then
    PUBKEY=$(cat "${DROPLET_PUBKEY}")
    if ! grep -qF "${PUBKEY}" "${AUTH_KEYS}" 2>/dev/null; then
        echo "${PUBKEY}" >> "${AUTH_KEYS}"
        chmod 600 "${AUTH_KEYS}"
        chown kali:kali "${AUTH_KEYS}"
        log "Droplet SSH public key added to ${AUTH_KEYS}"
    else
        log "Droplet SSH key already in authorized_keys."
    fi
else
    warn "No Droplet pubkey provided. To add SSH access later, run on the Droplet:"
    warn "  ssh-copy-id kali@${TS_IP}"
    warn "Or paste the Droplet's public key into ${AUTH_KEYS}"
fi

# ─── Install systemd service ─────────────────────────────────
log "Installing systemd service..."
cp "${REPO_DIR}/config/kalipi-agent.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable kalipi-agent.service

log "Agent service installed and enabled."

# ─── Start the agent ─────────────────────────────────────────
systemctl restart kalipi-agent.service
sleep 2

if systemctl is-active kalipi-agent.service >/dev/null 2>&1; then
    log "Agent is running!"
else
    warn "Agent failed to start. Check: journalctl -u kalipi-agent -f"
fi

# ─── Summary ─────────────────────────────────────────────────
TOKEN=$(cat "${TOKEN_FILE}")
echo ""
log "============================================"
log "KaliPi Agent installed!"
log "============================================"
log "  API:       http://${TS_IP}:7443"
log "  Health:    curl http://${TS_IP}:7443/api/health"
log "  Status:    curl http://${TS_IP}:7443/api/status"
log "  Exec:      curl -X POST http://${TS_IP}:7443/api/exec \\"
log "               -H 'Content-Type: application/json' \\"
log "               -H 'Authorization: Bearer ${TOKEN}' \\"
log "               -d '{\"cmd\":\"whoami\"}'"
log "  SSH:       ssh kali@${TS_IP}"
log "  Service:   systemctl status kalipi-agent"
log "  Log:       journalctl -u kalipi-agent -f"
log "============================================"
echo ""
log "One-liner for OpenClaw bot (paste into AGENTS.md or chat):"
echo ""
cat << EOF
KaliPi is a Raspberry Pi 4 running Kali Linux on your Tailscale network at ${TS_IP}. You have full access via two methods:

1. HTTP API (port 7443): GET /api/status for system+security status. GET /api/health for heartbeat. POST /api/exec with {"cmd":"SHELL_COMMAND"} for arbitrary shell execution (auth: 'Authorization: Bearer ${TOKEN}'). POST /api/command with {"command":"NAME"} for structured commands: security-scan, service-status, restart-service, network-scan, fail2ban-status, tailscale-status, disk-usage, recent-logs.

2. SSH: ssh kali@${TS_IP} — full shell access. Use for interactive tasks, file transfers, or long-running commands.

Example curl: curl -s -X POST http://${TS_IP}:7443/api/exec -H 'Content-Type: application/json' -H 'Authorization: Bearer ${TOKEN}' -d '{"cmd":"uname -a"}'

Monitor alerts: check /api/status and flag if failed_ssh > 0, f2b_banned > 0, cpu_temp > 75, mem_pct > 90, disk_pct > 85, or any service not active.
EOF
