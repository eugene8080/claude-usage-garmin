"""Build the Claude Grid icon picker: every field icon the face can draw, next to Garmin's own
watch-face icon for the same field, as a tap-to-choose page whose picks come out as copyable text.

    python build_icon_picker.py
        -> icon-picker.html (committed). Garmin's icons are LOADED FROM GARMIN'S SITE when the page
           is viewed (the URLs their support article uses), never stored in this public repo, so
           that column needs a connection and a viewer that allows remote images.

    python build_icon_picker.py --embed-garmin OUT.html [--artifact]
        -> a PRIVATE copy with Garmin's icons embedded (fetched once into .garmin-icons/, which is
           gitignored), for viewers that block remote images, e.g. the Claude app. --artifact leaves
           out the <!doctype>/<html>/<head> wrapper, which the Artifact publisher adds itself.
           Do not commit an embedded copy: the icons are Garmin's artwork.

Our icons are the solid versions the face draws (../../../shared/tools/solid_icons.py, from
../tools/tabler-icons.ttf - the same step that builds them into cg_icon, ../tools/build_fonts_grid.py); the solid weather set comes from ../../../shared/tools/weather_icons.py,
the same generator that builds those glyphs into the font. The ROWS
below restate which glyph the face draws for each field (ClaudeGridView.iconCodeFor,
weatherGlyph, fillField, batteryGlyph) - update them together.

Row numbers are what the user's picks refer to: only ever APPEND rows, never renumber.
"""
import argparse
import base64
import datetime
import html
import io
import os
import sys
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent.parent / "shared" / "tools"))
import weather_icons  # noqa: E402  (garmin/shared/tools/weather_icons.py)
import solid_icons  # noqa: E402  (garmin/shared/tools/solid_icons.py)

HERE = Path(__file__).resolve().parent
TTF = str(HERE.parent / "tools" / "tabler-icons.ttf")
PLEX = str(HERE.parent.parent.parent / "shared" / "tools" / "IBMPlexMono-Regular.ttf")
CACHE = HERE / ".garmin-icons"
SIZE = 72                  # render size for our glyphs (the watch draws them at 24 px)
TILE_IMG_H = 42            # display height of an icon inside a tile, px
ARTICLE = "https://support.garmin.com/en-HK/?faq=agZJiZRjhX2adgWkBVOHI9"
CDN = "https://atlaske-content.garmin.com/%2Fasset%2Fimages%2F"

# ---- Garmin's icons: file names from the support article ---------------------------------------
F = {
    "battery": "battery_level_Time1785335088705.png", "steps": "Steps_Time1785338182616.png",
    "hr": "Heart_Rate_Time1785336913513.png", "bb": "body_battery_final_Time1785335251726.png",
    "stress": "Stress_Time1785338230491.png", "spo2": "Pulse_Ox_Time1785337730774.png",
    "cal": "Calories_Time1785335444509.png", "floors": "Floors_Climbed_Time1785336869719.png",
    "alt": "Altimeter_Time1785334685250.png", "im": "Intensity_Minutes_Time1785337058765.png",
    "notif": "notifications_final_Time1785337680899.png", "sun": "Sunrise_Sunset_Time1785338278669.png",
    "resp": "Respiration_Rate_Time1785337923404.png", "recov": "Recovery_Time1785337877199.png",
    "solar": "solar_intensity_Time1785338104256.png", "ts": "Training_Status_Time1785338433165.png",
    "wx": "Weather_Time1785338931224.png", "alarm": "Alarm_Time1785334604896.png",
    "utc": "utc_Time1785338718046.png", "baro": "Barometric_Pressure_Time1785334967652.png",
    "calendar": "Calendar_Time1785335361739.png", "run": "Weekly_Running_Distance_Time1785339012464.png",
    "bike": "Weekly_Cycling_Distance_Time1785338972836.png", "golf": "Last_Golf_Time1785338607426.png",
}
# Garmin images that hold TWO separate icons: (natural width, height) and each icon's column range,
# measured from the PNGs. Everything else is one icon.
SPLIT = {"bb": ((146, 72), [(0, 70), (83, 145)]), "notif": ((134, 72), [(1, 54), (68, 133)])}
SPLIT_NAMES = {"bb": ["ring + figure", "figure + bolt"], "notif": ["bell", "message"]}
# Garmin draws almost all of these black on white; these few come white on dark.
LIGHT_ON_DARK = {"Calendar_Time1785335361739.png"}
G_ONLY = [("Acute Load", "Acute_Load_Time1785334328610.png"), ("Barometric Trend", "barometric_trend_Time1785334894979.png"),
          ("Dive Readiness", "dive_readiness_Time1785335589691.png"), ("Endurance Score", "Endurance_Score_Time1785335634279.png"),
          ("Event Countdown", "event_countdown_Time1785336765675.png"), ("Flashlight", "Flashlight_Time1785336816320.png"),
          ("Hill Score", "Hill_Score_Time1785336958385.png"), ("HRV Status", "HRV_Status_Time1785337006697.png"),
          ("Move Alert Bar", "move_alert_bar_Time1785337195385.png"), ("Music Player", "Music_Player_Time1785337251479.png"),
          ("Phone Connection", "Phone_Connection_Time1785337831621.png"), ("Timer", "Timer_Time1785338327266.png"),
          ("Training Readiness", "Training_Readiness_Time1785338375859.png"), ("Wallet", "Wallet_Time1785338838956.png")]


