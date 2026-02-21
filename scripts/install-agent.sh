#!/bin/bash
# KaliPi — Install the remote monitoring agent (HTTP API over Tailscale)
#
# Deploys the agent to /opt/kalipi/agent/ and enables the systemd service.
# The API binds to the Tailscale IP only — not accessible from LAN or internet.
#
# Usage: sudo ./scripts/install-agent.sh

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
    warn "Agent may still be starting (waiting for Tailscale). Check: journalctl -u kalipi-agent -f"
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
log "  Commands:  curl -X POST http://${TS_IP}:7443/api/command \\"
log "               -H 'Content-Type: application/json' \\"
log "               -H 'Authorization: Bearer ${TOKEN}' \\"
log "               -d '{\"command\":\"service-status\"}'"
log "  Service:   systemctl status kalipi-agent"
log "  Log:       journalctl -u kalipi-agent -f"
log "============================================"
echo ""
log "One-liner for OpenClaw bot (paste into AGENTS.md or chat):"
echo ""
echo "KaliPi is a Raspberry Pi 4 security monitor on Tailscale at ${TS_IP}:7443. GET /api/status for full security+system status. GET /api/health for heartbeat. POST /api/command with {\"command\":\"NAME\"} to run commands. Auth header: 'Authorization: Bearer ${TOKEN}'. Available commands: security-scan, service-status, restart-service (needs {\"args\":{\"service\":\"NAME\"}}), network-scan, fail2ban-status, tailscale-status, disk-usage, recent-logs (needs {\"args\":{\"source\":\"security|suricata|fail2ban|dashboard|agent\"}}). Alert me if: failed_ssh > 0, f2b_banned > 0, cpu_temp > 75, mem_pct > 90, disk_pct > 85, or any service is not 'active'."
