"""Rebuild the Claude Grid seconds dial as a pre-rasterised "tick font" (cg_ticks).

WHY. The dial used to be 60 x dc.drawLine(penWidth 2) at floating-point endpoints with
anti-aliasing on. Every tick then landed on the pixel grid at a different sub-pixel phase and got
round caps, so ticks looked uneven in weight and soft at the ends. Here each tick is an exact
square-ended rectangle, rasterised once at SS x supersampling and box-filtered down, so:
  * all 60 ticks have mathematically consistent coverage (same geometry, same filter);
  * the ends are true rectangle corners, not caps;
  * the dial centre sits on a PIXEL CORNER, so the 12 / 3 / 6 / 9 o'clock ticks (2 px wide) cover
    whole pixels and are perfectly hard-edged.

WHY A FONT. A font glyph is coverage-only and is tinted by dc.setColor at draw time, so each tick
still takes its own gradient / track colour per second - exactly like the old per-tick setColor.
All 60 glyphs share ONE cell (CELL x CELL, dial centre at its corner (HALF, HALF)); each glyph's
xoffset/yoffset places its small bitmap inside that cell, so the runtime draws every tick with the
same origin: drawText(cx - HALF, cy - HALF, font, tickChar(i), LEFT) - see GridDraw.tickRing.

Glyph codes: 0xE100 + i (i = 0 at 12 o'clock, clockwise). BMP private use - CIQ glyph codes are
16-bit. Atlas RGB = alpha = coverage (the compiler reads ink from RGB; see genfont.py).

Run from anywhere:  python garmin/faces/grid/tools/build_tick_font.py
Keep R_OUT / TICK_LEN / TICK_W / HALF in sync with GridDraw.TICK_* (asserted by the face's layout
only visually - the generator prints them).
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "resources" / "fonts"
BASE = "cg_ticks"

N = 60            # ticks
R_OUT = 50        # outer radius (px) - the r the view passes to tickRing
TICK_LEN = 9      # radial length (px): inner radius = R_OUT - TICK_LEN
TICK_W = 2        # default tick width (px); --width-out / --width-in override (test variants)
HALF = R_OUT + 2  # cell half-size; the dial centre is the cell's pixel corner (HALF, HALF)
CELL = 2 * HALF
SS = 16           # supersampling factor for the coverage raster
FIRST_CODE = 0xE100


def tick_coverage(i: int, w_out: float, w_in: float, centre: float) -> np.ndarray:
    """(CELL, CELL) float coverage 0..1 of tick i, rasterised at SS x and box-filtered.

    w_out / w_in: tick width at the outer / inner end (equal = straight, different = tapered).
    centre: dial centre in cell pixels. HALF (a pixel CORNER) makes an EVEN-width straight tick
    cover whole pixels at 12/3/6/9; HALF + 0.5 (a pixel CENTRE) does the same for an ODD width.
    """
    a = math.radians(90.0 - i * 360.0 / N)       # math angle; tick 0 points straight up
    dx, dy = math.cos(a), -math.sin(a)           # radial unit vector in screen coords (y down)
    px, py = -dy, dx                             # perpendicular unit vector
    # Analytic rasterisation: test every sub-sample CENTRE ((k + 0.5) / SS px) against the tick
    # rectangle in its own (radial, tangential) frame. Unlike a polygon fill this has no inclusive-
    # edge bias, so a rectangle whose sides sit exactly on pixel boundaries (the cardinal ticks)
    # covers whole pixels and nothing else.
    s = (np.arange(CELL * SS) + 0.5) / SS - centre     # sample coords relative to the dial centre
    sx, sy = np.meshgrid(s, s)                          # sy grows downward (screen space)
    radial = sx * dx + sy * dy                          # distance along the tick
    tangential = sx * px + sy * py                      # distance across the tick
    # With the centre on a pixel CENTRE, the radial ends must move by the same half pixel so the
    # 12/3/6/9 tick ends also fall on pixel edges (length stays TICK_LEN).
    r_hi = R_OUT + (centre - HALF)
    r_lo = r_hi - TICK_LEN
    # Half-width grows linearly from the inner end (w_in) to the outer end (w_out).
    f = np.clip((radial - r_lo) / TICK_LEN, 0.0, 1.0)
    hw = (w_in + (w_out - w_in) * f) / 2.0
    inside = ((radial >= r_lo) & (radial < r_hi)
              & (tangential >= -hw) & (tangential < hw))
    return inside.astype(np.float64).reshape(CELL, SS, CELL, SS).mean(axis=(1, 3))  # box filter


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--width-out", type=float, default=TICK_W, help="tick width at the outer end (px)")
    ap.add_argument("--width-in", type=float, default=None, help="tick width at the inner end (px); default = --width-out")
    ap.add_argument("--out", default=str(OUT), help="output folder for cg_ticks.fnt + cg_ticks_0.png")
    args = ap.parse_args()
    w_out = args.width_out
    w_in = args.width_in if args.width_in is not None else w_out
    if not (0 < w_in <= 6 and 0 < w_out <= 6):
        print("tick widths must be in (0, 6] px")
        return 2
    # An odd OUTER width needs the centre on a pixel centre for the 12/3/6/9 outer ends to be crisp
    # (for a taper that keeps the outer end - where the mesh columns fall evenly - hard-edged).
    centre = HALF + (0.5 if int(round(w_out)) % 2 == 1 else 0.0)
    out_dir = Path(args.out)
    glyphs = []
    for i in range(N):
        cov = tick_coverage(i, w_out, w_in, centre)
        a8 = np.round(cov * 255.0).astype(np.uint8)
        ys, xs = np.nonzero(a8)
        if len(xs) == 0:
            print("tick %d rasterised empty - geometry broken" % i)
            return 2
        x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
        glyphs.append((i, x0, y0, a8[y0:y1, x0:x1]))

    # Pack the small glyph bitmaps in rows, 1 px apart.
    atlas_w, pad = 256, 1
    x = y = row_h = 0
    places = []
    for i, gx, gy, bmp in glyphs:
        h, w = bmp.shape
        if x + w + pad > atlas_w:
            x, y, row_h = 0, y + row_h + pad, 0
        places.append((x + pad, y + pad))
        x += w + pad
        row_h = max(row_h, h)
    atlas_h = 1
    while atlas_h < y + row_h + 2 * pad:
        atlas_h *= 2

    atlas = np.zeros((atlas_h, atlas_w), dtype=np.uint8)
    lines = []
    for (i, gx, gy, bmp), (ax, ay) in zip(glyphs, places):
        h, w = bmp.shape
        atlas[ay:ay + h, ax:ax + w] = bmp
        lines.append("char id=%d x=%d y=%d width=%d height=%d xoffset=%d yoffset=%d xadvance=%d "
                     "page=0 chnl=15" % (FIRST_CODE + i, ax, ay, w, h, gx, gy, CELL))

    out_dir.mkdir(parents=True, exist_ok=True)
    # RGB = A = coverage: the CIQ compiler takes ink from RGB, alpha only masks (genfont.py).
    Image.merge("RGBA", [Image.fromarray(atlas)] * 4).save(out_dir / (BASE + "_0.png"))
    with open(out_dir / (BASE + ".fnt"), "w", newline="\n") as f:
        f.write('info face="Claude Grid ticks" size=%d bold=0 italic=0 charset="" unicode=1 '
                'stretchH=100 smooth=1 aa=1 padding=0,0,0,0 spacing=1,1 outline=0\n' % CELL)
        f.write("common lineHeight=%d base=%d scaleW=%d scaleH=%d pages=1 packed=0 alphaChnl=0 "
                "redChnl=0 greenChnl=0 blueChnl=0\n" % (CELL, CELL, atlas_w, atlas_h))
        f.write('page id=0 file="%s_0.png"\n' % BASE)
        f.write("chars count=%d\n" % N)
        for ln in lines:
            f.write(ln + "\n")

    # Sanity: straight whole-pixel ticks must be fully hard at 12/3/6/9 (only 0 or 255 coverage).
    straight_whole = (w_out == w_in and float(w_out).is_integer())
    for i in ((0, 15, 30, 45) if straight_whole else ()):
        vals = set(np.unique(glyphs[i][3]).tolist())
        if not vals <= {0, 255}:
            print("tick %d is not pixel-aligned: coverage levels %s" % (i, sorted(vals)))
            return 2
    print("generated %s in %s: %d ticks, cell %d, centre %.1f, R_OUT=%d LEN=%d width out %.1f / in %.1f, atlas %dx%d"
          % (BASE, out_dir, N, CELL, centre, R_OUT, TICK_LEN, w_out, w_in, atlas_w, atlas_h))
    return 0


if __name__ == "__main__":
    sys.exit(main())
