"""KaliPi Dashboard — Data collection layer.

Gathers live system stats, security status, and network info.
Runs collection in a background thread to avoid blocking the UI.
"""

import json
import os
import subprocess
import threading
import time


def _run(cmd, timeout=5):
    """Run a shell command, return stdout or empty string on failure."""
    try:
        r = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return r.stdout.strip()
    except Exception:
        return ""


class DataCollector:
    """Collects system and security data on a background thread."""

    def __init__(self, status_file="/tmp/kalipi/security-status.json"):
        self.status_file = status_file
        self.lock = threading.Lock()
        self._data = self._empty()
        self._running = False
        self._thread = None

    def _empty(self):
        return {
            # System
            "cpu_pct": 0,
            "cpu_temp": 0,
            "mem_used": 0,
            "mem_total": 0,
            "mem_pct": 0,
            "disk_used": "?",
            "disk_total": "?",
            "disk_pct": 0,
            "uptime": "?",
            "load_avg": "?",
            # Network
            "wlan_ip": "disconnected",
            "ts_ip": "offline",
            "ts_state": "unknown",
            # Services
            "svc_ssh": "unknown",
            "svc_tailscale": "unknown",
            "svc_fail2ban": "unknown",
            "svc_suricata": "unknown",
            "svc_auditd": "unknown",
            # Security (from security-check.sh JSON)
            "alerts": 0,
            "failed_ssh": 0,
            "f2b_banned": 0,
            "banned_ips": [],
            "last_check": "never",
            # Suricata recent alerts
            "recent_alerts": [],
            # Network devices
            "network_devices": [],
            # Timestamp
            "collected_at": "",
        }

    def start(self, interval=10):
        """Start background collection thread."""
        self._running = True
        self._thread = threading.Thread(
            target=self._loop, args=(interval,), daemon=True
        )
        self._thread.start()

    def stop(self):
        self._running = False

    @property
    def data(self):
        with self.lock:
            return dict(self._data)

    def _loop(self, interval):
        while self._running:
            fresh = self._collect()
            with self.lock:
                self._data = fresh
            time.sleep(interval)

    def _collect(self):
        d = self._empty()
        d["collected_at"] = time.strftime("%H:%M:%S")

        # ── CPU ──
        try:
            with open("/proc/stat") as f:
                line = f.readline()
            parts = line.split()
            idle = int(parts[4])
            total = sum(int(x) for x in parts[1:])
            # Compare with stored previous values
            prev_idle = getattr(self, "_prev_idle", idle)
            prev_total = getattr(self, "_prev_total", total)
            diff_idle = idle - prev_idle
            diff_total = total - prev_total
            self._prev_idle = idle
            self._prev_total = total
            if diff_total > 0:
                d["cpu_pct"] = round(100.0 * (1.0 - diff_idle / diff_total))
            else:
                d["cpu_pct"] = 0
        except Exception:
            d["cpu_pct"] = 0

        # ── CPU temperature ──
        try:
            with open("/sys/class/thermal/thermal_zone0/temp") as f:
                d["cpu_temp"] = int(f.read().strip()) // 1000
        except Exception:
            d["cpu_temp"] = 0

        # ── Memory ──
        try:
            with open("/proc/meminfo") as f:
                mi = {}
                for line in f:
                    parts = line.split()
                    mi[parts[0].rstrip(":")] = int(parts[1])
            d["mem_total"] = mi.get("MemTotal", 0) // 1024
            available = mi.get("MemAvailable", mi.get("MemFree", 0))
            d["mem_used"] = (mi.get("MemTotal", 0) - available) // 1024
            if d["mem_total"] > 0:
                d["mem_pct"] = round(100.0 * d["mem_used"] / d["mem_total"])
        except Exception:
            pass

        # ── Disk ──
        try:
            st = os.statvfs("/")
            total_gb = (st.f_blocks * st.f_frsize) / (1024**3)
            free_gb = (st.f_bavail * st.f_frsize) / (1024**3)
            used_gb = total_gb - free_gb
            d["disk_total"] = f"{total_gb:.0f}G"
            d["disk_used"] = f"{used_gb:.1f}G"
            d["disk_pct"] = round(100.0 * used_gb / total_gb) if total_gb > 0 else 0
        except Exception:
            pass

        # ── Uptime ──
        try:
            with open("/proc/uptime") as f:
                secs = float(f.read().split()[0])
            days = int(secs // 86400)
            hours = int((secs % 86400) // 3600)
            mins = int((secs % 3600) // 60)
            if days > 0:
                d["uptime"] = f"{days}d {hours}h {mins}m"
            elif hours > 0:
                d["uptime"] = f"{hours}h {mins}m"
            else:
                d["uptime"] = f"{mins}m"
        except Exception:
            pass

        # ── Load average ──
        try:
            with open("/proc/loadavg") as f:
                d["load_avg"] = " ".join(f.read().split()[:3])
        except Exception:
            pass

        # ── Network ──
        d["wlan_ip"] = _run(
            "ip -4 addr show wlan0 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1"
        ) or "disconnected"
        d["ts_ip"] = _run("tailscale ip -4 2>/dev/null") or "offline"
        d["ts_state"] = _run(
            "tailscale status --self --json 2>/dev/null | jq -r '.BackendState' 2>/dev/null"
        ) or "unknown"

        # ── Services ──
        for svc_key, svc_name in [
            ("svc_ssh", "ssh"),
            ("svc_tailscale", "tailscaled"),
            ("svc_fail2ban", "fail2ban"),
            ("svc_suricata", "suricata"),
            ("svc_auditd", "auditd"),
        ]:
            d[svc_key] = _run(f"systemctl is-active {svc_name} 2>/dev/null") or "unknown"

        # ── Security status from security-check.sh ──
        if os.path.isfile(self.status_file):
            try:
                with open(self.status_file) as f:
                    sec = json.load(f)
                d["alerts"] = sec.get("alerts", 0)
                d["failed_ssh"] = sec.get("failed_ssh", 0)
                d["f2b_banned"] = sec.get("f2b_banned", 0)
                d["banned_ips"] = sec.get("banned_ips", [])
                d["last_check"] = sec.get("timestamp", "never")
                d["recent_alerts"] = sec.get("recent_alerts", [])
                d["network_devices"] = sec.get("network_devices", [])
            except Exception:
                pass

        # ── Live fail2ban count if not in JSON ──
        if d["f2b_banned"] == 0:
            raw = _run(
                "fail2ban-client status sshd 2>/dev/null | grep 'Currently banned' | awk '{print $NF}'"
            )
            try:
                d["f2b_banned"] = int(raw)
            except ValueError:
                pass

        return d
