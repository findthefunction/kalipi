"""KaliPi Agent — Lightweight HTTP API for remote monitoring and control.

Serves security status and accepts whitelisted commands over Tailscale.
Binds to the Tailscale interface only (not exposed to LAN or internet).

Endpoints:
    GET  /api/health   — heartbeat (for uptime checks)
    GET  /api/status   — full security + system status JSON
    POST /api/command   — execute a whitelisted command

Usage:
    python3 -m agent                    # auto-detect Tailscale IP
    python3 -m agent --bind 0.0.0.0     # bind to all interfaces (testing)
    python3 -m agent --port 7443        # custom port
"""
