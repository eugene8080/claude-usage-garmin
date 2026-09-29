"""Regenerate every text bitmap font the Claude Grid face needs, into resources/fonts.

The face's typeface is the (TTF, FACE, WEIGHT) setting below - swap it to change the whole face.
Current: IBM Plex Mono Regular (static TTF), the synthwave design from the layout editor, 2026-09-25.
Before it: Roboto Mono Regular (400), and before that Chivo Mono Medium (500) - both kept in tools/;
set TTF/FACE/WEIGHT back to switch.

Those two are variable fonts (weight axis), pinned to one weight per atlas; IBM Plex Mono is a
static TTF, so WEIGHT is None. Sizes come straight from the
layout editor's final numbers. Each atlas carries only the glyphs its fields draw so the big sizes
stay small (the 153px time and its outline are digits only). Run tools/build_glow_digits.py
afterwards: the VFD time bitmaps are cut from cg_time.

Run from anywhere:  python garmin/faces/grid/tools/build_fonts_grid.py
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "resources", "fonts")
# genfont and the IBM Plex Mono TTF are shared with Claude Terminal: garmin/shared/tools/.
SHARED_TOOLS = os.path.join(HERE, "..", "..", "..", "shared", "tools")
sys.path.insert(0, SHARED_TOOLS)
from genfont import generate  # noqa: E402  (garmin/shared/tools/genfont.py)

# --- the face's typeface ---------------------------------------------------------------------
TTF = os.path.join(SHARED_TOOLS, "IBMPlexMono-Regular.ttf")   # OFL - shared/tools/IBMPlexMono-OFL.txt
FACE = "IBM Plex Mono"
WEIGHT = None  # static Regular TTF - no weight axis (the synthwave design, editor 2026-09-25)
# Previous faces, kept in tools/ - set TTF/FACE/WEIGHT back to switch:
# TTF, FACE, WEIGHT = os.path.join(HERE, "RobotoMono-VariableFont_wght.ttf"), "Roboto Mono", 400
# TTF, FACE, WEIGHT = os.path.join(HERE, "ChivoMono-VariableFont_wght.ttf"), "Chivo Mono", 500
DIGITS = "0123456789"
UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
# space, colon, percent, slash, dot, minus, degree + the punctuation complication values can carry,
# and the tilde that marks a weather value read from the stored forecast (WeatherNow's offline
# fallback: "~31°").
# The fonts have NO lowercase: the face upper-cases every value/label, so anything missing here
# would draw as a tofu box (e.g. "Fri"/"Sep" before values were upper-cased).
SYM = " :%/.-°,+'()!?&#~"

# (out_base, size, glyphs, atlas_w, stroke)
FONTS = [
    ("cg_time",   153, DIGITS,               512, 0),   # stacked HH / MM
    ("cg_time_o", 153, DIGITS,               512, 2),   # always-on OUTLINE time: 2 px, anti-aliased (Iron Grit weight)
    ("cg_big",     36, DIGITS + UPPER + SYM, 512, 0),   # ring values, brand text, date
    ("cg_med",     30, DIGITS + UPPER + SYM, 512, 0),   # chip values, alt-tz, seconds value
    ("cg_week",    27, UPPER,                256, 0),   # weekday strip letters
    ("cg_small",   24, DIGITS + UPPER + SYM, 256, 0),   # battery %, SEC label
    ("cg_tiny",    20, DIGITS + UPPER + SYM, 256, 0),   # last-resort value font for narrow corner slots
]

for out_base, size, chars, atlas_w, stroke in FONTS:
    generate(TTF, os.path.join(OUT, out_base), size, chars, atlas_w, FACE,
             weight=WEIGHT, stroke=stroke)

# --- per-field icon font, from Tabler Icons (MIT). Same set the editor embeds, incl. the
# footprints (steps), globe (alt time zone) and alarm-clock (indicator) glyphs. ------------
ICON_TTF = os.path.join(HERE, "tabler-icons.ttf")
ICONS = [
    0xea34,   # battery
    0x10265,  # footprints          -> STEPS (editor artwork)
    0xef92,   # heartbeat           -> HEART_RATE
    0xea38,   # bolt                -> BODY_BATTERY
    0xea97,   # droplet             -> PULSE_OX fallback
    0xec2c,   # flame               -> CALORIES
    0xeca5,   # stairs-up           -> FLOORS_CLIMBED
    0xef97,   # mountain            -> ALTITUDE
    0xf0db,   # activity-heartbeat  -> STRESS
    0xff9b,   # stopwatch           -> INTENSITY_MINUTES / stopwatch indicator
    0xea35,   # bell                -> NOTIFICATION_COUNT
    0xef1c,   # sunrise             -> SUNRISE
    0xec31,   # sunset              -> SUNSET
    0xea76,   # cloud               -> WEATHER default
    0xeaf8,   # moon                -> SLEEP_SCORE
    0xf228,   # zzz                 -> RECOVERY_TIME
    0xeb30,   # sun                 -> SOLAR / weather clear
    0xec34,   # wind                -> weather windy
    0xea72,   # cloud-rain          -> weather rain
    0xea73,   # cloud-snow          -> weather snow
    0xea74,   # cloud-storm         -> weather thunderstorm
    0xecd9,   # cloud-fog           -> weather fog/haze
    0xec0b,   # snowflake           -> weather cold
    0xeb54,   # world               -> ALT TIME ZONE
    0xea04,   # alarm               -> alarm indicator
    0xef62,   # lungs               -> RESPIRATION_RATE
    0xeb38,   # temperature         -> CURRENT_TEMPERATURE
    0xec82,   # run                 -> VO2MAX_RUN
    0xea36,   # bike                -> VO2MAX_BIKE
    0xeb43,   # trending-up         -> TRAINING_STATUS
    # Face-computed fields (the per-slot "field" setting; Garmin has no complication for them):
    0xebf1,   # umbrella            -> chance of rain
    0xea25,   # arrow-up            -> wind: the way the air moves, N (a wind FROM the south)
    0xea24,   # arrow-up-right      -> ... NE
    0xea1f,   # arrow-right         -> ... E
    0xea15,   # arrow-down-right    -> ... SE
    0xea16,   # arrow-down          -> ... S
    0xea13,   # arrow-down-left     -> ... SW
    0xea19,   # arrow-left          -> ... W
    0xea22,   # arrow-up-left       -> ... NW
    # Battery drawn at its charge level, like Garmin's own battery icon (battery = empty):
    0xea2f,   # battery-1           -> 1 bar
    0xea30,   # battery-2           -> 2 bars
    0xea31,   # battery-3           -> 3 bars
    0xea32,   # battery-4           -> full
    0xea33,   # battery-charging    -> on the charger
]
# CIQ addresses font glyphs by 16-bit code only, so anything Tabler files above U+FFFF is
# re-filed under a free BMP private-use code (source glyph -> emitted id). The face must ask for
# the EMITTED code: ClaudeGridView.iconCodeFor returns 0xE000 for steps.
ICON_REMAP = {
    0x10265: 0xE000,  # footprints (steps) - drew as a tofu box when filed under U+10265
}

# --- solid weather icons ------------------------------------------------------------------------
# Garmin-style filled weather icons (clear / partly cloudy, day and night; cloudy; rain; snow;
# storm; fog; wind), built from the outline Tabler glyphs by garmin/shared/tools/weather_icons.py
# (this Tabler build has no *-filled glyphs) and filed at 0xE001-0xE00A (weather_icons.CODES).
# The faces ask for them by those codes (ClaudeGridView / ClaudeFaceView.weatherGlyph).
from weather_icons import CODES as WEATHER_CODES, render as render_weather  # noqa: E402

extras = [(WEATHER_CODES[k],) + render_weather(k, ICON_TTF, 24) for k in WEATHER_CODES]

# --- every other icon, solid ---------------------------------------------------------------------
# Garmin's watch-face icons are solid shapes; ours are drawn solid too, from the outline Tabler
# glyphs, by garmin/shared/tools/solid_icons.py (fill closed shapes with their inner detail knocked
# out, heavier strokes for line icons). Each is filed under the SAME code as its outline glyph, so
# the faces ask for the same codes as before. solid_icons.KEEP (the battery levels) stay outline
# glyphs, drawn by genfont directly.
from solid_icons import mode_for as solid_mode, render as render_solid  # noqa: E402
from solid_icons import HUMIDITY_BASE, HUMIDITY_STEPS, humidity as render_humidity  # noqa: E402
from solid_icons import RAIN_BASE, RAIN_STEPS, rain_chance as render_rain  # noqa: E402

KEPT = [c for c in ICONS if solid_mode(c) == "keep"]
extras += [(ICON_REMAP.get(c, c),) + render_solid(c, ICON_TTF, 24, solid_mode(c))
           for c in ICONS if solid_mode(c) != "keep"]
# The humidity droplet at each 20 % fill step (0xE010 empty ... 0xE015 full; solid_icons.humidity).
extras += [(HUMIDITY_BASE + i,) + render_humidity(i, ICON_TTF, 24) for i in range(HUMIDITY_STEPS + 1)]
# The chance-of-rain umbrella with 0-3 drops (0xE020 dry ... 0xE023 three drops; solid_icons.rain_chance).
extras += [(RAIN_BASE + i,) + render_rain(i, ICON_TTF, 24) for i in range(RAIN_STEPS + 1)]
generate(ICON_TTF, os.path.join(OUT, "cg_icon"), 24, "".join([chr(c) for c in KEPT]),
         512, "Tabler", emit_ids=[ICON_REMAP.get(c, c) for c in KEPT], extra=extras)

# --- time ink offset -> source/TimeInk.mc ------------------------------------------------------
# The face positions the time by its DIGITS, not the font's line box: a VCENTER anchor centres the
# line box, and where the digit ink sits inside it depends on the typeface (Chivo Mono: centred;
# Roboto Mono: 4 px low). The editor centres the digit ink too, so both agree for any font.
import re as _re
_TIME_PX = [f[1] for f in FONTS if f[0] == "cg_time"][0]
_fnt = open(os.path.join(OUT, "cg_time.fnt"), encoding="utf-8").read().splitlines()
_lh = int(_re.search(r"lineHeight=(\d+)", [l for l in _fnt if l.startswith("common")][0]).group(1))
_rows = [dict(kv.split("=") for kv in l.split()[1:]) for l in _fnt if l.startswith("char ")]
_top = min(int(r["yoffset"]) for r in _rows)
_bot = max(int(r["yoffset"]) + int(r["height"]) for r in _rows)
# +1: CIQ draws font glyphs one row below line top + yoffset (measured in the simulator).
_dy = int(round((_top + _bot) / 2.0 - _lh / 2.0)) + 1
with open(os.path.join(HERE, "..", "source", "TimeInk.mc"), "w", encoding="utf-8", newline="\n") as f:
    f.write("// Generated by tools/build_fonts_grid.py - do not edit.\n"
            "// Screen px the cg_time digit INK centre sits below a TEXT_JUSTIFY_VCENTER anchor\n"
            "// (%s %d px: ink rows %d-%d in a %d px line box, +1 for CIQ's glyph row offset).\n"
            "// The view subtracts it so the time's y is the centre of the digits themselves.\n"
            "module TimeInk {\n    const DY = %d;\n}\n" % (FACE, _TIME_PX, _top, _bot, _lh, _dy))
print("time ink offset: DY=%d (ink %d-%d, lineHeight %d)" % (_dy, _top, _bot, _lh))

# --- sanity: every atlas must carry ink (a blank atlas silently kills all text) ----------
print("\n--- ink check ---")
for out_base, size, chars, atlas_w, stroke in FONTS + [("cg_icon", 24, "", 512, 0)]:
    png = os.path.join(OUT, out_base + "_0.png")
    bb = Image.open(png).getchannel("A").getbbox()
    print("%-10s %s" % (out_base, "OK ink=" + str(bb) if bb else "!!! BLANK !!!"))
