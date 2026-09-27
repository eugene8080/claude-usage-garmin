"""Pre-render the Claude Grid time digits as full-colour RGBA bitmaps with glow + surface effects.

Option 4 from the sharpness investigation: instead of drawing the 139px hour/minute with the CIQ
bitmap font (one flat colour, or the 12-band clip-stack gradient for the minute), each digit is a
pre-composited image - the exact same glyph shape, with a per-pixel gradient, a bevel, and a
two-radius bloom baked in - drawn with dc.drawBitmap. The watch alpha-blends the PNG alpha
(fenix847mm: alphaBlendingSupport=True), so the glow falls off over whatever is underneath - but
only with packingFormat="png" on the bitmap resource (see write_drawables).

GLYPH SOURCE. The mask is cropped straight out of resources/fonts/cg_time_0.png using the
cg_time.fnt metrics, so the bitmaps are pixel-for-pixel the font's own shapes and land exactly
where the font would draw them. (Run tools/build_fonts_grid.py first if the font changed.)

CELL. Every digit is emitted on ONE uniform cell = the union of all glyph boxes relative to the
pen origin, plus PAD on every side for the bloom. So the runtime placement is a constant offset
from the pen: left = pen_x + X0, top = line_top + Y0 (X0/Y0 are written to GlowTimeMetrics.mc).

STYLES (one resource folder each, identical ids, selected by the jungle resourcePath):
    vfd   -> resources-glow-vfd/   bloom, vertical face gradient, top-edge bevel; NO baked mesh -
                                   the face's one screen-aligned mesh overlay covers the digits
    flat  -> resources-glow-flat/  no effects at all - alignment check vs the font (not built by
                                   default; run --styles flat to regenerate it for a re-check)
    (The earlier "glow" and "mesh" styles were retired on 25 Sep 2026 with test faces D and E.)

MESH OVERLAY (always written): the full-face mesh tile shared with Claude Terminal, written by
garmin/shared/tools/mesh_tile.py into garmin/shared/resources-mesh/ (see that module for the
grid geometry). Tiled over the whole face as the last draw step so the time, text, icons, rings
and arcs share ONE grid in ONE phase.

Outputs (paths relative to garmin/faces/grid/):
    resources-glow*/drawables/drawables.xml + gh0..gh9.png (hour) + gm0..gm9.png (minute)
    source-glow/GlowTimeMetrics.mc
    dist/glow_preview_<style>.png   (8x zoom + 1:1 composite for review; dist/ is gitignored)
    ../../shared/resources-mesh/drawables/drawables.xml + mesh_tile.png

Run from anywhere:  python garmin/faces/grid/tools/build_glow_digits.py [--styles vfd,flat]
"""
from __future__ import annotations

import argparse
import logging
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter

log = logging.getLogger("glow")

HERE = Path(__file__).resolve().parent
GRID = HERE.parent                                      # garmin/faces/grid/
GARMIN = GRID.parents[1]                                # garmin/
# The mesh tile is shared with Claude Terminal, so its generator lives in garmin/shared/tools/.
sys.path.insert(0, str(GARMIN / "shared" / "tools"))
import mesh_tile  # noqa: E402  (garmin/shared/tools/mesh_tile.py)

FNT = GRID / "resources" / "fonts" / "cg_time.fnt"
ATLAS = GRID / "resources" / "fonts" / "cg_time_0.png"
METRICS_MC = GRID / "source-glow" / "GlowTimeMetrics.mc"
PREVIEW_DIR = GRID / "dist"

PAD = 18  # bloom margin on every side; the wide glow (sigma 7) is < 1% alpha by ~2.6 sigma

# CIQ draws a bitmap-font glyph ONE row lower than (line top + .fnt yoffset). Measured in the
# simulator: the flat bitmap digits (style "flat") matched the font-drawn "09" exactly in x and
# best at dy=-1 (mean abs error 1.5 vs 6.5 at dy=0). Folded into Y0 so the runtime stays simple.
Y_CALIBRATION = 1

