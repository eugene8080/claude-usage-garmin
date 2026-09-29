"""Solid ("filled") versions of the outline Tabler icons, in the style of Garmin's own watch-face
icons. This Tabler build ships no *-filled glyphs, so they are derived from the outlines:

  fill    A closed shape (heart, droplet, flame, bell, footprints...) is flood-filled solid. Detail
          strokes INSIDE it (a stopwatch's hands, the heartbeat line, a thermometer's scale) are
          kept as dark lines knocked out of the solid body, the usual way a filled icon keeps its
          detail.
  stroke  An open, line-only icon (arrows, the stress line, the training trend, the bike, whose
          wheels must not fill) is drawn with a heavier stroke, to sit at the same visual weight.
  keep    Left as the outline glyph (the battery levels: Garmin's own battery icon is an outline
          with a fill level, which the Tabler bars already are).

`auto` picks fill when flood-filling adds a substantial area, else stroke.

Everything is drawn at `ss` times the target size and box-filtered down, in the frame PIL's
draw.text uses (origin = pen x / line top), so a glyph filed through genfont's `extra=` sits
exactly where the outline glyph did - the faces keep asking for the same codes.

    render(cp, ttf, size, mode="auto") -> (Image "L" coverage, xadvance)

Used by garmin/faces/grid/tools/build_fonts_grid.py (the 24 px cg_icon atlas), and for previews by
garmin/faces/grid/editor/build_icon_picker.py and build_editor.py. The weather set is drawn by
weather_icons.py (composed icons, not single glyphs).
"""
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import binary_dilation, binary_fill_holes, distance_transform_edt, label

# Icons that must not be filled or thickened, and line icons whose enclosed areas must not fill.
KEEP = {0xea34, 0xea2f, 0xea30, 0xea31, 0xea32, 0xea33}      # battery, battery-1..4, charging
STROKE = {0xea36}                                           # bike: the wheels would fill solid
FILL = {0xea38}                                             # bolt: thin enough to miss FILL_GAIN
# Drawn from a different Tabler glyph than the code it is filed under. Heartbeat's pulse line
# breaks the heart's outline, so it never fills; heart rate becomes Tabler's closed "heart",
# filled - the solid heart Garmin uses.
SUBSTITUTE = {0xef92: 0xeabe}                               # heartbeat -> heart
FILL_GAIN = 1.35      # auto: fill when flood-filling grows the ink by more than this factor
TABLER_STROKE = 2.0 / 24.0   # Tabler's stroke width as a fraction of the em


def mode_for(cp: int) -> str:
    if cp in KEEP:
        return "keep"
    if cp in STROKE:
        return "stroke"
    if cp in FILL:
        return "fill"
    return "auto"