# ---- image helpers ----------------------------------------------------------------------------

def to_uri(alpha: Image.Image) -> str:
    """Coverage (mode L) -> a white glyph on transparent, cropped to its ink + 4 px, as a data URI."""
    bbox = alpha.getbbox()
    if bbox is None:
        raise ValueError("empty glyph")
    pad = 4
    alpha = alpha.crop((max(bbox[0] - pad, 0), max(bbox[1] - pad, 0), bbox[2] + pad, bbox[3] + pad))
    rgba = Image.new("RGBA", alpha.size, (255, 255, 255, 0))
    rgba.putalpha(alpha)
    buf = io.BytesIO()
    rgba.save(buf, "PNG", optimize=True)
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode("ascii")


def tabler(cp: int) -> str:
    """A face icon as the face draws it: the solid version of the Tabler glyph (solid_icons)."""
    img, _adv = solid_icons.render(cp, TTF, SIZE, solid_icons.mode_for(cp))
    return to_uri(img)


def weather(kind: str) -> str:
    """One of the face's solid weather icons (weather_icons.KINDS), rendered at SIZE."""
    img, _adv = weather_icons.render(kind, TTF, SIZE)
    return to_uri(img)


def ours(g) -> str:
    """A Tabler code point, or ("weather", kind) for the solid weather set."""
    return weather(g[1]) if isinstance(g, tuple) else tabler(g)


def city_tile(code: str, time: str) -> str:
    """The time-zone field as the face draws it now: the city code over the time."""
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="80" height="60">'
           '<text x="40" y="24" text-anchor="middle" font-family="IBM Plex Mono, monospace" '
           'font-size="17" font-weight="600" fill="#9aa0d0" letter-spacing="1">%s</text>'
           '<text x="40" y="48" text-anchor="middle" font-family="IBM Plex Mono, monospace" '
           'font-size="19" font-weight="600" fill="#ffffff">%s</text></svg>'
           % (html.escape(code), html.escape(time)))
    return "data:image/svg+xml;base64," + base64.b64encode(svg.encode()).decode("ascii")


def vo2() -> str:
    """Garmin's VO2 max marker as the tactix 8's native faces draw it: "VO" with a lowered "2".
    Bahnschrift SemiBold Condensed (Windows) is closest; IBM Plex Mono is the fallback."""
    try:
        big = ImageFont.truetype("C:/Windows/Fonts/bahnschrift.ttf", 64)
        big.set_variation_by_name("SemiBold Condensed")
        sub = ImageFont.truetype("C:/Windows/Fonts/bahnschrift.ttf", 38)
        sub.set_variation_by_name("SemiBold Condensed")
    except (OSError, ValueError):
        big, sub = ImageFont.truetype(PLEX, 56), ImageFont.truetype(PLEX, 34)
    im = Image.new("L", (220, 120), 0)
    d = ImageDraw.Draw(im)
    d.text((10, 10), "VO", font=big, fill=255)
    d.text((10 + int(big.getlength("VO")) + 1, 44), "2", font=sub, fill=255)
    return to_uri(im)