# Palette - must stay in lock-step with ClaudeGridView.HOUR_COL and GridDraw.GRAD_A / GRAD_B.
# Synthwave palette from the layout editor, 2026-09-25. Earlier palettes: the teal VFD set
# (hour glow / minute glow / GRAD_B 1ec693, GRAD_A b4eede, HOUR_BOT e2f4ee) and the editor's
# "Claude" theme (GRAD ff9255 -> ff3c3b, hour glow ffc4a4, minute glow = follow the gradient).
HOUR_TOP = (255, 255, 255)
HOUR_BOT = (255, 236, 250)       # faint pink fall-off (12 % of the hour glow) so the white hour has depth
HOUR_GLOW = (0xFF, 0x7E, 0xDB)   # synthwave pink bloom (editor "Hour glow")
# Minute bloom: None = each row glows in its own gradient colour; a fixed (r, g, b) overrides
# it. Both are settable with --hour-glow / --minute-glow (hex), which is what the layout
# editor's "Hour glow" / "Minute glow" pickers map to.
MINUTE_GLOW = (0xFC, 0x28, 0xA8) # hot magenta bloom (editor "Minute glow")
GRAD_A = (0xFF, 0x7E, 0xDB)      # Gradient 1 (pink)  - top of the minute
GRAD_B = (0xF9, 0x7E, 0x72)      # Gradient 2 (coral) - bottom of the minute

# The font path's minute gradient (ClaudeGridView.drawGradientText): over yc +/- HALF_H, solid
# Gradient 1 for the top (0.5 - FADE/2), a linear blend across the middle FADE, solid Gradient 2
# below. Reproduced here per pixel row instead of in 12 clip bands. HALF_H = 0.42 x the time
# size, as the editor draws it (153 px -> 64; it was 58 at 139 px) - keep in step with the view.
GRAD_HALF_H = 64
GRAD_FADE = 0.44


@dataclass(frozen=True)
class Glyph:
    x: int
    y: int
    w: int
    h: int
    xoff: int
    yoff: int
    adv: int


@dataclass(frozen=True)
class Style:
    name: str
    folder: str
    glow_tight: float      # alpha gain of the sigma-2.2 inner bloom
    glow_wide: float       # alpha gain of the sigma-7 outer bloom
    bevel: float           # 0..1 top-edge highlight / bottom-edge shade strength
    mesh: float            # 0..1 darkening of the VFD grid lines (0 = no mesh)
    effects: bool          # False = flat face colour only (alignment reference)


STYLES = {
    "flat": Style("flat", "resources-glow-flat", 0.0, 0.0, 0.0, 0.0, False),
    "vfd": Style("vfd", "resources-glow-vfd", 0.60, 0.42, 0.30, 0.0, True),
}


def hex_rgb(s: str) -> tuple[int, int, int]:
    """"#ffc4a4" / "ffc4a4" -> (255, 196, 164); rejects anything that isn't 6 hex digits."""
    h = s.strip().lstrip("#")
    if len(h) != 6 or any(c not in "0123456789abcdefABCDEF" for c in h):
        raise ValueError("not a 6-digit hex colour: %r" % s)
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def parse_fnt(path: Path) -> tuple[int, dict[str, Glyph]]:
    """Return (lineHeight, {char: Glyph}) from a BMFont text file."""
    line_h = None
    glyphs: dict[str, Glyph] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        parts = raw.split()
        if not parts:
            continue
        kv = dict(p.split("=", 1) for p in parts[1:] if "=" in p)
        if parts[0] == "common":
            line_h = int(kv["lineHeight"])
        elif parts[0] == "char":
            glyphs[chr(int(kv["id"]))] = Glyph(int(kv["x"]), int(kv["y"]), int(kv["width"]),
                                               int(kv["height"]), int(kv["xoffset"]),
                                               int(kv["yoffset"]), int(kv["xadvance"]))
    if line_h is None:
        raise ValueError("no 'common' line in %s" % path)
    missing = [d for d in "0123456789" if d not in glyphs]
    if missing:
        raise ValueError("%s lacks digits %s" % (path, missing))
    return line_h, glyphs


