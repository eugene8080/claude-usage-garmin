"""Solid ("filled") weather icons in the style of Garmin's own watch-face icons, built from the
outline Tabler glyphs the faces already use (this Tabler build ships no *-filled glyphs).

A shape is filled by rendering its outline glyph and flood-filling the enclosed area, so the
edge keeps Tabler's anti-aliasing and the inside is solid. The multi-part icons (a cloud with
rain, snow, lightning or fog under it; a sun or moon behind a cloud) are composed from those
solid shapes plus drawn marks. Wherever one part sits in front of another, a moat (a gap about
1 px wide at 24 px) is cut out of the part behind, so the two never merge into one blob.

Everything is drawn at `ss` times the target size and box-filtered down, in the SAME frame
PIL's draw.text uses for a glyph (origin = pen x / line top, width = the cloud glyph's advance,
height = ascent + descent), so these line up with the real Tabler glyphs in a font atlas
(garmin/shared/tools/genfont.py, `extra=`).

    render(kind, ttf, size) -> (Image "L" coverage, xadvance)

Used by garmin/faces/grid/tools/build_fonts_grid.py (the 24 px cg_icon atlas, which Claude
Terminal copies as stm_icon) and garmin/faces/grid/editor/build_icon_picker.py (72 px previews).
"""
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import binary_dilation, binary_fill_holes

# Tabler code points the solid shapes are traced from.
SUN, MOON, CLOUD, WIND = 0xeb30, 0xeaf8, 0xea76, 0xec34

# Icon kind -> the code it is filed under in the face's icon atlas (BMP private use area; CIQ
# glyph codes are 16-bit). 0xE000 is the footprints glyph; 0xE001 / 0xE002 keep their old
# meaning (partly cloudy, day / night), now solid. ClaudeGridView.weatherGlyph and
# ClaudeFaceView.weatherGlyph ask for these codes.
CODES = {
    "partly_day": 0xE001,
    "partly_night": 0xE002,
    "clear_day": 0xE003,
    "clear_night": 0xE004,
    "cloudy": 0xE005,
    "rain": 0xE006,
    "snow": 0xE007,
    "storm": 0xE008,
    "fog": 0xE009,
    "wind": 0xE00A,
}
KINDS = list(CODES)


