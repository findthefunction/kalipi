"""Security overview — main dashboard view.

Shows system stats, service health, network, and security summary.
This is the default/home view.
"""

import pygame
from dashboard.views.base import BaseView
from dashboard.theme import (
    CONTENT_Y, CONTENT_WIDTH, CONTENT_HEIGHT,
    TEXT, TEXT_DIM, TEXT_BRIGHT,
    SUCCESS, WARNING, DANGER, PRIMARY, INFO,
    BG_CARD, BORDER,
    PAD, PAD_SM, PAD_LG,
)


class SecurityView(BaseView):
    title = "Security"

    def render(self, data):
        self._fill_bg()
        y = CONTENT_Y + PAD_SM

        # ── System row ───────────────────────────────────────
        y += self._section_header("SYSTEM", y)

        # CPU + Temp on one line
        cpu = data.get("cpu_pct", 0)
        temp = data.get("cpu_temp", 0)
        temp_color = DANGER if temp > 80 else WARNING if temp > 70 else TEXT
        self._kv("CPU:", f"{cpu}%", PAD_LG, y)
        self._kv("Temp:", f"{temp}C", 150, y, value_color=temp_color)

        # CPU bar
        self._bar(280, y + 2, 185, 10, cpu)
        y += 18

        # Memory
        mem_used = data.get("mem_used", 0)
        mem_total = data.get("mem_total", 0)
        mem_pct = data.get("mem_pct", 0)
        self._kv("RAM:", f"{mem_used}/{mem_total}MB ({mem_pct}%)", PAD_LG, y)
        self._bar(330, y + 2, 135, 10, mem_pct)
        y += 18

        # Disk
        disk_used = data.get("disk_used", "?")
        disk_total = data.get("disk_total", "?")
        disk_pct = data.get("disk_pct", 0)
        self._kv("DSK:", f"{disk_used}/{disk_total} ({disk_pct}%)", PAD_LG, y)
        self._bar(330, y + 2, 135, 10, disk_pct)
        y += 18

        # Uptime + Load
        uptime = data.get("uptime", "?")
        load = data.get("load_avg", "?")
        self._kv("Up:", uptime, PAD_LG, y)
        self._kv("Load:", load, 250, y)
        y += 20

        # ── Network ──────────────────────────────────────────
        y += self._section_header("NETWORK", y)

        wlan = data.get("wlan_ip", "disconnected")
        wlan_color = SUCCESS if wlan != "disconnected" else DANGER
        self._kv("WiFi:", wlan, PAD_LG, y, value_color=wlan_color)

        ts = data.get("ts_ip", "offline")
        ts_state = data.get("ts_state", "unknown")
        ts_color = SUCCESS if ts != "offline" else DANGER
        self._kv("Tailscale:", f"{ts} ({ts_state})", 250, y, value_color=ts_color)
        y += 20

        # ── Services ─────────────────────────────────────────
        y += self._section_header("SERVICES", y)

        services = [
            ("SSH", data.get("svc_ssh", "unknown")),
            ("Tailscale", data.get("svc_tailscale", "unknown")),
            ("Fail2ban", data.get("svc_fail2ban", "unknown")),
            ("Suricata", data.get("svc_suricata", "unknown")),
            ("Auditd", data.get("svc_auditd", "unknown")),
        ]
        x = PAD_LG
        for name, status in services:
            active = status == "active"
            self._status_dot(x + 4, y + 7, active)
            label = f"{name}"
            self._text(label, x + 12, y, "small", SUCCESS if active else DANGER)
            x += 92
        y += 20

        # ── Security summary ─────────────────────────────────
        y += self._section_header("SECURITY", y)

        alerts = data.get("alerts", 0)
        alert_color = DANGER if alerts > 0 else SUCCESS
        self._kv("Alerts:", str(alerts), PAD_LG, y, value_color=alert_color)

        banned = data.get("f2b_banned", 0)
        ban_color = WARNING if banned > 0 else TEXT
        self._kv("Banned:", str(banned), 150, y, value_color=ban_color)

        failed = data.get("failed_ssh", 0)
        fail_color = DANGER if failed > 10 else WARNING if failed > 0 else TEXT
        self._kv("SSH Fail:", f"{failed} (6hr)", 280, y, value_color=fail_color)
        y += 18

        last = data.get("last_check", "never")
        self._kv("Last check:", str(last), PAD_LG, y)