def render(cp: int, ttf: str, size: int, mode: str = "auto", ss: int = 4):
    """The solid version of Tabler glyph `cp` at `size` px: (coverage image "L", xadvance)."""
    base = ImageFont.truetype(ttf, size)
    asc, desc = base.getmetrics()
    adv = int(round(base.getlength(chr(cp))))
    cp = SUBSTITUTE.get(cp, cp)          # drawn from another glyph; filed (and advanced) as `cp`
    margin = 4                                     # room for a thickened stroke at the right/bottom
    w, h = (adv + margin) * ss, (asc + desc + margin) * ss
    big = ImageFont.truetype(ttf, size * ss)
    im = Image.new("L", (w, h), 0)
    ImageDraw.Draw(im).text((0, 0), chr(cp), font=big, fill=255)
    cov = np.asarray(im).astype(np.float64) / 255.0
    if mode == "keep":
        out = cov
    else:
        mask = cov > 0.4
        filled = binary_fill_holes(mask)
        if mode == "auto":
            mode = "fill" if filled.sum() > FILL_GAIN * max(1, mask.sum()) else "stroke"
        stroke_px = size * ss * TABLER_STROKE
        if mode == "fill":
            # Distance of every inside pixel from the outside: the outline ring is within about one
            # stroke of it; ink deeper than that is interior detail, knocked out as a dark line.
            depth = distance_transform_edt(filled)
            detail = mask & (depth > stroke_px * 1.25)
            # Drop specks: where an outline bends inward (the dip at the top of a heart) a few pixels
            # of its own stroke sit deep enough to pass for detail. Real detail (hands, a scale, a
            # pulse line) is at least a couple of strokes long.
            parts, n = label(detail)
            if n:
                sizes = np.bincount(parts.ravel())
                small = sizes < (stroke_px ** 2) * 2.5
                small[0] = False
                detail[small[parts]] = False
            detail_zone = binary_dilation(detail, iterations=max(1, ss // 2))
            body = np.where(filled, 1.0, cov)              # solid inside, anti-aliased edge outside
            out = body * (1.0 - np.where(detail_zone, cov, 0.0))
        elif mode == "stroke":
            grow = max(1, int(round(0.30 * ss)))           # ~0.3 px heavier on each side at `size`
            out = np.maximum(cov, binary_dilation(mask, iterations=grow).astype(np.float64))
        else:
            raise ValueError("unknown mode %r" % mode)
    img = Image.fromarray(np.round(np.clip(out, 0, 1) * 255).astype(np.uint8), "L")
    return img.resize((w // ss, h // ss), Image.BOX), adv


# ---- humidity: a droplet that fills with the reading ------------------------------------------
# Tabler's droplet outline with water inside it up to the humidity level - a flat (horizontal)
# water line, higher for more humid air. A 1 px gap separates the water from the outline, so even
# the full droplet stays distinct from Pulse Ox's solid droplet. One glyph per 20 % step, filed at
# HUMIDITY_BASE + step (step 0 = empty ... HUMIDITY_STEPS = full); ClaudeGridView.humidityGlyph
# rounds the reading to the nearest step.
DROPLET = 0xea97
HUMIDITY_BASE = 0xE010
HUMIDITY_STEPS = 5


def humidity(step: int, ttf: str, size: int, ss: int = 4):
    """The droplet at fill step `step` (0..HUMIDITY_STEPS): (coverage image "L", xadvance)."""
    if not 0 <= step <= HUMIDITY_STEPS:
        raise ValueError("humidity step %d outside 0..%d" % (step, HUMIDITY_STEPS))
    base = ImageFont.truetype(ttf, size)
    asc, desc = base.getmetrics()
    adv = int(round(base.getlength(chr(DROPLET))))
    margin = 4
    w, h = (adv + margin) * ss, (asc + desc + margin) * ss
    im = Image.new("L", (w, h), 0)
    ImageDraw.Draw(im).text((0, 0), chr(DROPLET), font=ImageFont.truetype(ttf, size * ss), fill=255)
    cov = np.asarray(im).astype(np.float64) / 255.0
    mask = cov > 0.4
    # The droplet's inside, less a 1 px gap along the outline.
    interior = binary_fill_holes(mask) & ~binary_dilation(mask, iterations=ss)
    rows = np.nonzero(interior.any(axis=1))[0]
    top, bottom = rows.min(), rows.max() + 1
    level = bottom - (step / HUMIDITY_STEPS) * (bottom - top)      # the water line, as a row index
    water = interior & (np.arange(h)[:, None] >= level)
    out = np.maximum(cov, water.astype(np.float64))
    img = Image.fromarray(np.round(np.clip(out, 0, 1) * 255).astype(np.uint8), "L")
    return img.resize((w // ss, h // ss), Image.BOX), adv


# ---- chance of rain: an umbrella with 0-3 drops falling on it -----------------------------------
# A solid umbrella, a little smaller than the glyph so there is room above it, with more drops the
# likelier the rain: none, one, two, three. The umbrella keeps the same size and place at every
# step, so only the drops change. Filed at RAIN_BASE + step; ClaudeGridView.rainGlyph maps the
# percentage (quarter steps: 0-12% none, 13-37% one, 38-62% two, 63%+ three).
UMBRELLA = 0xebf1
RAIN_BASE = 0xE020
RAIN_STEPS = 3


def _filled(cp: int, ttf: str, px: int) -> np.ndarray:
    """Glyph `cp` at `px` px, flood-filled solid, cropped to its ink (float coverage)."""
    font = ImageFont.truetype(ttf, px)
    im = Image.new("L", (px * 2, px * 2), 0)
    ImageDraw.Draw(im).text((0, 0), chr(cp), font=font, fill=255)
    cov = np.asarray(im).astype(np.float64) / 255.0
    body = np.maximum(cov, binary_fill_holes(cov > 0.4).astype(np.float64))
    ys, xs = np.nonzero(body > 0.02)
    return body[ys.min(): ys.max() + 1, xs.min(): xs.max() + 1]


def _paste(canvas: np.ndarray, part: np.ndarray, left: float, top: float) -> None:
    x, y = int(round(left)), int(round(top))
    h, w = part.shape
    region = canvas[y: y + h, x: x + w]
    np.maximum(region, part[: region.shape[0], : region.shape[1]], out=region)


def rain_chance(step: int, ttf: str, size: int, ss: int = 4):
    """The umbrella with `step` drops (0..RAIN_STEPS): (coverage image "L", xadvance)."""
    if not 0 <= step <= RAIN_STEPS:
        raise ValueError("rain step %d outside 0..%d" % (step, RAIN_STEPS))
    base = ImageFont.truetype(ttf, size)
    asc, desc = base.getmetrics()
    adv = int(round(base.getlength(chr(UMBRELLA))))
    margin = 4
    w, h = (adv + margin) * ss, (asc + desc + margin) * ss
    # The full-size glyph's ink box: the composed icon fills the same box.
    im = Image.new("L", (w, h), 0)
    ImageDraw.Draw(im).text((0, 0), chr(UMBRELLA), font=ImageFont.truetype(ttf, size * ss), fill=255)
    ys, xs = np.nonzero(np.asarray(im) > 10)
    x0, y0, x1, y1 = xs.min(), ys.min(), xs.max() + 1, ys.max() + 1
    canvas = np.zeros((h, w), dtype=np.float64)
    umb = _filled(UMBRELLA, ttf, int(round(size * ss * 0.74)))
    umb_left = (x0 + x1) / 2.0 - umb.shape[1] / 2.0
    umb_top = y1 - umb.shape[0]
    _paste(canvas, umb, umb_left, umb_top)
    if step:
        gap = 1.2 * ss                                  # ~1 px of air between drops and canopy
        drop_h = max(2, int(round(umb_top - gap - y0)))
        drop = _filled(0xea97, ttf, int(round(drop_h * 1.25)))    # droplet ink is ~80% of its px
        spots = {1: [0.5], 2: [0.30, 0.70], 3: [0.16, 0.5, 0.84]}[step]
        for f in spots:
            cx = umb_left + f * umb.shape[1]
            _paste(canvas, drop, cx - drop.shape[1] / 2.0, umb_top - gap - drop.shape[0])
    img = Image.fromarray(np.round(np.clip(canvas, 0, 1) * 255).astype(np.uint8), "L")
    return img.resize((w // ss, h // ss), Image.BOX), adv