def cell_bounds(glyphs: dict[str, Glyph]) -> tuple[int, int, int, int]:
    """Union of all digit boxes relative to (pen_x, line_top), expanded by PAD."""
    ds = [glyphs[d] for d in "0123456789"]
    x0 = min(g.xoff for g in ds) - PAD
    y0 = min(g.yoff for g in ds) - PAD
    x1 = max(g.xoff + g.w for g in ds) + PAD
    y1 = max(g.yoff + g.h for g in ds) + PAD
    return x0, y0, x1, y1


def digit_mask(atlas_a: np.ndarray, g: Glyph, bounds: tuple[int, int, int, int]) -> np.ndarray:
    """The glyph's coverage (0..1 float) placed on the uniform cell."""
    x0, y0, x1, y1 = bounds
    cell = np.zeros((y1 - y0, x1 - x0), dtype=np.float64)
    crop = atlas_a[g.y:g.y + g.h, g.x:g.x + g.w].astype(np.float64) / 255.0
    ox, oy = g.xoff - x0, g.yoff - y0
    cell[oy:oy + g.h, ox:ox + g.w] = crop
    return cell


def lerp_rgb(a: tuple[int, int, int], b: tuple[int, int, int], t: np.ndarray) -> np.ndarray:
    """Per-row colour ramp: t is (H,) in 0..1 -> (H,1,3) float RGB in 0..1."""
    a_ = np.array(a, dtype=np.float64) / 255.0
    b_ = np.array(b, dtype=np.float64) / 255.0
    return (a_ + (b_ - a_) * t[:, None])[:, None, :]


def face_colour(kind: str, rows: np.ndarray, line_h: int, y0: int, effects: bool) -> np.ndarray:
    """(H,1,3) face colour per cell row. rows = 0..H-1."""
    y_rel = (y0 + rows) - line_h / 2.0          # screen y minus the row's VCENTER line
    if kind == "h":
        if not effects:
            return lerp_rgb(HOUR_TOP, HOUR_TOP, np.zeros_like(rows, dtype=np.float64))
        t = np.clip((y_rel + 50.0) / 100.0, 0.0, 1.0)  # across the ~100px glyph height
        return lerp_rgb(HOUR_TOP, HOUR_BOT, t)
    f = (y_rel + GRAD_HALF_H) / (2.0 * GRAD_HALF_H)
    lo, hi = 0.5 - GRAD_FADE / 2.0, 0.5 + GRAD_FADE / 2.0
    t = np.clip((f - lo) / (hi - lo), 0.0, 1.0)
    return lerp_rgb(GRAD_A, GRAD_B, t)


def shift_down(m: np.ndarray, n: int) -> np.ndarray:
    """m[y - n] (content moved DOWN by n rows); rows that come from outside are 0."""
    out = np.zeros_like(m)
    out[n:] = m[:-n]
    return out


def shift_up(m: np.ndarray, n: int) -> np.ndarray:
    out = np.zeros_like(m)
    out[:-n] = m[n:]
    return out


