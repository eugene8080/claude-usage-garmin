"""Regenerate every Chakra Petch bitmap font the Claude Grid face needs, into resources/fonts.

Each font carries only the glyphs its fields actually draw, so the big sizes stay small:
the 120px time and 36px ring fonts are digits only; value/small/label carry letters + symbols.
Run from anywhere:  python garmin/faces/grid/tools/build_fonts.py
"""
import os
import sys

# genfont is shared by both faces' font builders, so it lives in garmin/shared/tools/.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "shared", "tools"))
from genfont import generate  # noqa: E402  (garmin/shared/tools/genfont.py)

TTF = os.path.join(os.path.dirname(__file__), "ChakraPetch-SemiBold.ttf")
OUT = os.path.join(os.path.dirname(__file__), "..", "resources", "fonts")

DIGITS = "0123456789"
UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
LOWER = "abcdefghijklmnopqrstuvwxyz"
DEG = "°"  # degree sign, for the "C" (temperature) label

# (out_base, size, glyphs, atlas_w) -- sizes come straight from the layout editor:
#   time 64*1.88, ring value 22*1.64, chip/date value 22*1.4-1.48, small(batt/week) 22, label 11*1.5.
FONTS = [
    ("cp_time",  120, DIGITS,                             512),  # stacked HH / MM
    ("cp_ring",   36, DIGITS + "%/.-" + DEG,              256),  # HR/BB/SEC, Claude %, temps
    ("cp_value",  32, DIGITS + UPPER + " %/.-" + DEG,     256),  # chip values, date, %, temps (deg/slash/minus)
    ("cp_small",  22, DIGITS + UPPER + "% ",              256),  # battery %, weekday letters
    ("cp_label",  16, DIGITS + UPPER + LOWER + DEG + " ", 256),  # field labels (ST, HR, mb, VO2, degC...)
]

for out_base, size, chars, atlas_w in FONTS:
    generate(TTF, os.path.join(OUT, out_base), size, chars, atlas_w)

# --- per-field icon font, generated from Tabler Icons (MIT) ---------------------------------
# Each editable slot draws the icon for whatever complication is assigned. Codepoints are the
# Tabler webfont glyphs (see tools/tabler-icons.ttf); names kept here for maintenance. Weather
# variants (rain/snow/storm/fog/flake) are used by the weather-reactive picker.
ICON_TTF = os.path.join(os.path.dirname(__file__), "tabler-icons.ttf")
ICONS = [
    0xea34,  # battery            -> BATTERY
    0xec87,  # walk               -> STEPS
    0xef92,  # heartbeat          -> HEART_RATE
    0xea38,  # bolt               -> BODY_BATTERY
    0xef62,  # lungs              -> VO2MAX / RESPIRATION
    0xeab1,  # gauge              -> PRESSURE
    0xeb38,  # temperature        -> TEMPERATURE
    0xec2c,  # flame              -> CALORIES
    0xeca5,  # stairs-up          -> FLOORS_CLIMBED
    0xef97,  # mountain           -> ALTITUDE
    0xf0db,  # activity-heartbeat -> STRESS
    0xea97,  # droplet            -> PULSE_OX
    0xff9b,  # stopwatch          -> INTENSITY_MINUTES
    0xea35,  # bell               -> NOTIFICATION_COUNT
    0xef1c,  # sunrise            -> SUNRISE
    0xec31,  # sunset             -> SUNSET
    0xea76,  # cloud              -> WEATHER (default)
    0xea53,  # calendar           -> DATE
    0xeaf8,  # moon               -> SLEEP_SCORE
    0xf228,  # zzz                -> RECOVERY_TIME
    0xeb30,  # sun                -> SOLAR_INPUT / weather: clear
    0xefb1,  # circle-dot         -> fallback
    0xec34,  # wind               -> weather: windy
    0xea72,  # cloud-rain         -> weather: rain
    0xea73,  # cloud-snow         -> weather: snow
    0xea74,  # cloud-storm        -> weather: thunderstorm
    0xecd9,  # cloud-fog          -> weather: fog/haze
    0xec0b,  # snowflake          -> weather: cold
]
generate(ICON_TTF, os.path.join(OUT, "cp_icon"), 24, "".join([chr(c) for c in ICONS]), 512, "Tabler")