def text_tile(label: str) -> str:
    """The "text label" option: a short monospace word, as the face draws a field with no icon."""
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="90" height="40">'
           '<text x="45" y="27" text-anchor="middle" font-family="IBM Plex Mono, monospace" '
           'font-size="19" font-weight="600" fill="#ffffff" letter-spacing="1">%s</text></svg>'
           % html.escape(label))
    return "data:image/svg+xml;base64," + base64.b64encode(svg.encode()).decode("ascii")


class Garmin:
    """Renders a Garmin icon as tile markup: embedded (normalised to a white glyph, split with
    PIL) or linked (loaded from Garmin's CDN; inverted and split with CSS)."""

    def __init__(self, embed: bool):
        self.embed = embed

    def _local(self, fname: str) -> Path:
        path = CACHE / fname
        if not path.exists():
            CACHE.mkdir(exist_ok=True)
            req = urllib.request.Request(CDN + fname, headers={"User-Agent": "Mozilla/5.0"})
            data = urllib.request.urlopen(req, timeout=30).read()
            if not data.startswith(b"\x89PNG"):
                raise ValueError("%s: not a PNG" % fname)
            path.write_bytes(data)
        return path

    def _embedded_uri(self, fname: str, cols=None) -> str:
        """Coverage = darkness on a light background, brightness on a dark one, alpha on a
        transparent one - so every icon comes out as the same white glyph."""
        a = np.asarray(Image.open(self._local(fname)).convert("RGBA")).astype(np.float64)
        lum = a[..., :3].mean(axis=2) / 255.0
        alpha = a[..., 3] / 255.0
        if alpha[0, 0] < 0.04:
            cov = alpha
        elif lum[0, 0] < 0.5:
            cov = lum * alpha
        else:
            cov = (1.0 - lum) * alpha
        img = Image.fromarray(np.round(np.clip(cov, 0, 1) * 255).astype(np.uint8), "L")
        if cols is not None:
            img = img.crop((cols[0], 0, cols[1] + 1, img.height))
        return to_uri(img)

    def img(self, fname: str, alt: str, part=None) -> str:
        """`part` = (natural size, column range) to show one icon of a two-icon image."""
        if self.embed:
            return '<img src="%s" alt="%s">' % (self._embedded_uri(fname, part[1] if part else None),
                                               html.escape(alt))
        cls = "g-raw" if fname in LIGHT_ON_DARK else "g-inv"
        attrs = ('src="%s%s" alt="%s" class="%s" loading="lazy" referrerpolicy="no-referrer" '
                 'onerror="garminMissing(this)"' % (CDN, fname, html.escape(alt), cls))
        if part is None:
            return "<img %s>" % attrs
        # One icon of a two-icon image: scale the whole image to TILE_IMG_H and clip it to the
        # icon's columns with a sized, overflow-hidden box.
        (nat_w, nat_h), (c0, c1) = part
        s = TILE_IMG_H / nat_h
        return ('<span class="crop" style="width:%.1fpx;height:%dpx"><img %s style="height:%dpx;'
                'width:%.1fpx;max-width:none;max-height:none;margin-left:%.1fpx"></span>'
                % ((c1 - c0 + 1) * s, TILE_IMG_H, attrs, TILE_IMG_H, nat_w * s, -c0 * s))

    def options(self, key: str):
        """Tile options for a Garmin key: one, or A / B for a two-icon image."""
        if key in SPLIT:
            size, parts = SPLIT[key]
            return [("garmin_" + "ab"[i], "Garmin " + "AB"[i], SPLIT_NAMES[key][i],
                     self.img(F[key], "Garmin " + "AB"[i], (size, c)))
                    for i, c in enumerate(parts)]
        return [("garmin", "Garmin", "", self.img(F[key], "Garmin"))]