def render(kind: str, mask: np.ndarray, line_h: int, y0: int, st: Style) -> Image.Image:
    """Composite one digit to a straight-alpha RGBA image.

    Works in PREMULTIPLIED float space (colour already multiplied by coverage), because blurring
    and 'over' compositing are only correct there; converts back to straight alpha for the PNG.
    """
    h, w = mask.shape
    rows = np.arange(h)
    rgb = np.broadcast_to(face_colour(kind, rows, line_h, y0, st.effects), (h, w, 3)).copy()

    if st.effects and st.bevel > 0:
        # Bevel: light catches the TOP edges (pixel whose neighbour 2 rows up is empty), the
        # BOTTOM edges fall into shade. Both are masked by the glyph so they stay inside it.
        top_edge = np.clip(mask - shift_down(mask, 2), 0.0, 1.0)
        bot_edge = np.clip(mask - shift_up(mask, 2), 0.0, 1.0)
        rgb = rgb + (1.0 - rgb) * (st.bevel * 0.85 * top_edge)[..., None]
        rgb = rgb * (1.0 - st.bevel * 0.45 * bot_edge)[..., None]

    if st.mesh > 0:
        # Fine 3px VFD grid: every third row and column is dimmed, like the IV-22 tube mesh.
        yy, xx = np.mgrid[0:h, 0:w]
        grid = ((yy % 3) == 2) | ((xx % 3) == 2)
        rgb = rgb * np.where(grid, 1.0 - st.mesh, 1.0)[..., None]

    face_p = rgb * mask[..., None]              # premultiplied face
    out_p, out_a = face_p, mask.copy()

    if st.effects and (st.glow_tight > 0 or st.glow_wide > 0):
        if kind == "h":
            src_p = np.array(HOUR_GLOW, dtype=np.float64) / 255.0 * mask[..., None]
        else:
            # The minute glows in its own row colour (orange above, red below). The un-meshed
            # face colour feeds the bloom so the mesh doesn't dim the halo.
            if MINUTE_GLOW is not None:
                src_p = np.array(MINUTE_GLOW, dtype=np.float64) / 255.0 * mask[..., None]
            else:
                base = np.broadcast_to(face_colour(kind, rows, line_h, y0, True), (h, w, 3))
                src_p = base * mask[..., None]
        def bloom(sig: float, gain: float) -> tuple[np.ndarray, np.ndarray]:
            bp = np.stack([gaussian_filter(src_p[..., c], sig) for c in range(3)], axis=-1)
            ba = gaussian_filter(mask, sig)
            return bp * gain, ba * gain
        p1, a1 = bloom(2.2, st.glow_tight)
        p2, a2 = bloom(7.0, st.glow_wide)
        glow_p = np.clip(p1 + p2, 0.0, 1.0)
        glow_a = np.clip(a1 + a2, 0.0, 1.0)
        # face OVER glow
        out_p = face_p + glow_p * (1.0 - mask[..., None])
        out_a = mask + glow_a * (1.0 - mask)

    out_a = np.clip(out_a, 0.0, 1.0)
    safe = np.where(out_a > 1e-6, out_a, 1.0)
    straight = np.clip(out_p / safe[..., None], 0.0, 1.0)
    rgba = np.dstack([straight * 255.0, out_a * 255.0]).round().astype(np.uint8)
    # A pixel with alpha 0 must also be RGB 0: transparent-but-coloured pixels can bleed through
    # any resampling or palette step in the resource compiler.
    rgba[rgba[..., 3] == 0] = 0
    return Image.fromarray(rgba, "RGBA")


def write_drawables(folder: Path) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    lines = ["<drawables>",
             "    <!-- Generated by tools/build_glow_digits.py - do not edit. gh = hour (white),",
             "         gm = minute (Gradient 1->2).",
             "         packingFormat=\"png\" is REQUIRED: the default packing converts to the panel's",
             "         native format with a 1-bit transparency key, which deletes the whole bloom and",
             "         leaves hard stair-stepped edges (seen in the simulator). PNG packing keeps the",
             "         8-bit alpha for the device's alpha blending, and compresses the images. -->"]
    for kind in ("h", "m"):
        for d in range(10):
            lines.append('    <bitmap id="G%s%d" filename="g%s%d.png" packingFormat="png" />'
                         % (kind.upper(), d, kind, d))
    lines.append("</drawables>")
    (folder / "drawables.xml").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def write_metrics(bounds: tuple[int, int, int, int]) -> None:
    x0, y0, x1, y1 = bounds
    METRICS_MC.parent.mkdir(parents=True, exist_ok=True)
    METRICS_MC.write_text(
        "// Generated by tools/build_glow_digits.py - do not edit.\n"
        "// Offset of every glow-digit bitmap's top-left from (pen x, line top) of the cg_time font,\n"
        "// and the cell size. Same for every digit because all are emitted on one uniform cell.\n"
        "// Y0 includes the +%d row calibration CIQ applies to font glyphs (see Y_CALIBRATION).\n"
        "module GlowTimeMetrics {\n"
        "    const X0 = %d;\n"
        "    const Y0 = %d;\n"
        "    const W = %d;\n"
        "    const H = %d;\n"
        "}\n" % (Y_CALIBRATION, x0, y0 + Y_CALIBRATION, x1 - x0, y1 - y0),
        encoding="utf-8", newline="\n")


