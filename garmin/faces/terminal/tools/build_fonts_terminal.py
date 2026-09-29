"""Regenerate the Claude Terminal bitmap fonts into resources/fonts.

Three atlases: the big time (digits + colon), the prompt text, and the date/row text (both
printable ASCII - the prompt is user-editable; the rows carry labels, percentages and reset
times). Sizes come from the layout editor; keep them in step with its Copy settings block.
The stm_* file names predate the typeface switch - they are the face's generic font slots.

The face's typeface is the (TTF, FACE, WEIGHT) setting below - swap it to change the whole face.
A terminal must be monospace, so every glyph (incl. the time's colon) gets the SAME advance.

Run from anywhere:  python garmin/faces/terminal/tools/build_fonts_terminal.py
(then tools/build_glow_time.py if the time font changed - the VFD time bitmaps are cut from it).
"""
from __future__ import annotations

import os

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "resources", "fonts")
# genfont and the IBM Plex Mono TTF are shared with Claude Grid: garmin/shared/tools/.
SHARED_TOOLS = os.path.join(HERE, "..", "..", "..", "shared", "tools")
# Claude Grid's generated fonts, source of the weather icon atlas (see copy_icon_font).
GRID_FONTS = os.path.join(HERE, "..", "..", "grid", "resources", "fonts")
# --- the face's typeface ---------------------------------------------------------------------
# Doto (dot matrix, OFL - tools/Doto-OFL.txt), chosen in the layout editor on 2026-09-29. Variable
# font with two axes in fvar order [ROND, wght]: square dots (ROND 0) at Regular (wght 400), the
# weight Google Fonts serves by default and so the one the editor previewed. Before it: IBM Plex
# Mono Regular (garmin/shared/tools/IBMPlexMono-Regular.ttf, WEIGHT = None).
TTF = os.path.join(HERE, "Doto-Variable.ttf")
FACE = "Doto"
WEIGHT = [0, 400]   # every axis of a variable TTF in fvar order, a single wght number, or None

TIME_CHARS = "0123456789:"
# Printable ASCII + the degree sign for the weather temperature ("17°") - without it the
# temperature ended in a tofu box.
TEXT_CHARS = "".join([chr(c) for c in range(0x20, 0x7F)]) + "°"