def uri_img(uri: str, alt: str = "") -> str:
    return '<img src="%s" alt="%s">' % (uri, html.escape(alt))


# ---- rows (numbers are permanent) ---------------------------------------------------------------

def build_rows(g: Garmin):
    rows = []

    def add(section, field, note, options, default):
        rows.append({"num": len(rows) + 1, "section": section, "field": field, "note": note,
                     "options": options, "default": default})

    paired = [
        ("Battery", 0xea31, "battery-1..4", "battery", "Same icon as Garmin's (their 23% is the reading). "
         "Ours fills with the charge too: empty, 1-4 bars, or charging"),
        ("Steps", 0x10265, "footprints", "steps", ""),
        ("Heart rate", 0xef92, "heartbeat", "hr", "Data 04 ring by default"),
        ("Body Battery", 0xea38, "bolt", "bb", "Data 05 ring by default. Your native face uses Garmin A"),
        ("Stress", 0xf0db, "activity-heartbeat", "stress", ""),
        ("Pulse Ox", 0xea97, "droplet", "spo2", ""),
        ("Calories", 0xec2c, "flame", "cal", ""),
        ("Floors climbed", 0xeca5, "stairs-up", "floors", ""),
        ("Altitude", 0xef97, "mountain", "alt", ""),
        ("Intensity minutes", 0xff9b, "stopwatch", "im", ""),
        ("Notifications", 0xea35, "bell", "notif", ""),
        ("Sunrise", 0xef1c, "sunrise", "sun", "Garmin uses one icon for both"),
        ("Sunset", 0xec31, "sunset", "sun", "Garmin uses one icon for both"),
        ("Respiration", 0xef62, "lungs", "resp", ""),
        ("Recovery time", 0xf228, "zzz", "recov", ""),
        ("Solar input", 0xeb30, "sun", "solar", "Solar models only, not your tactix 8"),
        ("Training status", 0xeb43, "trending-up", "ts", ""),
        ("Weather", ("weather", "partly_day"), "cloud + sun, filled", "wx",
         "Solid, Garmin-style; ours changes with the condition (set below)"),
        ("Alarm (indicator)", 0xea04, "alarm", "alarm", "Top-left corner when an alarm is set"),
    ]
    for field, glyph, tname, gkey, note in paired:
        add("both", field, "Tabler " + tname + (" · " + note if note else ""),
            [("ours", "Ours", "", uri_img(ours(glyph), "Ours"))] + g.options(gkey), "ours")
    # Row 20: the face shows the city code now; the globe it used before is a separate option.
    add("both", "Second time zone", "Data 08's clock: the city code (NY, LDN...) over the time, "
        "as the face draws it now; the globe was the old marker",
        [("ours", "City code", "as now", uri_img(city_tile("NY", "14:30"), "City code")),
         ("globe", "Globe", "old", uri_img(tabler(0xeb54), "Globe"))] + g.options("utc"), "ours")

    for field, gkey, label in [("Barometric pressure", "baro", "PRESS"), ("Calendar events", "calendar", "CAL"),
                               ("Weekly running distance", "run", "RUN"),
                               ("Weekly cycling distance", "bike", "BIKE"), ("Last golf round", "golf", "GOLF")]:
        add("text", field, "No icon today: the face shows a short text label",
            [("text", "Text", "as now", uri_img(text_tile(label), "Text"))] + g.options(gkey), "text")

    v = uri_img(vo2(), "Garmin VO2")
    add("ours", "VO2 max (run)", "Tabler run · Garmin shows VO2 lettering on your native faces",
        [("ours", "Ours", "", uri_img(tabler(0xec82), "Ours")), ("garmin_vo2", "Garmin", "VO2 lettering", v)], "ours")
    add("ours", "VO2 max (bike)", "Tabler bike · Garmin shows VO2 lettering here too",
        [("ours", "Ours", "", uri_img(tabler(0xea36), "Ours")), ("garmin_vo2", "Garmin", "VO2 lettering", v)], "ours")
    add("ours", "Temperature (wrist sensor)", "Tabler temperature · no Garmin icon in the article",
        [("ours", "Ours", "", uri_img(tabler(0xeb38)))], "ours")
    add("ours", "Sleep score", "Tabler moon · no Garmin icon in the article",
        [("ours", "Ours", "", uri_img(tabler(0xeaf8)))], "ours")

    # Face-computed fields (Settings > Data fields) - added 2026-09-28 as rows 30-32.
    add("fields", "Humidity", "Tabler droplet-half (the whole droplet is Pulse Ox) · no Garmin icon in the article",
        [("ours", "Ours", "", uri_img(tabler(0xee82)))], "ours")
    add("fields", "Wind speed", "Tabler arrows, one of eight: the way the air moves · shown here for a SW wind",
        [("ours", "Ours", "", uri_img(tabler(0xea24)))], "ours")
    add("fields", "Chance of rain", "Tabler umbrella · no Garmin icon in the article",
        [("ours", "Ours", "", uri_img(tabler(0xebf1)))], "ours")
    return rows


