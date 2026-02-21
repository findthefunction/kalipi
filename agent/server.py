"""KaliPi Agent — HTTP API server (stdlib only, no pip dependencies).

Binds to the Tailscale IP so it's only reachable over the mesh VPN.
"""

import argparse
import json
import os
import subprocess
import time
from functools import partial
from http.server import HTTPServer, BaseHTTPRequestHandler

from agent.commands import COMMANDS, run_command

STATUS_FILE = "/tmp/kalipi/security-status.json"
TOKEN_FILE = "/opt/kalipi/agent/.token"
DEFAULT_PORT = 7443


def _get_tailscale_ip():
    """Get the Tailscale IPv4 address."""
    try:
        result = subprocess.run(
            ["tailscale", "ip", "-4"],
            capture_output=True, text=True, timeout=5,
        )
        ip = result.stdout.strip()
        if ip:
            return ip
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return "127.0.0.1"


def _read_token():
    """Read the API bearer token from disk."""
    try:
        with open(TOKEN_FILE) as f:
            return f.read().strip()
    except FileNotFoundError:
        return None


def _system_metrics():
    """Collect live system metrics (lightweight, no subprocess)."""
    metrics = {}

    # CPU temperature
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            metrics["cpu_temp"] = round(int(f.read().strip()) / 1000, 1)
    except (OSError, ValueError):
        metrics["cpu_temp"] = None

    # Memory
    try:
        with open("/proc/meminfo") as f:
            mi = {}
            for line in f:
                parts = line.split()
                if parts[0] in ("MemTotal:", "MemAvailable:"):
                    mi[parts[0]] = int(parts[1])
            total = mi.get("MemTotal:", 0)
            avail = mi.get("MemAvailable:", 0)
            metrics["mem_total_mb"] = total // 1024
            metrics["mem_used_mb"] = (total - avail) // 1024
            metrics["mem_pct"] = round((total - avail) / total * 100, 1) if total else 0
    except OSError:
        pass

    # Disk
    try:
        st = os.statvfs("/")
        total = st.f_blocks * st.f_frsize
        free = st.f_bfree * st.f_frsize
        metrics["disk_total_gb"] = round(total / (1024**3), 1)
        metrics["disk_used_gb"] = round((total - free) / (1024**3), 1)
        metrics["disk_pct"] = round((total - free) / total * 100, 1) if total else 0
    except OSError:
        pass

    # Uptime
    try:
        with open("/proc/uptime") as f:
            secs = int(float(f.read().split()[0]))
            h, rem = divmod(secs, 3600)
            m, s = divmod(rem, 60)
            metrics["uptime"] = f"{h}h{m}m"
    except OSError:
        pass

    # Load average
    try:
        with open("/proc/loadavg") as f:
            metrics["load_avg"] = f.read().split()[0]
    except OSError:
        pass

    return metrics


def _read_security_status():
    """Read the latest security-check.sh output."""
    try:
        with open(STATUS_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"error": "security-status.json not available"}


class KaliPiHandler(BaseHTTPRequestHandler):
    """HTTP request handler for the KaliPi API."""

    # Suppress per-request logging to stderr
    def log_message(self, format, *args):
        pass

    def _send_json(self, data, status=200):
        body = json.dumps(data, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _check_token(self):
        """Verify bearer token for protected endpoints. Returns True if OK."""
        token = _read_token()
        if not token:
            # No token configured — allow (Tailscale-only network)
            return True
        auth = self.headers.get("Authorization", "")
        if auth == f"Bearer {token}":
            return True
        self._send_json({"error": "unauthorized"}, 401)
        return False

    def do_GET(self):
        if self.path == "/api/health":
            self._send_json({
                "status": "ok",
                "hostname": "kalipi",
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            })

        elif self.path == "/api/status":
            security = _read_security_status()
            live = _system_metrics()
            self._send_json({
                "hostname": "kalipi",
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "live": live,
                "security": security,
                "commands": list(COMMANDS.keys()),
            })

        else:
            self._send_json({"error": "not found"}, 404)

    def do_POST(self):
        if self.path == "/api/command":
            if not self._check_token():
                return

            # Read body
            length = int(self.headers.get("Content-Length", 0))
            if length == 0:
                self._send_json({"error": "empty body"}, 400)
                return
            try:
                body = json.loads(self.rfile.read(length))
            except json.JSONDecodeError:
                self._send_json({"error": "invalid JSON"}, 400)
                return

            cmd_name = body.get("command", "")
            cmd_args = body.get("args", {})

            if cmd_name not in COMMANDS:
                self._send_json({
                    "error": f"unknown command: {cmd_name}",
                    "available": list(COMMANDS.keys()),
                }, 400)
                return

            result = run_command(cmd_name, cmd_args)
            self._send_json(result)

        else:
            self._send_json({"error": "not found"}, 404)


def main():
    parser = argparse.ArgumentParser(description="KaliPi Agent API")
    parser.add_argument("--bind", default=None, help="Bind address (default: Tailscale IP)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Port (default: 7443)")
    args = parser.parse_args()

    bind = args.bind or _get_tailscale_ip()
    server = HTTPServer((bind, args.port), KaliPiHandler)
    print(f"KaliPi Agent listening on {bind}:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
