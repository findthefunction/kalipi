"""Apps view — Launcher grid for installed applications.

Scans for registered apps and displays touch-friendly launch buttons.
Apps register by dropping a JSON descriptor into /opt/kalipi/apps.d/.
"""

import json
import os
import subprocess
import pygame
from dashboard.views.base import BaseView
from dashboard.theme import (
    CONTENT_Y, CONTENT_WIDTH, CONTENT_HEIGHT,
    TEXT, TEXT_DIM, TEXT_BRIGHT,
    SUCCESS, WARNING, DANGER, INFO, PRIMARY,
    BG_CARD, BORDER,
    FONT_BODY, FONT_SMALL,
    PAD, PAD_SM, PAD_LG,
    TAB_BAR_HEIGHT,
)

APPS_DIR = "/opt/kalipi/apps.d"

# Built-in quick actions (always available)
BUILTIN_ACTIONS = [
    {
        "name": "Security Check",
        "desc": "Run full security audit",
        "cmd": "/opt/kalipi/scripts/security-check.sh --cron",
        "icon": "SEC",
        "color": PRIMARY,
    },
    {
        "name": "Network Scan",
        "desc": "Scan local devices",
        "cmd": "/opt/kalipi/scripts/security-check.sh --cron --devices",
        "icon": "NET",
        "color": INFO,
    },
    {
        "name": "Reboot",
        "desc": "Restart the Pi",
        "cmd": "sudo reboot",
        "icon": "RBT",
        "confirm": True,
        "color": DANGER,
    },
]

# Grid layout for 480x320 content area
COLS = 3
BUTTON_W = 140
BUTTON_H = 65
BUTTON_PAD = 10
GRID_X_START = (CONTENT_WIDTH - (COLS * BUTTON_W + (COLS - 1) * BUTTON_PAD)) // 2


class AppsView(BaseView):
    title = "Apps"

    def __init__(self, screen, fonts):
        super().__init__(screen, fonts)
        self._apps = []
        self._buttons = []  # (rect, app_dict) for touch mapping
        self._confirm_pending = None  # app awaiting confirmation
        self._last_scan = 0
        self._scan_interval = 30  # re-scan apps.d every 30s
        self._status_msg = ""
        self._status_time = 0

    def _scan_apps(self):
        """Load app descriptors from apps.d directory."""
        import time
        now = time.time()
        if now - self._last_scan < self._scan_interval and self._apps:
            return
        self._last_scan = now

        apps = list(BUILTIN_ACTIONS)

        if os.path.isdir(APPS_DIR):
            for fname in sorted(os.listdir(APPS_DIR)):
                if not fname.endswith(".json"):
                    continue
                try:
                    with open(os.path.join(APPS_DIR, fname)) as f:
                        app = json.load(f)
                    if "name" in app and "cmd" in app:
                        app.setdefault("icon", app["name"][:3].upper())
                        app.setdefault("color", PRIMARY)
                        if isinstance(app["color"], list):
                            app["color"] = tuple(app["color"])
                        apps.append(app)
                except Exception:
                    continue

        self._apps = apps

    def render(self, data):
        self._fill_bg()
        self._scan_apps()
        self._buttons = []

        y = CONTENT_Y + PAD_SM

        if self._confirm_pending:
            self._render_confirm(y)
            return

        y += self._section_header("QUICK ACTIONS", y)
        y += PAD_SM

        # Render button grid
        col = 0
        for app in self._apps:
            bx = GRID_X_START + col * (BUTTON_W + BUTTON_PAD)
            by = y

            color = app.get("color", PRIMARY)
            if isinstance(color, list):
                color = tuple(color)

            rect = pygame.Rect(bx, by, BUTTON_W, BUTTON_H)
            self._buttons.append((rect, app))

            # Button background
            pygame.draw.rect(self.screen, BG_CARD, rect, border_radius=6)
            pygame.draw.rect(self.screen, color, rect, width=2, border_radius=6)

            # Icon text (top center)
            icon = app.get("icon", "?")
            icon_surf = self.fonts["body"].render(icon, True, color)
            self.screen.blit(
                icon_surf,
                (bx + (BUTTON_W - icon_surf.get_width()) // 2, by + 8)
            )

            # Name (bottom center)
            name = app.get("name", "?")
            if len(name) > 16:
                name = name[:14] + ".."
            name_surf = self.fonts["small"].render(name, True, TEXT)
            self.screen.blit(
                name_surf,
                (bx + (BUTTON_W - name_surf.get_width()) // 2, by + 35)
            )

            # Description (below name, tiny)
            desc = app.get("desc", "")
            if desc:
                if len(desc) > 20:
                    desc = desc[:18] + ".."
                desc_surf = self.fonts["tiny"].render(desc, True, TEXT_DIM)
                self.screen.blit(
                    desc_surf,
                    (bx + (BUTTON_W - desc_surf.get_width()) // 2, by + 50)
                )

            col += 1
            if col >= COLS:
                col = 0
                y += BUTTON_H + BUTTON_PAD

        # Status message (e.g. "Running security check...")
        import time
        if self._status_msg and time.time() - self._status_time < 10:
            msg_y = CONTENT_Y + CONTENT_HEIGHT - 20
            self._text(self._status_msg, PAD_LG, msg_y, "small", INFO)

    def _render_confirm(self, y):
        """Render a confirmation dialog for destructive actions."""
        app = self._confirm_pending
        y += 30
        self._text(f"Confirm: {app['name']}?", PAD_LG, y, "title", WARNING)
        y += 22
        self._text(app.get("desc", ""), PAD_LG, y, "body", TEXT_DIM)
        y += 30

        # Yes / No buttons
        yes_rect = pygame.Rect(80, y, 120, 44)
        no_rect = pygame.Rect(280, y, 120, 44)

        pygame.draw.rect(self.screen, DANGER, yes_rect, border_radius=6)
        pygame.draw.rect(self.screen, BG_CARD, no_rect, border_radius=6)
        pygame.draw.rect(self.screen, BORDER, no_rect, width=1, border_radius=6)

        yes_surf = self.fonts["body"].render("Yes", True, TEXT_BRIGHT)
        no_surf = self.fonts["body"].render("Cancel", True, TEXT)
        self.screen.blit(
            yes_surf,
            (yes_rect.centerx - yes_surf.get_width() // 2,
             yes_rect.centery - yes_surf.get_height() // 2)
        )
        self.screen.blit(
            no_surf,
            (no_rect.centerx - no_surf.get_width() // 2,
             no_rect.centery - no_surf.get_height() // 2)
        )

        self._buttons = [(yes_rect, {"_action": "confirm_yes"}),
                         (no_rect, {"_action": "confirm_no"})]

    def handle_touch(self, pos, data):
        """Handle button presses."""
        import time
        for rect, app in self._buttons:
            if rect.collidepoint(pos):
                # Confirmation dialog actions
                if app.get("_action") == "confirm_yes":
                    self._launch(self._confirm_pending)
                    self._confirm_pending = None
                    return
                elif app.get("_action") == "confirm_no":
                    self._confirm_pending = None
                    return

                # Regular button press
                if app.get("confirm"):
                    self._confirm_pending = app
                else:
                    self._launch(app)
                return

    def _launch(self, app):
        """Launch an app command in the background."""
        import time
        cmd = app.get("cmd", "")
        if not cmd:
            return
        self._status_msg = f"Running: {app.get('name', cmd)}"
        self._status_time = time.time()
        try:
            subprocess.Popen(
                cmd, shell=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
        except Exception:
            self._status_msg = f"Failed to launch: {app.get('name', '?')}"
            self._status_time = time.time()