WEATHER_SET = [("Clear, day", ("weather", "clear_day")), ("Clear, night", ("weather", "clear_night")),
               ("Partly cloudy, day", ("weather", "partly_day")), ("Partly cloudy, night", ("weather", "partly_night")),
               ("Cloudy", ("weather", "cloudy")), ("Rain", ("weather", "rain")), ("Snow / ice", ("weather", "snow")),
               ("Storm", ("weather", "storm")), ("Fog / haze", ("weather", "fog")), ("Wind", ("weather", "wind"))]


# ---- page -------------------------------------------------------------------------------------

def row_html(r) -> str:
    rid = "r%d" % r["num"]
    single = len(r["options"]) == 1
    opts = []
    for key, cap, sub, img in r["options"]:
        if single:
            opts.append('<div class="opt static"><span class="tile">%s</span><span class="cap">%s</span></div>'
                        % (img, cap))
            continue
        oid = "%s-%s" % (rid, key)
        checked = " checked" if key == r["default"] else ""
        sub_html = '<span class="sub">%s</span>' % html.escape(sub) if sub else ""
        caption = cap + (" (" + sub + ")" if sub else "")
        opts.append('<label class="opt" for="%s"><input type="radio" id="%s" name="%s" value="%s" '
                    'data-caption="%s"%s><span class="tile">%s</span><span class="cap">%s</span>%s</label>'
                    % (oid, oid, rid, key, html.escape(caption), checked, img, cap, sub_html))
    return ('<li class="row" data-num="%d" data-field="%s" data-default="%s"><span class="num">%d</span>'
            '<div class="meta"><b>%s</b><small>%s</small></div><div class="opts">%s</div></li>'
            % (r["num"], html.escape(r["field"]), r["default"], r["num"], html.escape(r["field"]),
               html.escape(r["note"]), "".join(opts)))


