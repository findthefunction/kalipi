#!/usr/bin/env python3
"""KaliPi Touchscreen Dashboard — Main entry point.

Multi-view security and monitoring dashboard for the 3.5" SPI LCD (480x320).
Touch-navigable with a tab bar at the bottom.

Usage:
    python3 -m dashboard.main           # run dashboard
    python3 -m dashboard.main --windowed # run in a window (for dev/testing)

Requires: pygame, runs on X11 (fbturbo) or direct framebuffer.
"""

import os
import sys
import time
import signal
import argparse

# Set SDL environment before importing pygame.
# On the Pi, X11 is started by xinit on fb1 (SPI LCD).
# Fallback to fbcon for direct framebuffer if no X11.
if not os.environ.get("DISPLAY"):
    os.environ.setdefault("SDL_VIDEODRIVER", "fbcon")
    os.environ.setdefault("SDL_FBDEV", "/dev/fb1")

import pygame

from dashboard.theme import (
    SCREEN_WIDTH, SCREEN_HEIGHT, FPS,
    HEADER_HEIGHT, TAB_BAR_HEIGHT, TAB_Y, TAB_WIDTH, TAB_COUNT,
    BG, BG_HEADER, BG_TAB, BG_TAB_ACTIVE,
    PRIMARY, TEXT, TEXT_DIM, TEXT_BRIGHT, BORDER,
    FONT_HEADER, FONT_TAB, FONT_TITLE, FONT_BODY, FONT_SMALL, FONT_TINY,
    CONTENT_Y,
)
from dashboard.data import DataCollector
from dashboard.views.security import SecurityView
from dashboard.views.alerts import AlertsView
from dashboard.views.network import NetworkView
from dashboard.views.trading import TradingView
from dashboard.views.apps import AppsView


def load_fonts():
    """Load fonts with fallbacks for Pi ARM64."""
    pygame.font.init()
    fonts = {}
    # Try common monospace fonts available on Kali ARM
    mono_names = [
        "dejavusansmono", "liberationmono", "ubuntumono",
        "droidsansmono", "couriernew", "monospace",
    ]
    # Try common sans fonts
    sans_names = [
        "dejavusans", "liberationsans", "ubuntusans",
        "droidsans", "arial", "sans",
    ]

    def pick_font(names, size):
        for name in names:
            f = pygame.font.SysFont(name, size)
            if f:
                return f
        return pygame.font.Font(None, size)

    fonts["header"] = pick_font(sans_names, FONT_HEADER)
    fonts["tab"] = pick_font(sans_names, FONT_TAB)
    fonts["title"] = pick_font(sans_names, FONT_TITLE)
    fonts["body"] = pick_font(mono_names, FONT_BODY)
    fonts["small"] = pick_font(mono_names, FONT_SMALL)
    fonts["tiny"] = pick_font(mono_names, FONT_TINY)
    return fonts


