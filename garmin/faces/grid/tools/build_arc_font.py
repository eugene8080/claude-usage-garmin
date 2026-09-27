"""Rebuild the Claude Grid battery arc (the 16 dashes across the top bezel) as a pre-rasterised
"arc font" (cg_arc) - the same treatment as the seconds ticks (build_tick_font.py).

WHY. The arc was 16 x dc.fillPolygon quads at floating-point corners with anti-aliasing on: each
dash hit the pixel grid at a different sub-pixel phase, so the dashes came out uneven and soft.
Here each dash is an exact rectangle rasterised once at SS x supersampling and box-filtered, so
all 16 have mathematically consistent coverage and clean corners.

GEOMETRY (must match ClaudeGridView / GridDraw.segmentArc):
  screen 454 x 454, centre = the pixel CORNER (227, 227);
  outer radius R = 227 - 3 = 224, dash length 15 (radially inward), dash width 10;
  16 dashes evenly from 122.5 deg to 57.5 deg (math angles, 90 = straight up), dash 0 on the left.

Each glyph has ZERO offsets and the runtime draws dash i at its own screen position ArcMetrics.X[i],
Y[i] (generated into source/ArcMetrics.mc), minus 1 on y for CIQ drawing glyphs one row low.
(A first version put every dash at its screen position via large .fnt xoffset/yoffset (up to ~400)
with a 454 px lineHeight: it compiled but rendered as scattered slivers in the simulator - the
compiled font evidently can't hold offsets/line heights that large. The tick font, whose offsets
stay under ~110, is fine.) Glyph codes 0xE140 + i (BMP private use).
Atlas RGB = alpha = coverage (the CIQ compiler reads ink from RGB; see genfont.py).

The font is declared in resources/fonts/fonts.xml (CGArc) for every device so the code compiles
everywhere, but GridDraw only uses it when the screen is 454 px; other screens keep the polygon arc.
Run from anywhere:  python garmin/faces/grid/tools/build_arc_font.py
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "resources" / "fonts"   # shared: the face only USES it on a 454 px screen
BASE = "cg_arc"

SCREEN = 454
CX = CY = SCREEN / 2.0        # pixel corner (227, 227)
R_OUT = SCREEN / 2.0 - 0      # 227: dashes reach the screen edge (editor arc rad=227, synthwave design; was 224)
DASH_LEN = 15
DASH_W = 10
N = 16
A_START, A_END = 122.5, 57.5  # degrees
SS = 16
FIRST_CODE = 0xE140


def dash(i: int) -> tuple[np.ndarray, int, int]:
    """Coverage bitmap of dash i (uint8) and its top-left screen pixel (x0, y0)."""
    a = math.radians(A_START + (A_END - A_START) * i / (N - 1))
    dx, dy = math.cos(a), -math.sin(a)          # radial unit vector, screen coords (y down)
    px, py = -dy, dx                            # tangential unit vector
    r0, r1, hw = R_OUT - DASH_LEN, R_OUT, DASH_W / 2.0
    corners = [(CX + dx * r + px * s * hw, CY + dy * r + py * s * hw) for r in (r0, r1) for s in (-1, 1)]
    x0 = int(math.floor(min(c[0] for c in corners))) - 1
    y0 = int(math.floor(min(c[1] for c in corners))) - 1
    x1 = int(math.ceil(max(c[0] for c in corners))) + 1
    y1 = int(math.ceil(max(c[1] for c in corners))) + 1
    # sample CENTRES of an SS x SS grid in every pixel of the bbox (no inclusive-edge bias)
    xs = x0 + (np.arange((x1 - x0) * SS) + 0.5) / SS - CX
    ys = y0 + (np.arange((y1 - y0) * SS) + 0.5) / SS - CY
    sx, sy = np.meshgrid(xs, ys)
    radial = sx * dx + sy * dy
    tang = sx * px + sy * py
    inside = (radial >= r0) & (radial < r1) & (tang >= -hw) & (tang < hw)
    cov = inside.astype(np.float64).reshape(y1 - y0, SS, x1 - x0, SS).mean(axis=(1, 3))
    a8 = np.round(cov * 255).astype(np.uint8)
    ys_, xs_ = np.nonzero(a8)
    ty0, ty1, tx0, tx1 = ys_.min(), ys_.max() + 1, xs_.min(), xs_.max() + 1
    return a8[ty0:ty1, tx0:tx1], x0 + int(tx0), y0 + int(ty0)


def main() -> int:
    glyphs = [dash(i) for i in range(N)]
    atlas_w, pad = 256, 1
    x = y = row_h = 0
    places = []
    for bmp, _, _ in glyphs:
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
    line_h = max(bmp.shape[0] for bmp, _, _ in glyphs)
    adv = max(bmp.shape[1] for bmp, _, _ in glyphs)
    for i, ((bmp, gx, gy), (ax, ay)) in enumerate(zip(glyphs, places)):
        h, w = bmp.shape
        atlas[ay:ay + h, ax:ax + w] = bmp
        lines.append("char id=%d x=%d y=%d width=%d height=%d xoffset=0 yoffset=0 xadvance=%d "
                     "page=0 chnl=15" % (FIRST_CODE + i, ax, ay, w, h, adv))
    OUT.mkdir(parents=True, exist_ok=True)
    Image.merge("RGBA", [Image.fromarray(atlas)] * 4).save(OUT / (BASE + "_0.png"))
    with open(OUT / (BASE + ".fnt"), "w", newline="\n") as f:
        f.write('info face="Claude Grid arc" size=%d bold=0 italic=0 charset="" unicode=1 '
                'stretchH=100 smooth=1 aa=1 padding=0,0,0,0 spacing=1,1 outline=0\n' % SCREEN)
        f.write("common lineHeight=%d base=%d scaleW=%d scaleH=%d pages=1 packed=0 alphaChnl=0 "
                "redChnl=0 greenChnl=0 blueChnl=0\n" % (line_h, line_h, atlas_w, atlas_h))
        f.write('page id=0 file="%s_0.png"\n' % BASE)
        f.write("chars count=%d\n" % N)
        for ln in lines:
            f.write(ln + "\n")
    # Per-dash screen positions for the runtime (see module docstring).
    mc = HERE.parent / "source" / "ArcMetrics.mc"
    mc.write_text(
        "// Generated by tools/build_arc_font.py - do not edit.\n"
        "// Screen top-left of each battery-arc dash glyph (cg_arc, 454 px screen), dash 0 = left.\n"
        "module ArcMetrics {\n"
        "    const X = [%s];\n"
        "    const Y = [%s];\n"
        "}\n" % (", ".join(str(g[1]) for g in glyphs), ", ".join(str(g[2]) for g in glyphs)),
        encoding="utf-8", newline="\n")
    print("generated %s: %d dashes, R=%.0f len=%d w=%d, atlas %dx%d -> %s"
          % (BASE, N, R_OUT, DASH_LEN, DASH_W, atlas_w, atlas_h, OUT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