def generate(out_base: str, size: int, chars: str, atlas_w: int = 256) -> None:
    """Rasterise `chars` into a BMFont atlas with one shared (monospace) advance.

    Coverage goes into R, G, B AND alpha: the CIQ font compiler takes a glyph pixel's ink from its
    RGB brightness and uses alpha only as an on/off mask (proved in the simulator for the Claude
    Grid). Pillow's draw.text on a transparent RGBA image leaves RGB at a flat 255 on every touched
    pixel, so without this the anti-aliased edge was thrown away and text compiled 1-bit and bold.
    """
    font = ImageFont.truetype(TTF, size)
    if WEIGHT is not None:
        font.set_variation_by_axes(list(WEIGHT) if isinstance(WEIGHT, (list, tuple)) else [WEIGHT])
    ascent, descent = font.getmetrics()
    line_h = ascent + descent
    adv = int(round(font.getlength("0")))

    pad = 1
    cell_w = max(adv, max(font.getbbox(c)[2] for c in chars)) + 2 * pad + 2
    cell_h = line_h + 2 * pad + 2
    cols = max(1, atlas_w // cell_w)
    rows = (len(chars) + cols - 1) // cols
    atlas_h = 1
    while atlas_h < rows * cell_h:
        atlas_h *= 2

    atlas = Image.new("RGBA", (atlas_w, atlas_h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(atlas)
    lines = []
    for i, ch in enumerate(chars):
        gx = (i % cols) * cell_w + pad
        gy = (i // cols) * cell_h + pad
        draw.text((gx, gy), ch, font=font, fill=(255, 255, 255, 255))
        x0, y0, x1, y1 = font.getbbox(ch)
        lines.append(
            "char id=%d x=%d y=%d width=%d height=%d xoffset=%d yoffset=%d xadvance=%d page=0 chnl=15"
            % (ord(ch), gx + x0, gy + y0, max(0, x1 - x0), max(0, y1 - y0), x0, y0, adv))

    cov = atlas.getchannel("A")
    Image.merge("RGBA", (cov, cov, cov, cov)).save(out_base + "_0.png")
    with open(out_base + ".fnt", "w", newline="\n") as f:
        f.write('info face="%s" size=%d bold=0 italic=0 charset="" unicode=1 '
                'stretchH=100 smooth=1 aa=1 padding=0,0,0,0 spacing=1,1 outline=0\n' % (FACE, size))
        # BMFont channel codes: 0 = glyph data - every channel carries the glyph.
        f.write("common lineHeight=%d base=%d scaleW=%d scaleH=%d pages=1 packed=0 alphaChnl=0 "
                "redChnl=0 greenChnl=0 blueChnl=0\n" % (line_h, ascent, atlas_w, atlas_h))
        f.write('page id=0 file="%s_0.png"\n' % os.path.basename(out_base))
        f.write("chars count=%d\n" % len(chars))
        for ln in lines:
            f.write(ln + "\n")
    bb = Image.open(out_base + "_0.png").getchannel("A").getbbox()
    print("generated %s size=%d atlas=%dx%d adv=%d lineH=%d ink=%s"
          % (os.path.basename(out_base), size, atlas_w, atlas_h, adv, line_h, bb))
    if bb is None:
        raise SystemExit("!!! %s is blank - a blank atlas silently kills all text" % out_base)


def generate_outline(out_base: str, size: int, chars: str, stroke: int = 2,
                     atlas_w: int = 512) -> None:
    """The always-on time: hollow, anti-aliased `stroke`-px OUTLINES of the same glyphs.

    Uses the shared genfont outline renderer (supersampled distance-transform band, coverage in
    RGB and alpha) rather than a second copy of it. Its .fnt uses the same line metrics as
    generate() above (lineHeight = ascent + descent, offsets from the line top) and IBM Plex Mono
    is monospace, so an outline glyph lands exactly where its solid twin does and the face can
    swap fonts without moving the time.
    """
    import sys
    sys.path.insert(0, SHARED_TOOLS)
    import genfont  # noqa: E402  (garmin/shared/tools/genfont.py)
    genfont.generate(TTF, out_base, size, chars, atlas_w, face_name=FACE, weight=WEIGHT,
                     stroke=stroke)
    bb = Image.open(out_base + "_0.png").getchannel("A").getbbox()
    if bb is None:
        raise SystemExit("!!! %s is blank - a blank atlas silently kills all text" % out_base)


# Bleed chosen in the layout editor's Scanlines panel, 2026-09-29: 145 % at radius 5 px (a 3-pass
# box blur of radius 5 is close to a gaussian of sigma 5.5). Was sigma 2.8, pad 8, gain 2.4.
GLOW_PAD = 15       # px of halo room around every glyph (~2.7 sigma)
GLOW_SIGMA = 5.5    # gaussian blur radius of the halo
GLOW_GAIN = 3.2     # coverage multiplier before clipping: the core reaches full coverage
GLOW_PEAK = 1.0     # CIQ renders font coverage in only 4 levels (measured in the simulator:
                    # 0 / 1/3 / 2/3 / 1), so a faint halo collapses into one flat band. A
                    # full-strength halo quantises into three evenly spaced glow steps instead;
                    # its brightness comes from the colour it is drawn in (the face blends the
                    # text colour halfway to the background - ClaudeFaceView.GLOW_MIX).


def glow_from_bmfont(src_base: str, out_base: str) -> None:
    """A soft HALO font for an existing BMFont (Retro tube's "everything glows" tube effect).

    Connect IQ can't blur, so the glow is pre-rendered like the time's glow bitmaps: every glyph
    of `src_base` (.fnt + _0.png) is cropped from its atlas, padded by GLOW_PAD, gaussian-blurred
    and scaled into a soft halo, and packed into a new atlas whose .fnt keeps the source's line
    metrics and advances with every offset shifted by -GLOW_PAD. So drawing the same string with
    the halo font at the same position lays the halo exactly under the sharp text; the face
    draws the halo first, then the text (ClaudeFaceView.text / drawWeather). Coverage goes into
    RGB and alpha, as for every CIQ font here.
    """
    import numpy as np
    from scipy.ndimage import gaussian_filter

    lines = open(src_base + ".fnt", encoding="utf-8").read().splitlines()
    common = [l for l in lines if l.startswith("common ")][0]
    info = [l for l in lines if l.startswith("info ")][0]
    chars = [dict(kv.split("=", 1) for kv in l.split()[1:]) for l in lines if l.startswith("char ")]
    src = np.asarray(Image.open(src_base + "_0.png").getchannel("A")).astype(float) / 255.0

    halos = []
    for c in chars:
        x, y, w, h = int(c["x"]), int(c["y"]), int(c["width"]), int(c["height"])
        cell = np.zeros((h + 2 * GLOW_PAD, w + 2 * GLOW_PAD))
        if w > 0 and h > 0:
            cell[GLOW_PAD:GLOW_PAD + h, GLOW_PAD:GLOW_PAD + w] = src[y:y + h, x:x + w]
        halo = np.clip(gaussian_filter(cell, GLOW_SIGMA) * GLOW_GAIN, 0.0, GLOW_PEAK)
        halos.append((c, halo))

    # shelf-pack the halos into a power-of-two atlas, 512 wide
    atlas_w, pen_x, pen_y, shelf_h, places = 512, 1, 1, 0, []
    for c, halo in halos:
        hh, ww = halo.shape
        if pen_x + ww + 1 > atlas_w:
            pen_x, pen_y, shelf_h = 1, pen_y + shelf_h + 1, 0
        places.append((pen_x, pen_y))
        pen_x += ww + 1
        shelf_h = max(shelf_h, hh)
    atlas_h = 1
    while atlas_h < pen_y + shelf_h + 1:
        atlas_h *= 2
    cov = np.zeros((atlas_h, atlas_w))
    out_lines = []
    for (c, halo), (px_, py_) in zip(halos, places):
        hh, ww = halo.shape
        cov[py_:py_ + hh, px_:px_ + ww] = halo
        out_lines.append(
            "char id=%s x=%d y=%d width=%d height=%d xoffset=%d yoffset=%d xadvance=%s page=0 chnl=15"
            % (c["id"], px_, py_, ww, hh, int(c["xoffset"]) - GLOW_PAD, int(c["yoffset"]) - GLOW_PAD,
               c["xadvance"]))
    c8 = Image.fromarray(np.round(cov * 255.0).astype(np.uint8), "L")
    Image.merge("RGBA", (c8, c8, c8, c8)).save(out_base + "_0.png")
    with open(out_base + ".fnt", "w", encoding="utf-8", newline="\n") as f:
        f.write(info + "\n")
        f.write(common.replace(common.split("scaleW=")[1].split()[0], str(atlas_w), 1)
                .replace("scaleH=" + common.split("scaleH=")[1].split()[0], "scaleH=%d" % atlas_h) + "\n")
        f.write('page id=0 file="%s_0.png"\n' % os.path.basename(out_base))
        f.write("chars count=%d\n" % len(out_lines))
        for ln in out_lines:
            f.write(ln + "\n")
    print("generated %s (halo of %s) atlas=%dx%d glyphs=%d"
          % (os.path.basename(out_base), os.path.basename(src_base), atlas_w, atlas_h, len(out_lines)))


def copy_icon_font() -> None:
    """The weather icons, as stm_icon: Claude Grid's generated cg_icon atlas (Tabler icons at
    24 px, incl. the solid weather set at 0xE001-0xE00A), copied rather than
    regenerated so both faces show identical icons from one source. Run Claude Grid's
    tools/build_fonts_grid.py (garmin/faces/grid/) first if the icon set changes."""
    src = GRID_FONTS
    fnt = open(os.path.join(src, "cg_icon.fnt"), encoding="utf-8").read()
    if 'file="cg_icon_0.png"' not in fnt:
        raise SystemExit("cg_icon.fnt page line changed - update copy_icon_font()")
    with open(os.path.join(OUT, "stm_icon.fnt"), "w", encoding="utf-8", newline="\n") as f:
        f.write(fnt.replace('file="cg_icon_0.png"', 'file="stm_icon_0.png"'))
    Image.open(os.path.join(src, "cg_icon_0.png")).save(os.path.join(OUT, "stm_icon_0.png"))
    print("copied cg_icon -> stm_icon (weather icons)")


if __name__ == "__main__":
    copy_icon_font()
    generate(os.path.join(OUT, "stm_time"), 70, TIME_CHARS, 256)    # editor: time size
    # always-on time: 2 px outline (Claude Grid's cg_time_o weight), digits + colon only
    generate_outline(os.path.join(OUT, "stm_time_o"), 70, TIME_CHARS, 2)
    generate(os.path.join(OUT, "stm_text"), 26, TEXT_CHARS, 256)    # editor: prompt size
    generate(os.path.join(OUT, "stm_small"), 25, TEXT_CHARS, 256)   # editor: date + rows size
    # Retro tube's glow on everything: halo fonts for the prompt, the date/rows and the icons.
    for base in ("stm_text", "stm_small", "stm_icon"):
        glow_from_bmfont(os.path.join(OUT, base), os.path.join(OUT, base + "_glow"))