class _Canvas:
    """Coverage canvas (float 0..1) at supersampled size, composed with max()."""

    def __init__(self, ttf: str, size: int, ss: int):
        self.ttf, self.size, self.ss = ttf, size, ss
        base = ImageFont.truetype(ttf, size)
        asc, desc = base.getmetrics()
        self.adv = int(round(base.getlength(chr(CLOUD))))
        self.w, self.h = self.adv * ss, (asc + desc) * ss
        self.a = np.zeros((self.h, self.w), dtype=np.float64)
        # The Tabler glyph's own ink box at this size: every icon is laid out inside it, so the
        # composed icons have the same optical size and position as the plain glyphs.
        probe = self.glyph(CLOUD, 1.0)
        ys, xs = np.nonzero(probe > 0.05)
        full = self._render(SUN, 1.0)
        fys, fxs = np.nonzero(full > 0.05)
        self.box = (float(fxs.min()), float(fys.min()), float(fxs.max()), float(fys.max()))

    def _render(self, cp: int, scale: float) -> np.ndarray:
        font = ImageFont.truetype(self.ttf, int(round(self.size * self.ss * scale)))
        im = Image.new("L", (self.w * 2, self.h * 2), 0)
        ImageDraw.Draw(im).text((0, 0), chr(cp), font=font, fill=255)
        return np.asarray(im).astype(np.float64)[: self.h * 2, : self.w * 2] / 255.0

    def glyph(self, cp: int, scale: float) -> np.ndarray:
        return self._render(cp, scale)

    @staticmethod
    def crop(arr: np.ndarray) -> np.ndarray:
        ys, xs = np.nonzero(arr > 0.02)
        return arr[ys.min(): ys.max() + 1, xs.min(): xs.max() + 1]

    def solid(self, cp: int, scale: float) -> np.ndarray:
        """The glyph with its enclosed area filled, cropped to its ink."""
        cov = self._render(cp, scale)
        fill = binary_fill_holes(cov > 0.35).astype(np.float64)
        return self.crop(np.maximum(cov, fill))

    def outline(self, cp: int, scale: float) -> np.ndarray:
        return self.crop(self._render(cp, scale))

    def layer(self, part: np.ndarray, cx: float, cy: float) -> np.ndarray:
        """`part` placed with its centre at (cx, cy) (fractions of the ink box), on a blank layer."""
        x0, y0, x1, y1 = self.box
        px = x0 + cx * (x1 - x0) - part.shape[1] / 2.0
        py = y0 + cy * (y1 - y0) - part.shape[0] / 2.0
        out = np.zeros_like(self.a)
        ix, iy = int(round(px)), int(round(py))
        sx0, sy0 = max(0, -ix), max(0, -iy)
        dx0, dy0 = max(0, ix), max(0, iy)
        w = min(part.shape[1] - sx0, self.w - dx0)
        h = min(part.shape[0] - sy0, self.h - dy0)
        out[dy0: dy0 + h, dx0: dx0 + w] = part[sy0: sy0 + h, sx0: sx0 + w]
        return out

    def draw_layer(self, fn) -> np.ndarray:
        """A layer drawn with PIL: fn(ImageDraw, box) paints white on black at supersample."""
        im = Image.new("L", (self.w, self.h), 0)
        fn(ImageDraw.Draw(im), self.box)
        return np.asarray(im).astype(np.float64) / 255.0

    def put_behind(self, back: np.ndarray, front: np.ndarray, moat_px: float = 1.0) -> None:
        """Compose `front` over `back`, cutting a moat around the front out of the back."""
        cut = binary_dilation(front > 0.35, iterations=max(1, int(round(moat_px * self.ss))))
        self.a = np.maximum(self.a, np.maximum(front, np.where(cut, 0.0, back)))

    def put(self, layer: np.ndarray) -> None:
        self.a = np.maximum(self.a, layer)

    def image(self) -> Image.Image:
        img = Image.fromarray(np.round(np.clip(self.a, 0, 1) * 255).astype(np.uint8), "L")
        return img.resize((self.w // self.ss, self.h // self.ss), Image.BOX)


def _stroke(d: ImageDraw.ImageDraw, pts, width: float) -> None:
    """A polyline with round caps and joins."""
    w = max(1, int(round(width)))
    d.line(pts, fill=255, width=w, joint="curve")
    r = w / 2.0
    for x, y in (pts[0], pts[-1]):
        d.ellipse((x - r, y - r, x + r, y + r), fill=255)


def render(kind: str, ttf: str, size: int, ss: int = 4):
    """One solid weather icon at `size` px. Returns (coverage image "L", xadvance)."""
    if kind not in CODES:
        raise ValueError("unknown weather icon %r" % kind)
    c = _Canvas(ttf, size, ss)
    x0, y0, x1, y1 = c.box
    bw, bh = x1 - x0, y1 - y0
    pen = 0.095 * bw                                    # mark weight: ~2 px at 24 px

    def X(f):
        return x0 + f * bw

    def Y(f):
        return y0 + f * bh

    if kind == "clear_day":
        c.put(c.layer(c.solid(SUN, 1.0), 0.5, 0.5))
    elif kind == "clear_night":
        c.put(c.layer(c.solid(MOON, 1.0), 0.5, 0.5))
    elif kind == "cloudy":
        c.put(c.layer(c.solid(CLOUD, 1.0), 0.5, 0.52))
    elif kind in ("partly_day", "partly_night"):
        back = c.layer(c.solid(SUN if kind == "partly_day" else MOON, 0.62), 0.70, 0.30)
        front = c.layer(c.solid(CLOUD, 0.86), 0.42, 0.64)
        c.put_behind(back, front)
    elif kind == "wind":
        # Wind is strokes by nature; a heavier trace of the Tabler glyph reads as solid.
        cov = c.glyph(WIND, 1.0)
        thick = binary_dilation(cov > 0.35, iterations=max(1, int(round(0.03 * bw))))
        c.put(c.layer(c.crop(np.maximum(cov, thick.astype(np.float64))), 0.5, 0.5))
    else:
        # A solid cloud in the upper part, with the weather falling out of it.
        cloud = c.layer(c.solid(CLOUD, 0.80), 0.5, 0.36)
        if kind == "rain":
            def marks(d, box):
                for fx in (0.30, 0.52, 0.74):
                    _stroke(d, [(X(fx + 0.05), Y(0.70)), (X(fx - 0.03), Y(0.96))], pen)
            c.put_behind(cloud, c.draw_layer(marks))
        elif kind == "snow":
            def marks(d, box):
                r = 0.075 * bw
                for fx, fy in ((0.30, 0.78), (0.52, 0.93), (0.74, 0.78)):
                    d.ellipse((X(fx) - r, Y(fy) - r, X(fx) + r, Y(fy) + r), fill=255)
            c.put_behind(cloud, c.draw_layer(marks))
        elif kind == "storm":
            def bolt(d, box):
                # Wide enough to stay a solid bolt, not a hairline, at 24 px.
                d.polygon([(X(0.55), Y(0.42)), (X(0.31), Y(0.75)), (X(0.49), Y(0.75)),
                           (X(0.38), Y(1.02)), (X(0.76), Y(0.62)), (X(0.57), Y(0.62)),
                           (X(0.71), Y(0.42))], fill=255)
            c.put_behind(cloud, c.draw_layer(bolt))
        elif kind == "fog":
            def marks(d, box):
                _stroke(d, [(X(0.14), Y(0.78)), (X(0.86), Y(0.78))], pen)
                _stroke(d, [(X(0.30), Y(0.95)), (X(0.96), Y(0.95))], pen)
            c.put_behind(cloud, c.draw_layer(marks))
    return c.image(), c.adv
