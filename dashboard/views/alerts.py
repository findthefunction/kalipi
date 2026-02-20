"""Alerts view — Suricata IDS and fail2ban alerts feed.

Shows recent intrusion detection alerts and banned IPs.
Scrollable list for reviewing security events.
"""

import time
import pygame
from dashboard.views.base import BaseView
from dashboard.theme import (
    CONTENT_Y, CONTENT_WIDTH, CONTENT_HEIGHT,
    TEXT, TEXT_DIM, TEXT_BRIGHT,
    SUCCESS, WARNING, DANGER, INFO, PRIMARY,
    BG_CARD, BORDER,
    PAD, PAD_SM, PAD_LG,
)


class AlertsView(BaseView):
    title = "Alerts"

    def render(self, data):
        self._fill_bg()
        y = CONTENT_Y + PAD_SM - self.scroll_offset

        # ── Fail2ban banned IPs ──────────────────────────────
        y += self._section_header("FAIL2BAN", y)
        banned = data.get("banned_ips", [])
        f2b_count = data.get("f2b_banned", 0)

        if f2b_count > 0 or banned:
            self._text(
                f"{f2b_count} IP(s) currently banned",
                PAD_LG, y, "body", WARNING
            )
            y += 16
            for ip in banned[:10]:
                if isinstance(ip, str):
                    self._text(f"  {ip}", PAD_LG, y, "small", DANGER)
                    y += 14
        else:
            self._text("No IPs currently banned", PAD_LG, y, "body", SUCCESS)
            y += 16

        y += PAD

        # ── Failed SSH attempts ──────────────────────────────
        y += self._section_header("SSH AUTH", y)
        failed = data.get("failed_ssh", 0)
        if failed > 0:
            color = DANGER if failed > 10 else WARNING
            self._text(
                f"{failed} failed login attempts (last 6hr)",
                PAD_LG, y, "body", color
            )
        else:
            self._text("No failed attempts (last 6hr)", PAD_LG, y, "body", SUCCESS)
        y += 18

        # ── Suricata IDS alerts ──────────────────────────────
        y += self._section_header("SURICATA IDS", y)
        recent = data.get("recent_alerts", [])

        if recent:
            for alert in recent[:15]:
                if isinstance(alert, dict):
                    ts = alert.get("timestamp", "")[:19]
                    sig = alert.get("signature", "unknown")
                    sev = alert.get("severity", 3)
                    sev_color = DANGER if sev <= 1 else WARNING if sev <= 2 else INFO
                    # Timestamp
                    self._text(ts, PAD_LG, y, "tiny", TEXT_DIM)
                    y += 12
                    # Signature with severity color
                    # Truncate long signatures to fit 480px
                    if len(sig) > 55:
                        sig = sig[:52] + "..."
                    self._text(f"  [{sev}] {sig}", PAD_LG, y, "small", sev_color)
                    y += 15
                elif isinstance(alert, str):
                    if len(alert) > 60:
                        alert = alert[:57] + "..."
                    self._text(alert, PAD_LG, y, "small", WARNING)
                    y += 14
        else:
            self._text("No IDS alerts in last 6 hours", PAD_LG, y, "body", SUCCESS)
            y += 16

        y += PAD

        # ── Overall status ───────────────────────────────────
        total_alerts = data.get("alerts", 0)
        y += self._section_header("SUMMARY", y)
        if total_alerts == 0:
            self._text("All clear — no security events", PAD_LG, y, "body", SUCCESS)
        else:
            self._text(
                f"{total_alerts} total alert(s) since last check",
                PAD_LG, y, "body", DANGER
            )

        # Set max scroll
        self.max_scroll = max(0, y + self.scroll_offset - CONTENT_Y - CONTENT_HEIGHT + 20)