class Dashboard:
    """Main dashboard application."""

    TAB_LABELS = ["SEC", "ALRT", "NET", "TRAD", "APPS"]
    TAB_NAMES = ["Security", "Alerts", "Network", "Trading", "Apps"]

    def __init__(self, windowed=False):
        pygame.init()

        flags = 0 if windowed else pygame.FULLSCREEN
        if not windowed:
            # Hide mouse cursor on the LCD
            pygame.mouse.set_visible(False)

        self.screen = pygame.display.set_mode(
            (SCREEN_WIDTH, SCREEN_HEIGHT), flags
        )
        pygame.display.set_caption("KaliPi Dashboard")

        self.clock = pygame.time.Clock()
        self.fonts = load_fonts()
        self.running = True
        self.active_tab = 0

        # Initialize views
        self.views = [
            SecurityView(self.screen, self.fonts),
            AlertsView(self.screen, self.fonts),
            NetworkView(self.screen, self.fonts),
            TradingView(self.screen, self.fonts),
            AppsView(self.screen, self.fonts),
        ]

        # Data collector
        self.collector = DataCollector()
        self.collector.start(interval=10)

        # Touch state
        self._touch_start = None
        self._last_render = 0

    def run(self):
        """Main event loop."""
        signal.signal(signal.SIGTERM, lambda *_: self._quit())
        signal.signal(signal.SIGINT, lambda *_: self._quit())

        while self.running:
            self._handle_events()
            self._render()
            self.clock.tick(FPS)

        self._cleanup()

    def _handle_events(self):
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                self._quit()

            elif event.type == pygame.KEYDOWN:
                if event.key in (pygame.K_ESCAPE, pygame.K_q):
                    self._quit()
                elif event.key == pygame.K_LEFT:
                    self.active_tab = (self.active_tab - 1) % len(self.views)
                    self.views[self.active_tab].scroll_offset = 0
                elif event.key == pygame.K_RIGHT:
                    self.active_tab = (self.active_tab + 1) % len(self.views)
                    self.views[self.active_tab].scroll_offset = 0

            elif event.type == pygame.MOUSEBUTTONDOWN:
                if event.button == 1:
                    self._on_touch(event.pos)
                elif event.button == 4:  # Scroll up
                    self.views[self.active_tab].handle_scroll(-1)
                elif event.button == 5:  # Scroll down
                    self.views[self.active_tab].handle_scroll(1)

            elif event.type == pygame.FINGERDOWN:
                # Normalize touch coordinates to screen coords
                x = int(event.x * SCREEN_WIDTH)
                y = int(event.y * SCREEN_HEIGHT)
                self._on_touch((x, y))

    def _on_touch(self, pos):
        """Handle a touch/click event."""
        x, y = pos

        # Check if touch is in tab bar
        if y >= TAB_Y:
            tab_idx = x // TAB_WIDTH
            if 0 <= tab_idx < len(self.views):
                self.active_tab = tab_idx
                self.views[self.active_tab].scroll_offset = 0
            return

        # Pass to active view for in-content touch handling
        data = self.collector.data
        self.views[self.active_tab].handle_touch(pos, data)

    def _render(self):
        """Render the full dashboard frame."""
        data = self.collector.data

        # Header
        self._draw_header(data)

        # Active view content
        self.views[self.active_tab].render(data)

        # Tab bar
        self._draw_tab_bar()

        pygame.display.flip()

    def _draw_header(self, data):
        """Draw the top header bar."""
        header_rect = pygame.Rect(0, 0, SCREEN_WIDTH, HEADER_HEIGHT)
        pygame.draw.rect(self.screen, BG_HEADER, header_rect)
        pygame.draw.line(
            self.screen, BORDER, (0, HEADER_HEIGHT - 1), (SCREEN_WIDTH, HEADER_HEIGHT - 1)
        )

        # Title
        title = self.fonts["header"].render("KALIPi", True, PRIMARY)
        self.screen.blit(title, (8, 5))

        # Active view name
        view_name = self.TAB_NAMES[self.active_tab]
        name_surf = self.fonts["header"].render(view_name, True, TEXT_DIM)
        self.screen.blit(name_surf, (80, 5))

        # CPU temp indicator (right side)
        temp = data.get("cpu_temp", 0)
        temp_color = (255, 68, 68) if temp > 80 else (255, 187, 51) if temp > 70 else TEXT_DIM
        temp_surf = self.fonts["small"].render(f"{temp}C", True, temp_color)
        self.screen.blit(temp_surf, (SCREEN_WIDTH - 90, 7))

        # Clock (right side)
        now = time.strftime("%H:%M:%S")
        clock_surf = self.fonts["small"].render(now, True, TEXT_DIM)
        self.screen.blit(clock_surf, (SCREEN_WIDTH - 55, 7))

    def _draw_tab_bar(self):
        """Draw the bottom tab bar with touch targets."""
        bar_rect = pygame.Rect(0, TAB_Y, SCREEN_WIDTH, TAB_BAR_HEIGHT)
        pygame.draw.rect(self.screen, BG_TAB, bar_rect)
        pygame.draw.line(
            self.screen, BORDER, (0, TAB_Y), (SCREEN_WIDTH, TAB_Y)
        )

        for i, label in enumerate(self.TAB_LABELS):
            tx = i * TAB_WIDTH
            tab_rect = pygame.Rect(tx, TAB_Y, TAB_WIDTH, TAB_BAR_HEIGHT)

            if i == self.active_tab:
                pygame.draw.rect(self.screen, BG_TAB_ACTIVE, tab_rect)
                # Active indicator line at top of tab
                pygame.draw.line(
                    self.screen, PRIMARY,
                    (tx + 4, TAB_Y), (tx + TAB_WIDTH - 4, TAB_Y), 2
                )
                color = PRIMARY
            else:
                color = TEXT_DIM

            # Center the label in the tab
            lbl_surf = self.fonts["tab"].render(label, True, color)
            lx = tx + (TAB_WIDTH - lbl_surf.get_width()) // 2
            ly = TAB_Y + (TAB_BAR_HEIGHT - lbl_surf.get_height()) // 2
            self.screen.blit(lbl_surf, (lx, ly))

            # Divider between tabs
            if i < len(self.TAB_LABELS) - 1:
                pygame.draw.line(
                    self.screen, BORDER,
                    (tx + TAB_WIDTH, TAB_Y + 6),
                    (tx + TAB_WIDTH, TAB_Y + TAB_BAR_HEIGHT - 6)
                )

    def _quit(self):
        self.running = False

    def _cleanup(self):
        self.collector.stop()
        pygame.quit()


def main():
    parser = argparse.ArgumentParser(description="KaliPi Touchscreen Dashboard")
    parser.add_argument(
        "--windowed", action="store_true",
        help="Run in a window instead of fullscreen (for development)"
    )
    args = parser.parse_args()

    dashboard = Dashboard(windowed=args.windowed)
    dashboard.run()


if __name__ == "__main__":
    main()