CSS = """
  /* One dark look on purpose: it mirrors the watch screen. Colours are Claude Grid's own:
     lavender labels, cyan data, yellow accent. */
  :root {
    color-scheme: dark;
    --bg: #07070b; --panel: #101018; --panel-hi: #15162a; --line: #23243a; --screen: #000;
    --text: #eceefa; --dim: #8a90c0; --cyan: #36f9f6; --yellow: #fede5d;
    --mono: "IBM Plex Mono", ui-monospace, Consolas, monospace;
    --sans: "IBM Plex Sans", system-ui, "Segoe UI", sans-serif;
  }
  * { box-sizing: border-box; }
  body { background: var(--bg); color: var(--text); font: 15px/1.5 var(--sans); margin: 0;
         padding-inline: 16px; padding-block: 24px 0; }
  main { max-width: 780px; margin: 0 auto; display: grid; gap: 34px; padding-bottom: 28px; }
  header { display: grid; gap: 10px; }
  h1 { font: 600 26px/1.2 var(--mono); margin: 0; text-wrap: balance; }
  h1 span { color: var(--cyan); }
  header p { margin: 0; color: var(--dim); max-width: 64ch; }
  a { color: var(--cyan); }
  h2 { font: 600 13px/1 var(--mono); text-transform: uppercase; letter-spacing: .12em; color: var(--yellow); margin: 0 0 6px; }
  section > p { margin: 0 0 14px; color: var(--dim); max-width: 64ch; }
  ol { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
  .row { display: grid; grid-template-columns: 30px minmax(0, 1fr) auto; gap: 12px; align-items: center;
         background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 10px 12px; }
  .row.changed { border-color: color-mix(in srgb, var(--cyan) 45%, var(--line)); background: var(--panel-hi); }
  .num { font: 600 15px/1 var(--mono); color: var(--yellow); font-variant-numeric: tabular-nums; }
  .meta { display: grid; gap: 2px; }
  .meta b { font-weight: 600; }
  .meta small { color: var(--dim); font-size: 12.5px; }
  .opts { display: flex; gap: 8px; }
  .opt { display: grid; justify-items: center; gap: 3px; cursor: pointer; width: 70px; }
  .opt.static { cursor: default; }
  .opt input { position: absolute; opacity: 0; width: 1px; height: 1px; pointer-events: none; }
  .tile { width: 64px; height: 64px; background: var(--screen); border: 1px solid var(--line); border-radius: 9px;
          display: grid; place-items: center; position: relative; overflow: visible; transition: border-color .12s, box-shadow .12s; }
  .tile img { max-width: 46px; max-height: TILEHpx; width: auto; height: auto; }
  .tile img.g-inv { filter: invert(1); }          /* Garmin's black-on-white -> white-on-black */
  .tile .crop { display: block; overflow: hidden; }
  .tile .alt { font-size: 10px; line-height: 1.2; color: var(--dim); padding: 4px; text-align: center; }
  .cap { font: 600 11px/1.1 var(--mono); color: var(--dim); letter-spacing: .06em; text-transform: uppercase; }
  .sub { font-size: 11px; line-height: 1.15; color: var(--dim); text-align: center; }
  .opt:hover .tile { border-color: var(--dim); }
  .opt input:focus-visible + .tile { outline: 2px solid var(--yellow); outline-offset: 2px; }
  .opt input:checked + .tile { border-color: var(--cyan); box-shadow: 0 0 0 1px var(--cyan) inset, 0 0 12px -2px color-mix(in srgb, var(--cyan) 60%, transparent); }
  .opt input:checked + .tile::after { content: "\\2713"; position: absolute; top: -7px; right: -7px; width: 18px; height: 18px;
          border-radius: 50%; background: var(--cyan); color: #001; font: 700 12px/18px var(--sans); text-align: center; }
  .opt input:checked ~ .cap { color: var(--cyan); }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(104px, 1fr)); gap: 8px; }
  .mini { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 10px;
          display: grid; justify-items: center; gap: 6px; }
  .mini small { color: var(--dim); font-size: 12px; text-align: center; }
  details summary { cursor: pointer; color: var(--dim); font-size: 14px; }
  details[open] summary { margin-bottom: 12px; }
  .out { display: grid; gap: 10px; }
  #picks { width: 100%; min-height: 150px; resize: vertical; background: var(--screen); color: var(--text);
           border: 1px solid var(--line); border-radius: 10px; padding: 12px; font: 500 13px/1.55 var(--mono); }
  .actions { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
  button { font: 600 14px var(--sans); border-radius: 8px; padding: 9px 16px; cursor: pointer; border: 1px solid var(--line); }
  #copy { background: var(--cyan); color: #001; border-color: var(--cyan); }
  #reset { background: transparent; color: var(--dim); }
  button:focus-visible { outline: 2px solid var(--yellow); outline-offset: 2px; }
  #status { color: var(--dim); font-size: 13px; }
  .bar { position: sticky; bottom: 0; margin-inline: -16px; padding: 10px 16px;
         padding-bottom: calc(10px + env(safe-area-inset-bottom, 0px));
         background: color-mix(in srgb, var(--bg) 88%, transparent); backdrop-filter: blur(6px);
         border-top: 1px solid var(--line); display: flex; justify-content: space-between; align-items: center; gap: 12px; }
  .bar span { font: 500 13px var(--mono); color: var(--dim); }
  .bar span b { color: var(--cyan); }
  .bar a { font: 600 14px var(--sans); text-decoration: none; color: var(--bg); background: var(--cyan); border-radius: 8px; padding: 7px 14px; }
  footer { color: var(--dim); font-size: 12.5px; }
  @media (max-width: 520px) {
    .row { grid-template-columns: 26px minmax(0, 1fr); grid-template-areas: "num meta" "num opts"; row-gap: 10px; }
    .num { grid-area: num; align-self: start; padding-top: 3px; }
    .meta { grid-area: meta; }
    .opts { grid-area: opts; }
  }
  @media (prefers-reduced-motion: reduce) { .tile { transition: none; } }
""".replace("TILEH", str(TILE_IMG_H))

