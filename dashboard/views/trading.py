"""Trading view — Price feeds, logic engine status, and clawbot connection.

This view is a framework for displaying trading-related data.
It reads from a JSON status file that trading apps will write to.
Initially shows placeholder UI; populated once trading services are installed.
"""

import json
import os
import pygame
from dashboard.views.base import BaseView
from dashboard.theme import (
    CONTENT_Y, CONTENT_WIDTH, CONTENT_HEIGHT,
    TEXT, TEXT_DIM, TEXT_BRIGHT,
    SUCCESS, WARNING, DANGER, INFO, PRIMARY,
    BG_CARD, BORDER,
    PAD, PAD_SM, PAD_LG,
)

TRADING_STATUS_FILE = "/tmp/kalipi/trading-status.json"


class TradingView(BaseView):
    title = "Trading"

    def _load_trading_data(self):
        """Load trading status from the shared JSON file."""
        if not os.path.isfile(TRADING_STATUS_FILE):
            return None
        try:
            with open(TRADING_STATUS_FILE) as f:
                return json.load(f)
        except Exception:
            return None

    def render(self, data):
        self._fill_bg()
        y = CONTENT_Y + PAD_SM

        trading = self._load_trading_data()

        if trading is None:
            self._render_placeholder(y)
        else:
            self._render_live(y, trading, data)

    def _render_placeholder(self, y):
        """Show setup instructions when no trading services are running."""
        y += self._section_header("TRADING ENGINE", y)

        self._text("No trading services detected", PAD_LG, y, "body", TEXT_DIM)
        y += 22

        self._text("Expected data sources:", PAD_LG, y, "small", TEXT_DIM)
        y += 18

        items = [
            "Logic engine status",
            "Price scraping feeds",
            "ClawBot connection state",
            "Active positions / signals",
        ]
        for item in items:
            self._text(f"  - {item}", PAD_LG, y, "small", INFO)
            y += 16

        y += 12
        self._text("Trading apps write status to:", PAD_LG, y, "small", TEXT_DIM)
        y += 16
        self._text(f"  {TRADING_STATUS_FILE}", PAD_LG, y, "small", PRIMARY)
        y += 24

        # Show expected JSON format
        self._text("Expected JSON format:", PAD_LG, y, "small", TEXT_DIM)
        y += 16
        example_lines = [
            '{ "engine_status": "running",',
            '  "clawbot_connected": true,',
            '  "feeds": [{"symbol":"BTC",...}],',
            '  "positions": [...],',
            '  "last_signal": "..." }',
        ]
        for line in example_lines:
            self._text(line, PAD_LG + 8, y, "tiny", TEXT_DIM)
            y += 12

    def _render_live(self, y, trading, sys_data):
        """Render live trading data when available."""
        # ── Engine status ────────────────────────────────────
        y += self._section_header("LOGIC ENGINE", y)
        engine = trading.get("engine_status", "unknown")
        engine_ok = engine in ("running", "active")
        self._status_dot(PAD_LG + 4, y + 7, engine_ok)
        self._text(
            f"Engine: {engine}", PAD_LG + 14, y, "body",
            SUCCESS if engine_ok else DANGER
        )
        y += 20

        # ── ClawBot connection ───────────────────────────────
        y += self._section_header("CLAWBOT", y)
        cb_connected = trading.get("clawbot_connected", False)
        cb_latency = trading.get("clawbot_latency_ms", "?")
        self._status_dot(PAD_LG + 4, y + 7, cb_connected)
        self._text(
            f"{'Connected' if cb_connected else 'Disconnected'}",
            PAD_LG + 14, y, "body",
            SUCCESS if cb_connected else DANGER
        )
        if cb_connected:
            self._kv("Latency:", f"{cb_latency}ms", 250, y)
        y += 20

        # ── Price feeds ──────────────────────────────────────
        y += self._section_header("PRICE FEEDS", y)
        feeds = trading.get("feeds", [])
        if feeds:
            for feed in feeds[:8]:
                symbol = feed.get("symbol", "?")
                price = feed.get("price", "?")
                change = feed.get("change_pct", 0)
                change_color = SUCCESS if change >= 0 else DANGER
                change_str = f"+{change:.2f}%" if change >= 0 else f"{change:.2f}%"

                self._text(symbol, PAD_LG, y, "body", TEXT_BRIGHT)
                self._text(str(price), 100, y, "body", TEXT)
                self._text(change_str, 250, y, "small", change_color)
                y += 16
        else:
            self._text("No feeds active", PAD_LG, y, "small", TEXT_DIM)
            y += 16

        y += PAD

        # ── Last signal ──────────────────────────────────────
        last_signal = trading.get("last_signal", "")
        if last_signal:
            y += self._section_header("LAST SIGNAL", y)
            if len(last_signal) > 55:
                last_signal = last_signal[:52] + "..."
            self._text(last_signal, PAD_LG, y, "small", INFO)
