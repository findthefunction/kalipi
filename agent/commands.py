"""KaliPi Agent — Whitelisted commands.

Only commands defined here can be executed via the API.
Each command is a function that returns a JSON-serializable dict.
"""

import subprocess
import json
import time

TIMEOUT = 30  # max seconds per command


def _run(cmd, timeout=TIMEOUT):
    """Run a shell command and return stdout."""
    try:
        r = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout,
        )
        return {"stdout": r.stdout.strip(), "stderr": r.stderr.strip(), "rc": r.returncode}
    except subprocess.TimeoutExpired:
        return {"stdout": "", "stderr": "command timed out", "rc": -1}


def cmd_security_scan(args):
    """Run a security check (the existing security-check.sh)."""
    return _run("/opt/kalipi/scripts/security-check.sh", timeout=120)


def cmd_service_status(args):
    """Check the status of all monitored services."""
    services = ["ssh", "tailscaled", "fail2ban", "suricata", "auditd",
                 "kalipi-dashboard", "kalipi-agent"]
    statuses = {}
    for svc in services:
        r = _run(f"systemctl is-active {svc}", timeout=5)
        statuses[svc] = r["stdout"] or "unknown"
    return {"services": statuses, "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z")}


def cmd_restart_service(args):
    """Restart a specific service (from allowed list only)."""
    allowed = ["kalipi-dashboard", "kalipi-agent", "fail2ban", "suricata"]
    svc = args.get("service", "")
    if svc not in allowed:
        return {"error": f"service '{svc}' not in allowed list: {allowed}"}
    return _run(f"systemctl restart {svc}")


def cmd_network_scan(args):
    """Quick scan of local network devices."""
    return _run("nmap -sn 192.168.0.0/24 -oG - 2>/dev/null | grep 'Status: Up'", timeout=60)


def cmd_fail2ban_status(args):
    """Get fail2ban jail status."""
    return _run("fail2ban-client status sshd")


def cmd_tailscale_status(args):
    """Get Tailscale network status."""
    return _run("tailscale status")


def cmd_disk_usage(args):
    """Get disk usage breakdown."""
    return _run("df -h /")


def cmd_recent_logs(args):
    """Get recent security-relevant log entries (last 50 lines)."""
    source = args.get("source", "security")
    log_map = {
        "security": "journalctl -u ssh --since '1 hour ago' --no-pager -n 50",
        "suricata": "tail -n 50 /var/log/suricata/fast.log 2>/dev/null || echo 'no suricata log'",
        "fail2ban": "tail -n 50 /var/log/fail2ban.log 2>/dev/null || echo 'no fail2ban log'",
        "dashboard": "tail -n 50 /var/log/kalipi-dashboard.log 2>/dev/null || echo 'no dashboard log'",
        "agent": "journalctl -u kalipi-agent --since '1 hour ago' --no-pager -n 50",
    }
    if source not in log_map:
        return {"error": f"unknown source: {source}", "available": list(log_map.keys())}
    return _run(log_map[source])


# ─── Command registry ────────────────────────────────────────
COMMANDS = {
    "security-scan": cmd_security_scan,
    "service-status": cmd_service_status,
    "restart-service": cmd_restart_service,
    "network-scan": cmd_network_scan,
    "fail2ban-status": cmd_fail2ban_status,
    "tailscale-status": cmd_tailscale_status,
    "disk-usage": cmd_disk_usage,
    "recent-logs": cmd_recent_logs,
}


def run_command(name, args=None):
    """Execute a registered command by name."""
    fn = COMMANDS.get(name)
    if not fn:
        return {"error": f"unknown command: {name}"}
    try:
        result = fn(args or {})
        result["command"] = name
        result["timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        return result
    except Exception as e:
        return {"error": str(e), "command": name}