JS = """
(function () {
  var KEY = "grid-icon-picks-v1";
  var rows = Array.prototype.slice.call(document.querySelectorAll(".row"));
  var out = document.getElementById("picks");
  var count = document.getElementById("count");
  var status = document.getElementById("status");
  function load() { try { return JSON.parse(localStorage.getItem(KEY) || "{}") || {}; } catch (e) { return {}; } }
  function save(state) { try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) { /* storage blocked */ } }
  function render() {
    var lines = [], state = {};
    rows.forEach(function (row) {
      var c = row.querySelector("input:checked");
      if (!c) { return; }
      var changed = c.value !== row.dataset.default;
      row.classList.toggle("changed", changed);
      if (changed) {
        state[row.dataset.num] = c.value;
        lines.push(row.dataset.num + " " + row.dataset.field + ": " + c.dataset.caption);
      }
    });
    count.textContent = String(lines.length);
    out.value = lines.length
      ? "Claude Grid icon picks\\n" + lines.join("\\n") + "\\nEverything else: keep ours."
      : "No changes: keep all our current icons.";
    save(state);
  }
  var saved = load();                     // this viewer's last picks
  rows.forEach(function (row) {
    var v = saved[row.dataset.num];
    var input = v ? row.querySelector('input[value="' + v + '"]') : null;
    if (input) { input.checked = true; }
  });
  document.addEventListener("change", function (e) {
    if (e.target && e.target.type === "radio") { render(); status.textContent = ""; }
  });
  document.getElementById("reset").addEventListener("click", function () {
    rows.forEach(function (row) {
      var d = row.querySelector('input[value="' + row.dataset.default + '"]');
      if (d) { d.checked = true; }
    });
    render();
    status.textContent = "Reset to our icons.";
  });
  document.getElementById("copy").addEventListener("click", function () {
    function fallback() { out.focus(); out.select(); status.textContent = "Selected. Copy it with your device's copy command."; }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(out.value).then(function () { status.textContent = "Copied. Paste it into the chat."; }, fallback);
    } else { fallback(); }
  });
  render();
})();
// A linked Garmin icon that can't load (offline, or a viewer that blocks remote images) shows
// Garmin's own description of it instead.
function garminMissing(img) {
  var s = document.createElement("span");
  s.className = "alt";
  s.textContent = img.alt;
  (img.closest(".crop") || img).replaceWith(s);
}
"""


