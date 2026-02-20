"""Network view — connectivity status and discovered devices.

Shows WiFi, Tailscale VPN, and devices found on the local network.
"""

import pygame
from dashboard.views.base import BaseView
from dashboard.theme import (
    CONTENT_Y, CONTENT_WIDTH, CONTENT_HEIGHT,
    TEXT, TEXT_DIM, TEXT_BRIGHT,
    SUCCESS, WARNING, DANGER, INFO, PRIMARY,
    BG_CARD, BORDER,
    PAD, PAD_SM, PAD_LG,
)


class NetworkView(BaseView):
    title = "Network"

    def render(self, data):
        self._fill_bg()
        y = CONTENT_Y + PAD_SM - self.scroll_offset

        # ── WiFi ─────────────────────────────────────────────
        y += self._section_header("WIFI", y)
        wlan = data.get("wlan_ip", "disconnected")
        connected = wlan != "disconnected"
        self._status_dot(PAD_LG + 4, y + 7, connected)
        status_text = f"Connected: {wlan}" if connected else "Disconnected"
        self._text(status_text, PAD_LG + 14, y, "body", SUCCESS if connected else DANGER)
        y += 20

        # ── Tailscale VPN ────────────────────────────────────
        y += self._section_header("TAILSCALE VPN", y)
        ts_ip = data.get("ts_ip", "offline")
        ts_state = data.get("ts_state", "unknown")
        ts_ok = ts_ip != "offline" and ts_state not in ("unknown", "Stopped")
        self._status_dot(PAD_LG + 4, y + 7, ts_ok)
        self._text(
            f"IP: {ts_ip}" if ts_ok else "Offline",
            PAD_LG + 14, y, "body", SUCCESS if ts_ok else DANGER
        )
        y += 16
        self._kv("State:", ts_state, PAD_LG + 14, y)
        y += 20

        # ── Interfaces ───────────────────────────────────────
        y += self._section_header("SERVICES LISTENING", y)
        services = [
            ("SSH", data.get("svc_ssh", "unknown"), "22"),
            ("Tailscale", data.get("svc_tailscale", "unknown"), "VPN"),
            ("Fail2ban", data.get("svc_fail2ban", "unknown"), "-"),
            ("Suricata", data.get("svc_suricata", "unknown"), "IDS"),
            ("Auditd", data.get("svc_auditd", "unknown"), "Audit"),
        ]
        for name, status, port in services:
            active = status == "active"
            self._status_dot(PAD_LG + 4, y + 7, active)
            self._text(name, PAD_LG + 14, y, "small", TEXT)
            self._text(
                status, 160, y, "small",
                SUCCESS if active else DANGER
            )
            self._text(f":{port}", 260, y, "small", TEXT_DIM)
            y += 16
        y += PAD

        # ── Discovered devices ───────────────────────────────
        y += self._section_header("LOCAL DEVICES", y)
        devices = data.get("network_devices", [])

        if devices:
            for dev in devices[:12]:
                if isinstance(dev, dict):
                    ip = dev.get("ip", "?")
                    mac = dev.get("mac", "")
                    vendor = dev.get("vendor", "")
                    label = ip
                    if vendor:
                        label += f" ({vendor})"
                    elif mac:
                        label += f" [{mac}]"
                    if len(label) > 55:
                        label = label[:52] + "..."
                    self._text(f"  {label}", PAD_LG, y, "small", TEXT_DIM)
                    y += 14
                elif isinstance(dev, str):
                    if len(dev) > 55:
                        dev = dev[:52] + "..."
                    self._text(f"  {dev}", PAD_LG, y, "small", TEXT_DIM)
                    y += 14
        else:
            self._text(
                "Run security-check.sh --devices to scan",
                PAD_LG, y, "small", TEXT_DIM
            )
            y += 14

        self.max_scroll = max(0, y + self.scroll_offset - CONTENT_Y - CONTENT_HEIGHT + 20)
