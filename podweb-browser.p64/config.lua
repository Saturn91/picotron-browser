--[[pod_format="raw",created="2026-04-17 10:47:47",modified="2026-04-26 12:36:39",revision=28,xstickers={}]]
-- Screen dimensions, layout metrics, and network configuration

VERSION      = "1.5.0"

W, H         = 320, 180
BAR_H        = 16
PAD_X        = 6
CONT_W       = W - PAD_X * 2
LINE_H       = 8
CHAR_W       = 4

DOMAINS_FILE = "/appdata/podweb-browser/domains.lookup"
CONFIG_FILE  = "/appdata/podweb-browser/settings.pod"
HOME_URL     = "podnet://48932/index.podweb"

BACK_BTN     = { x=4,    y=2, w=12, h=12, sprite=3 }
FORWARD_BTN  = { x=20,   y=2, w=12, h=12, sprite=4 }
RELOAD_BTN   = { x=36,   y=2, w=12, h=12, sprite=2 }
COPY_BTN     = { x=W-32, y=2, w=12, h=12, sprite=5 }
SUBMIT_BTN   = { x=W-16, y=2, w=12, h=12, sprite=1 }

DEFAULT_COLORS = {
    bg               = 1,
    text             = 6,
    h1               = 7,
    h2               = 12,
    h3               = 12,
    link             = 30,
    link_hover       = 29,
    btn_bg           = 1,
    btn_bg_hover     = 5,
    btn_border       = 5,
    btn_border_hover = 1,
    btn_text         = 7,
}