def build_page(embed: bool) -> str:
    g = Garmin(embed)
    rows = build_rows(g)

    def section(name):
        return "".join(row_html(r) for r in rows if r["section"] == name)

    wx = "".join('<li class="mini"><span class="tile">%s</span><small>%s</small></li>'
                 % (uri_img(ours(glyph)), html.escape(label)) for label, glyph in WEATHER_SET)
    gonly = "".join('<li class="mini"><span class="tile">%s</span><small>%s</small></li>'
                    % (g.img(f, name), html.escape(name)) for name, f in G_ONLY)
    source = ("Garmin&rsquo;s icons are built into this private copy."
              if embed else
              "Garmin&rsquo;s icons load from Garmin&rsquo;s site, so that column needs a connection.")
    today = datetime.date.today().isoformat()
    return """<title>Grid Icon Picker</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@500;600&family=IBM+Plex+Sans:wght@400;600&display=swap">
<style>%s</style>
<main>
  <header>
    <h1>Claude Grid <span>icon picker</span></h1>
    <p>For each field, tap the icon you want on the face; our current icon is selected to start with.
      Garmin&rsquo;s icons are from <a href="%s" target="_blank" rel="noopener">What Do the Icons on My Garmin Watch Face Mean?</a>,
      split into A and B where Garmin shows two. %s Both columns are white on black here; on the watch our icons
      draw in the face&rsquo;s lavender label colour. Your picks are written out at the bottom, ready to copy.</p>
  </header>
  <section><h2>Fields with both icons</h2><ol>%s</ol></section>
  <section><h2>Fields shown as text today</h2>
    <p>No icon on our faces yet: the slot shows a short text label. Pick Garmin to give one an icon.</p><ol>%s</ol></section>
  <section><h2>Ours, and Garmin&rsquo;s lettering</h2>
    <p>Not in Garmin&rsquo;s article. Your native faces show VO2 max as VO&#8322; lettering rather than a picture.</p><ol>%s</ol></section>
  <section><h2>Our own fields</h2>
    <p>Face settings &rsaquo; Data fields: data Garmin has no complication for. No Garmin icons in the article.</p><ol>%s</ol></section>
  <section><h2>Weather set</h2>
    <p>The weather field and the Terminal&rsquo;s weather line change icon with the condition (moon after sunset).
      Solid shapes in Garmin&rsquo;s style; Garmin&rsquo;s article has a single weather icon, row 18.
      Mention any you want redrawn.</p><ol class="grid">%s</ol></section>
  <section><details><summary>Garmin icons with no Connect IQ field (can&rsquo;t appear on our faces)</summary>
    <ol class="grid">%s</ol></details></section>
  <section class="out" id="out">
    <h2>Your picks</h2>
    <textarea id="picks" readonly aria-label="Your picks as text"></textarea>
    <div class="actions">
      <button id="copy" type="button">Copy picks</button>
      <button id="reset" type="button">Reset all to ours</button>
      <span id="status" role="status"></span>
    </div>
  </section>
  <footer>Generated: %s by garmin/faces/grid/editor/build_icon_picker.py &middot; our icons: Tabler Icons (MIT),
    from the face&rsquo;s own font source &middot; Garmin icons &copy; Garmin, shown for comparison.</footer>
</main>
<div class="bar"><span><b id="count">0</b> changes</span><a href="#out">See picks</a></div>
<script>%s</script>
""" % (CSS, ARTICLE, source, section("both"), section("text"), section("ours"), section("fields"),
       wx, gonly, today, JS)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--embed-garmin", metavar="OUT", help="write a private copy with Garmin's icons embedded")
    ap.add_argument("--artifact", action="store_true", help="omit the document wrapper (Artifact publishing)")
    args = ap.parse_args()
    embed = args.embed_garmin is not None
    out = Path(args.embed_garmin) if embed else HERE / "icon-picker.html"
    if embed and out.resolve().is_relative_to(HERE.parent.parent.parent.parent.resolve()):
        # A path inside the repo: refuse, so Garmin's artwork never lands in this public repo by accident.
        print("refusing to write an embedded copy inside the repo: %s" % out, file=sys.stderr)
        return 2
    body = build_page(embed)
    if not args.artifact:
        body = ('<!doctype html>\n<html lang="en"><head><meta charset="utf-8">\n'
                '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
                + body + "</html>\n")
    out.write_text(body, encoding="utf-8", newline="\n")
    print("wrote %s (%s Garmin icons, %d bytes)" % (out, "embedded" if embed else "linked", out.stat().st_size))
    return 0


if __name__ == "__main__":
    sys.exit(main())
