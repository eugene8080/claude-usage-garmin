"""Generate a Connect IQ bitmap font (BMFont .fnt + PNG atlas) from a TTF.

Shared by both faces' font builders (garmin/faces/grid/tools/build_fonts*.py and
garmin/faces/terminal/tools/build_fonts_terminal.py). It preserves each glyph's own horizontal
advance, so a *proportional* face (Chakra Petch) sets its natural letter spacing instead of being
forced onto one column width; a monospace TTF simply comes out with one advance for every glyph.

CIQ tints the glyph by the text colour, so glyphs are drawn white and the coverage (the smooth
anti-aliased edge) is written into BOTH the RGB and the alpha channels.

Why both: the CIQ resource compiler takes a glyph pixel's ink level from its RGB brightness and
uses alpha only as an on/off mask (alpha == 0 -> empty). Pillow's draw.text on a transparent RGBA
image leaves RGB at a flat 255 on every pixel the glyph touches and puts the edge gradient in alpha
alone, so the compiler saw a 1-bit, fattened glyph and `antialias="true"` had nothing smooth to
keep. Verified in the simulator with a diagnostic atlas (RGB-only pixels and alpha-only pixels both
vanish; an alpha ramp under RGB=255 renders solid; an RGB ramp under alpha=255 renders as levels).

Callable as `generate(...)` (see garmin/faces/grid/tools/build_fonts_grid.py) or from the CLI:
    python genfont.py <ttf> <out_base> <size> <chars> [atlas_w] [face_name]
"""
import os
import sys
from PIL import Image, ImageFont, ImageDraw


OUTLINE_SS = 8  # supersampling for outline glyphs


