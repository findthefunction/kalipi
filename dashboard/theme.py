"""KaliPi Dashboard — Theme constants for 480x320 SPI LCD."""

# Display
SCREEN_WIDTH = 480
SCREEN_HEIGHT = 320
FPS = 30

# Layout regions
HEADER_HEIGHT = 28
TAB_BAR_HEIGHT = 44
CONTENT_Y = HEADER_HEIGHT
CONTENT_HEIGHT = SCREEN_HEIGHT - HEADER_HEIGHT - TAB_BAR_HEIGHT
CONTENT_WIDTH = SCREEN_WIDTH

# Tab bar
TAB_COUNT = 5
TAB_WIDTH = SCREEN_WIDTH // TAB_COUNT  # 96px each
TAB_Y = SCREEN_HEIGHT - TAB_BAR_HEIGHT

# Touch target minimum (44px per Apple HIG — important for 3.5" screen)
TOUCH_MIN = 44

# Colors — Kali-inspired dark theme
BG = (13, 17, 23)             # #0d1117 — main background
BG_HEADER = (22, 27, 34)      # #161b22 — header bar
BG_TAB = (22, 27, 34)         # #161b22 — tab bar
BG_TAB_ACTIVE = (48, 54, 61)  # #30363d — active tab
BG_CARD = (22, 27, 34)        # #161b22 — card/panel background
BG_CONTENT = (13, 17, 23)     # #0d1117 — content area

PRIMARY = (54, 123, 240)      # #367bf0 — Kali blue
SUCCESS = (0, 200, 81)        # #00c851 — green
WARNING = (255, 187, 51)      # #ffbb33 — amber
DANGER = (255, 68, 68)        # #ff4444 — red
INFO = (100, 180, 255)        # #64b4ff — light blue

TEXT = (230, 230, 230)         # #e6e6e6 — primary text
TEXT_DIM = (139, 148, 158)     # #8b949e — secondary text
TEXT_BRIGHT = (255, 255, 255)  # #ffffff — emphasis

BORDER = (48, 54, 61)         # #30363d — borders/dividers

# Font sizes (tuned for 480x320 at ~3.5")
FONT_HEADER = 16
FONT_TAB = 13
FONT_TITLE = 15
FONT_BODY = 13
FONT_SMALL = 11
FONT_TINY = 10

# Padding
PAD = 6
PAD_SM = 3
PAD_LG = 10
