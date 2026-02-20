"""Base view class for KaliPi Dashboard."""

import pygame
from dashboard.theme import (
    CONTENT_Y, CONTENT_HEIGHT, CONTENT_WIDTH,
    BG_CONTENT, TEXT, TEXT_DIM, TEXT_BRIGHT,
    SUCCESS, WARNING, DANGER, INFO, PRIMARY,
    BG_CARD, BORDER,
    FONT_TITLE, FONT_BODY, FONT_SMALL, FONT_TINY,
    PAD, PAD_SM, PAD_LG,
)


class BaseView:
    """Base class for dashboard views. Subclasses override render()."""

    title = "View"

    def __init__(self, screen, fonts):
        self.screen = screen
        self.fonts = fonts
        self.content_rect = pygame.Rect(0, CONTENT_Y, CONTENT_WIDTH, CONTENT_HEIGHT)
        self.scroll_offset = 0
        self.max_scroll = 0

    def render(self, data):
        """Override in subclass. Draw the view content."""
        self._fill_bg()

    def handle_touch(self, pos, data):
        """Handle touch events within the content area. Override if needed."""
        pass

    def handle_scroll(self, direction):
        """Scroll content. direction: -1 = up, 1 = down."""
        self.scroll_offset = max(
            0, min(self.max_scroll, self.scroll_offset + direction * 20)
        )

    # ── Drawing helpers ──────────────────────────────────────

    def _fill_bg(self):
        pygame.draw.rect(self.screen, BG_CONTENT, self.content_rect)

    def _text(self, text, x, y, font_key="body", color=TEXT):
        font = self.fonts.get(font_key, self.fonts["body"])
        surf = font.render(str(text), True, color)
        self.screen.blit(surf, (x, y))
        return surf.get_height()

    def _section_header(self, text, y):
        """Draw a section header with a subtle underline."""
        h = self._text(text, PAD_LG, y, "title", PRIMARY)
        pygame.draw.line(
            self.screen, BORDER,
            (PAD_LG, y + h + 1),
            (CONTENT_WIDTH - PAD_LG, y + h + 1)
        )
        return h + PAD_SM + 2

    def _card(self, x, y, w, h):
        """Draw a card/panel background."""
        rect = pygame.Rect(x, y, w, h)
        pygame.draw.rect(self.screen, BG_CARD, rect, border_radius=4)
        pygame.draw.rect(self.screen, BORDER, rect, width=1, border_radius=4)
        return rect

    def _status_dot(self, x, y, active):
        """Draw a colored status indicator dot."""
        color = SUCCESS if active else DANGER
        pygame.draw.circle(self.screen, color, (x, y), 4)

    def _bar(self, x, y, w, h, pct, color=PRIMARY):
        """Draw a progress bar."""
        bg_rect = pygame.Rect(x, y, w, h)
        pygame.draw.rect(self.screen, BORDER, bg_rect, border_radius=2)
        fill_w = max(1, int(w * min(pct, 100) / 100))
        fill_rect = pygame.Rect(x, y, fill_w, h)

        # Color by severity
        if pct > 90:
            bar_color = DANGER
        elif pct > 75:
            bar_color = WARNING
        else:
            bar_color = color

        pygame.draw.rect(self.screen, bar_color, fill_rect, border_radius=2)

    def _kv(self, label, value, x, y, label_color=TEXT_DIM, value_color=TEXT):
        """Draw a key-value pair on one line."""
        lw = self.fonts["small"].render(label, True, label_color)
        vw = self.fonts["body"].render(str(value), True, value_color)
        self.screen.blit(lw, (x, y + 1))
        self.screen.blit(vw, (x + lw.get_width() + PAD_SM, y))
        return max(lw.get_height(), vw.get_height())