def preview(imgs: dict[str, Image.Image], line_h: int, adv: int,
            bounds: tuple[int, int, int, int], name: str) -> Path:
    """Composite '09' over '34' on black at the face's real spacing, plus an 3x zoom crop."""
    x0, y0, x1, y1 = bounds
    gap = 56
    w, h = 2 * adv + 80, 2 * gap + line_h + 60
    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 255))
    cx, cy = w // 2, h // 2
    for text, kind, yc in (("09", "h", cy - gap), ("34", "m", cy + gap)):
        pen = cx - (adv * len(text)) // 2
        top = yc - line_h // 2
        for i, ch in enumerate(text):
            img = imgs["%s%s" % (kind, ch)]
            canvas.alpha_composite(img, (pen + i * adv + x0, top + y0))
    zoom = canvas.resize((w * 3, h * 3), Image.NEAREST)
    sheet = Image.new("RGBA", (w + w * 3 + 10, h * 3), (40, 40, 40, 255))
    sheet.paste(canvas, (0, 0))
    sheet.paste(zoom, (w + 10, 0))
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    out = PREVIEW_DIR / ("glow_preview_%s.png" % name)
    sheet.convert("RGB").save(out)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--styles", default="vfd", help="comma-separated: vfd, flat")
    ap.add_argument("--hour-glow", default=None, help="hour bloom colour as hex, e.g. ffc4a4 (default peach)")
    ap.add_argument("--minute-glow", default=None,
                    help="minute bloom colour as hex (default: follow the minute's own gradient)")
    args = ap.parse_args()
    global HOUR_GLOW, MINUTE_GLOW
    try:
        if args.hour_glow:
            HOUR_GLOW = hex_rgb(args.hour_glow)
        if args.minute_glow:
            MINUTE_GLOW = hex_rgb(args.minute_glow)
    except ValueError as ex:
        log.error("%s", ex)
        return 2
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    names = [s.strip() for s in args.styles.split(",") if s.strip()]
    unknown = [n for n in names if n not in STYLES]
    if unknown:
        log.error("unknown style(s): %s (have %s)", unknown, sorted(STYLES))
        return 2

    line_h, glyphs = parse_fnt(FNT)
    advs = {glyphs[d].adv for d in "0123456789"}
    if len(advs) != 1:
        # The runtime places digit i at pen + i*advance; that needs a monospace digit set.
        log.error("time digits are not monospace (advances %s) - uniform-cell placement invalid", advs)
        return 2
    adv = advs.pop()
    atlas_img = Image.open(ATLAS)
    if atlas_img.mode != "RGBA":
        log.error("%s is %s, expected RGBA", ATLAS, atlas_img.mode)
        return 2
    atlas_a = np.asarray(atlas_img.getchannel("A"))
    bounds = cell_bounds(glyphs)
    write_metrics(bounds)
    log.info("cell %dx%d  X0=%d Y0=%d  adv=%d lineH=%d  -> %s", bounds[2] - bounds[0],
             bounds[3] - bounds[1], bounds[0], bounds[1], adv, line_h, METRICS_MC.name)

    tile = mesh_tile.write_mesh_tile()
    log.info("mesh  -> %s (%dpx tile, pitch %d, dim %.2f)", tile.relative_to(GARMIN).as_posix(),
             mesh_tile.MESH_TILE, mesh_tile.MESH_PITCH, mesh_tile.MESH_DIM)

    for name in names:
        st = STYLES[name]
        folder = GRID / st.folder / "drawables"
        write_drawables(folder)
        imgs: dict[str, Image.Image] = {}
        for kind in ("h", "m"):
            for d in "0123456789":
                img = render(kind, digit_mask(atlas_a, glyphs[d], bounds), line_h, bounds[1], st)
                img.save(folder / ("g%s%s.png" % (kind, d)), optimize=True)
                imgs[kind + d] = img
        total = sum((folder / ("g%s%d.png" % (k, d))).stat().st_size for k in "hm" for d in range(10))
        log.info("%-5s -> %s  (20 PNGs, %.1f KB)  preview %s", name, st.folder, total / 1024.0,
                 preview(imgs, line_h, adv, bounds, name).name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
