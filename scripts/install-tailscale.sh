#!/bin/bash
# KaliPi — Tailscale installation script
# Usage: sudo ./scripts/install-tailscale.sh [AUTHKEY]

set -euo pipefail

AUTHKEY="${1:-}"

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

log "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh

log "Enabling tailscaled on boot..."
systemctl enable tailscaled
systemctl start tailscaled

if [ -n "$AUTHKEY" ]; then
    log "Authenticating with provided auth key..."
    tailscale up --authkey="$AUTHKEY" --ssh
    log "Tailscale connected!"
    log "  Tailscale IP: $(tailscale ip -4)"
    log "  Hostname:     $(tailscale status --self --json | python3 -c 'import sys,json; print(json.load(sys.stdin)["Self"]["HostName"])' 2>/dev/null || hostname)"
else
    warn "No auth key provided. Starting interactive auth..."
    warn "A URL will be printed — open it in a browser to authenticate."
    tailscale up --ssh
fi

log "Tailscale status:"
tailscale status