def outline_coverage(ttf, size, weight, ch, width_px):
    """Anti-aliased hollow outline of `ch`: every point within `width_px` OUTSIDE the glyph edge.

    Pillow's stroke_width is not anti-aliased (it produces hard 0/255 pixels), which made the
    always-on outline time stair-stepped. Here the glyph is rendered at OUTLINE_SS x, the outline
    band is taken from an exact Euclidean distance transform of the empty space, and the band is
    box-filtered back down, so its thickness is `width_px` and its edges carry real coverage.

    Returns (uint8 coverage HxW, xoffset, yoffset): the offsets are from the pen / line-top origin,
    in the same frame as font.getbbox at 1x, and the SS canvas origin is snapped to a multiple of
    OUTLINE_SS so the downsampled pixels sit exactly on the 1x grid.
    """
    import math
    import numpy as np
    from scipy.ndimage import distance_transform_edt

    ss = OUTLINE_SS
    big = ImageFont.truetype(ttf, size * ss)
    if weight is not None:
        try:
            big.set_variation_by_axes([weight])
        except Exception:
            pass
    x0, y0, x1, y1 = big.getbbox(ch)
    reach = (width_px + 1) * ss
    ox = math.floor((x0 - reach) / ss) * ss          # canvas origin, SS coords, 1x-grid aligned
    oy = math.floor((y0 - reach) / ss) * ss
    w = math.ceil((x1 + reach - ox) / ss) * ss
    h = math.ceil((y1 + reach - oy) / ss) * ss
    canvas = Image.new("L", (w, h), 0)
    ImageDraw.Draw(canvas).text((-ox, -oy), ch, font=big, fill=255)
    inside = np.asarray(canvas) >= 128
    dist = distance_transform_edt(~inside)           # SS px from each empty sample to the glyph
    band = (~inside) & (dist <= width_px * ss)
    cov = band.reshape(h // ss, ss, w // ss, ss).mean(axis=(1, 3))
    cov8 = np.round(cov * 255.0).astype(np.uint8)
    ys, xs = np.nonzero(cov8)
    cy0, cy1, cx0, cx1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    return cov8[cy0:cy1, cx0:cx1], ox // ss + int(cx0), oy // ss + int(cy0)


def generate(ttf, out_base, size, chars, atlas_w=256, face_name="Chakra Petch",
             weight=None, stroke=0, emit_ids=None, extra=None):
    """Rasterise `chars` from `ttf` at `size` into a BMFont atlas.

    weight: for a variable font, the wght axis value (e.g. 500). Ignored for static TTFs.
    stroke: if > 0, draw hollow OUTLINE glyphs (px stroke, transparent interior) instead of
            solid fills - used for the always-on time. The glyph region is expanded by the
            stroke so the outline is never clipped, and xoffset/yoffset shift back by the same
            amount so an outlined glyph lands exactly where its solid twin would.
    emit_ids: optional list (parallel to `chars`) of the character codes to WRITE into the .fnt,
            when a glyph must be addressed by a different code than the one it is drawn from.
            CIQ can only address 16-bit (BMP) code points: a glyph filed under a code above
            0xFFFF (e.g. Tabler's footprints, U+10265) is in the atlas but never found, and draws
            as a tofu box. Remap such glyphs to a free BMP private-use code.
    extra: optional list of (emit_id, coverage image "L", xadvance) for glyphs that are not a
            character of the TTF (e.g. a composited cloud-with-sun icon). Each image is the glyph
            drawn in the same frame draw.text uses (origin = pen x / line top); it is trimmed to its
            ink and filed with matching xoffset/yoffset.
    """
    extra = list(extra or [])
    for eid, _img, _adv in extra:
        if eid > 0xFFFF:
            raise ValueError("extra glyph id %s is above 0xFFFF" % hex(eid))
    if emit_ids is not None and len(emit_ids) != len(chars):
        raise ValueError("emit_ids must be parallel to chars (%d vs %d)" % (len(emit_ids), len(chars)))
    ids = emit_ids if emit_ids is not None else [ord(c) for c in chars]
    too_big = [hex(i) for i in ids if i > 0xFFFF]
    if too_big:
        raise ValueError("code points above 0xFFFF can't be addressed on CIQ: %s - remap them "
                         "with emit_ids" % too_big)
    font = ImageFont.truetype(ttf, size)
    if weight is not None:
        try:
            font.set_variation_by_axes([weight])
        except Exception as ex:
            print("  (weight axis unavailable: %s)" % ex)
    ascent, descent = font.getmetrics()
    line_h = ascent + descent

    sw = int(stroke)
    pad = 1 + sw
    # Uniform grid cell sized to the widest glyph in the set (keeps packing trivial); each
    # glyph still records its OWN xadvance below, so rendered spacing stays proportional.
    max_w = 0
    for ch in chars:
        bb = font.getbbox(ch)
        max_w = max(max_w, bb[2] - bb[0], int(round(font.getlength(ch))))

    cell_w = max_w + 2 * pad + 2
    cell_h = line_h + 2 * pad + 2
    for _eid, img, _adv in extra:
        max_w = max(max_w, img.width)
    cell_w = max(cell_w, max_w + 2 * pad + 2)
    cols = max(1, atlas_w // cell_w)
    rows = (len(chars) + len(extra) + cols - 1) // cols

    atlas_h = 1
    while atlas_h < rows * cell_h:
        atlas_h *= 2

    atlas = Image.new("RGBA", (atlas_w, atlas_h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(atlas)
    outline_layer = Image.new("L", (atlas_w, atlas_h), 0) if sw > 0 else None

    lines = []
    for i, ch in enumerate(chars):
        col = i % cols
        row = i // cols
        gx = col * cell_w + pad
        gy = row * cell_h + pad
        adv = int(round(font.getlength(ch)))
        if sw > 0:
            # Hollow outline, anti-aliased, exactly `sw` px thick outside the glyph (see
            # outline_coverage). Placed at the cell's top-left; the offsets carry the position.
            cov, xo, yo = outline_coverage(ttf, size, weight, ch, sw)
            ch_h, ch_w = cov.shape
            if ch_w > cell_w - 2 or ch_h > cell_h - 2:
                raise ValueError("outline glyph %r (%dx%d) overflows its %dx%d cell"
                                 % (ch, ch_w, ch_h, cell_w, cell_h))
            ax, ay = col * cell_w + 1, row * cell_h + 1
            outline_layer.paste(Image.fromarray(cov), (ax, ay))
            lines.append(
                "char id=%d x=%d y=%d width=%d height=%d xoffset=%d yoffset=%d xadvance=%d page=0 chnl=15"
                % (ids[i], ax, ay, ch_w, ch_h, xo, yo, adv))
            continue
        draw.text((gx, gy), ch, font=font, fill=(255, 255, 255, 255))
        x0, y0, x1, y1 = font.getbbox(ch)
        gw = max(0, x1 - x0)
        gh = max(0, y1 - y0)
        lines.append(
            "char id=%d x=%d y=%d width=%d height=%d xoffset=%d yoffset=%d xadvance=%d page=0 chnl=15"
            % (ids[i], gx + x0, gy + y0, gw, gh, x0, y0, adv)
        )

    for k, (eid, img, adv) in enumerate(extra):
        i = len(chars) + k
        bb = img.getbbox()
        if bb is None:
            raise ValueError("extra glyph %s is empty" % hex(eid))
        crop = img.crop(bb)
        if crop.width > cell_w - 2 or crop.height > cell_h - 2:
            raise ValueError("extra glyph %s overflows its cell" % hex(eid))
        ax, ay = (i % cols) * cell_w + 1, (i // cols) * cell_h + 1
        atlas.paste((255, 255, 255, 255), (ax, ay, ax + crop.width, ay + crop.height), mask=crop)
        lines.append(
            "char id=%d x=%d y=%d width=%d height=%d xoffset=%d yoffset=%d xadvance=%d page=0 chnl=15"
            % (eid, ax, ay, crop.width, crop.height, bb[0], bb[1], adv))

    # Copy the coverage (alpha) into R, G and B so the compiler, which reads ink from RGB, gets the
    # anti-aliased edge; alpha stays as-is and still masks the empty pixels (see module docstring).
    cov = outline_layer if outline_layer is not None else atlas.getchannel("A")
    atlas = Image.merge("RGBA", (cov, cov, cov, cov))
    atlas.save(out_base + "_0.png")
    with open(out_base + ".fnt", "w", newline="\n") as f:
        f.write('info face="%s" size=%d bold=0 italic=0 charset="" unicode=1 '
                'stretchH=100 smooth=1 aa=1 padding=0,0,0,0 spacing=1,1 outline=0\n' % (face_name, size))
        # BMFont channel codes: 0 = glyph data. Every channel now carries the glyph (the old header
        # said alphaChnl=1, i.e. "alpha is an outline", which no longer describes the atlas).
        f.write("common lineHeight=%d base=%d scaleW=%d scaleH=%d pages=1 packed=0 alphaChnl=0 "
                "redChnl=0 greenChnl=0 blueChnl=0\n" % (line_h, ascent, atlas_w, atlas_h))
        f.write('page id=0 file="%s_0.png"\n' % os.path.basename(out_base))
        f.write("chars count=%d\n" % (len(chars) + len(extra)))
        for ln in lines:
            f.write(ln + "\n")
    print("generated %s size=%d atlas=%dx%d cols=%d rows=%d cell=%dx%d"
          % (out_base, size, atlas_w, atlas_h, cols, rows, cell_w, cell_h))


if __name__ == "__main__":
    generate(sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4],
             int(sys.argv[5]) if len(sys.argv) > 5 else 256,
             sys.argv[6] if len(sys.argv) > 6 else "Chakra Petch")
