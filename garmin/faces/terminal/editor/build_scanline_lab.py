"""Build the Claude Terminal scanline lab: an interactive page to tune the CRT scanline effect on a
real simulator render of the face, then send the chosen settings back.

    python build_scanline_lab.py                        -> scanline-lab.html (committed)
    python build_scanline_lab.py --artifact OUT.html    -> the same page without the document
                                                           wrapper, for publishing as an Artifact

The page works on lab/base_clean.png: Claude Terminal in the Retro tube theme, captured 1:1 from
the Connect IQ simulator (fenix847mm, 454 x 454) with NO glow and NO overlay. It rebuilds the look
in the watch's own drawing order, so whatever it shows can be built on the watch:

  1. background: the theme background, scaled by "background brightness"; in the scanline rows it
     takes its own colour, so the background's lines can differ from the text's (on the watch: a
     background stripe tile drawn first);
  2. bleed: a blur of the lit pixels added back (on the watch: the halo fonts and the time's glow
     bitmaps, rebuilt at that radius and strength);
  3. the text, bars and icons (unchanged pixels from the render);
  4. the scanline overlay: every scanline row darkened by "lines on text" (the watch's scan tile,
     black at that alpha);
  5. rounding to the watch's 16-bit colours (R5 G6 B5) - the simulator shows the background
     #020F06 as (0,12,0), and faint line shades collapse the same way on the watch.

lab/base_current.png is the face as it ships (glow + scanlines every 3rd row at 45 %), shown for
comparison with the lab's "Today" preset. Recapture both with the simulator if the face changes.
"""
import argparse
import base64
import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent


def data_uri(path: Path) -> str:
    return "data:image/png;base64," + base64.b64encode(path.read_bytes()).decode("ascii")


PAGE = r"""<title>Terminal Scanline Lab</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@500;600&family=IBM+Plex+Sans:wght@400;600&display=swap">
<style>
  /* One dark look on purpose (a CRT bench). Colours from the face's Retro tube theme. */
  :root {
    color-scheme: dark;
    --bg: #050806; --panel: #0c120e; --panel-hi: #122017; --line: #1d2e22; --screen: #000;
    --text: #e6f2e9; --dim: #86a892; --green: #2bdc63; --bright: #66ff8f; --amber: #ffcf5a;
    --mono: "IBM Plex Mono", ui-monospace, Consolas, monospace;
    --sans: "IBM Plex Sans", system-ui, "Segoe UI", sans-serif;
  }
  * { box-sizing: border-box; }
  body { background: var(--bg); color: var(--text); font: 15px/1.5 var(--sans); margin: 0;
         padding-inline: 16px; padding-block: 24px 40px; }
  main { max-width: 1060px; margin: 0 auto; display: grid; gap: 30px; }
  h1 { font: 600 26px/1.2 var(--mono); margin: 0; }
  h1 span { color: var(--green); }
  header p, section > p { margin: 6px 0 0; color: var(--dim); max-width: 70ch; }
  h2 { font: 600 13px/1 var(--mono); text-transform: uppercase; letter-spacing: .12em; color: var(--amber); margin: 0 0 10px; }
  .presets { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 470px), 1fr)); gap: 12px; }
  .preset { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 10px;
            display: grid; gap: 8px; cursor: pointer; text-align: left; color: inherit; font: inherit; }
  .preset:hover { border-color: var(--dim); }
  .preset.on { border-color: var(--green); box-shadow: 0 0 0 1px var(--green) inset; }
  .preset .name { display: flex; justify-content: space-between; gap: 8px; font: 600 13px var(--mono); }
  .preset .name small { color: var(--dim); font-weight: 500; }
  .strip { overflow-x: auto; }
  .strip canvas, .strip img { display: block; image-rendering: pixelated; }
  .bench { display: grid; grid-template-columns: minmax(0, 1fr) 330px; gap: 20px; align-items: start; }
  .view { display: grid; gap: 12px; }
  .screenwrap { overflow: auto; background: #000; border: 1px solid var(--line); border-radius: 10px; padding: 8px; }
  #face { display: block; image-rendering: pixelated; }
  .fit #face { width: 100%; height: auto; max-width: 454px; }
  #zoom { display: block; width: 100%; height: auto; image-rendering: pixelated; border: 1px solid var(--line); border-radius: 10px; background: #000; }
  .viewbar { display: flex; gap: 14px; flex-wrap: wrap; align-items: center; color: var(--dim); font-size: 13px; }
  .controls { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 16px; display: grid; gap: 14px; position: sticky; top: 12px; }
  .ctl { display: grid; gap: 4px; }
  .ctl label { display: flex; justify-content: space-between; gap: 10px; font-size: 13.5px; }
  .ctl label b { font: 600 13px var(--mono); color: var(--bright); font-variant-numeric: tabular-nums; }
  .ctl small { color: var(--dim); font-size: 12px; line-height: 1.35; }
  input[type=range] { width: 100%; accent-color: var(--green); }
  .check { display: flex; gap: 8px; align-items: center; font-size: 13.5px; }
  #out { width: 100%; min-height: 96px; resize: vertical; background: #000; color: var(--text); border: 1px solid var(--line);
         border-radius: 8px; padding: 10px; font: 500 12.5px/1.5 var(--mono); }
  .actions { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
  button.act { font: 600 14px var(--sans); border-radius: 8px; padding: 8px 14px; cursor: pointer; border: 1px solid var(--line); }
  #copy { background: var(--green); color: #021; border-color: var(--green); }
  #reset { background: transparent; color: var(--dim); }
  button:focus-visible, input:focus-visible { outline: 2px solid var(--amber); outline-offset: 2px; }
  #status { color: var(--dim); font-size: 12.5px; }
  footer { color: var(--dim); font-size: 12.5px; }
  @media (max-width: 860px) { .bench { grid-template-columns: 1fr; } .controls { position: static; } }
</style>
<main>
  <header>
    <h1>Terminal <span>scanline lab</span></h1>
    <p>Claude Terminal in its Retro tube theme, rendered by the Connect IQ simulator, with the scanlines rebuilt the way the
      watch draws them: background, glow, text, then the line overlay, rounded to the watch&rsquo;s 16-bit colours. Pick a
      preset or move the sliders, then copy the settings at the bottom of the controls and send them back.</p>
  </header>

  <section>
    <h2>Presets</h2>
    <p>The top band of the face at true size, one pixel per watch pixel. Tap one to load it into the sliders. &ldquo;As it
      ships&rdquo; is the real simulator render today, for comparing against the lab&rsquo;s &ldquo;Today&rdquo;.</p>
    <div class="presets" id="presets"></div>
  </section>

  <section>
    <h2>Bench</h2>
    <div class="bench">
      <div class="view">
        <div class="viewbar">
          <label class="check"><input type="checkbox" id="fit"> Fit to width (scaled: fine lines may shimmer)</label>
        </div>
        <div class="screenwrap" id="wrap"><canvas id="face" width="454" height="454" aria-label="The face with the current settings"></canvas></div>
        <canvas id="zoom" width="1122" height="420" aria-label="Three times magnified view of the time"></canvas>
        <div class="viewbar">Magnified 3&times;: the time, pixel for pixel.</div>
      </div>
      <div class="controls">
        <div class="ctl"><label for="pitch">Line spacing <b id="pitchV"></b></label>
          <input type="range" id="pitch" min="2" max="8" step="1">
          <small>Pixels from one scanline to the next. Smaller = more, finer lines.</small></div>
        <div class="ctl"><label for="rows">Line thickness <b id="rowsV"></b></label>
          <input type="range" id="rows" min="1" max="7" step="1">
          <small>Dark rows in each repeat (at most spacing &minus; 1).</small></div>
        <div class="ctl"><label for="text">Lines on text <b id="textV"></b></label>
          <input type="range" id="text" min="0" max="90" step="1">
          <small>How much the lines darken the lit text, bars and glow.</small></div>
        <div class="ctl"><label for="bgl">Lines on background <b id="bglV"></b></label>
          <input type="range" id="bgl" min="-60" max="90" step="1">
          <small>How dark the lines are on the background. Negative = lines lighter than the background.</small></div>
        <div class="ctl"><label for="bright">Background brightness <b id="brightV"></b></label>
          <input type="range" id="bright" min="1" max="5" step="0.25">
          <small>The green behind everything, &times; today&rsquo;s. Lines on the background need some light to show.</small></div>
        <div class="ctl"><label for="bleed">Bleed <b id="bleedV"></b></label>
          <input type="range" id="bleed" min="0" max="160" step="5">
          <small>Glow spilling around lit pixels.</small></div>
        <div class="ctl"><label for="radius">Bleed radius <b id="radiusV"></b></label>
          <input type="range" id="radius" min="1" max="8" step="1">
          <small>How far the glow spreads, in pixels.</small></div>
        <label class="check"><input type="checkbox" id="quant" checked> Watch colours (16-bit)</label>
        <textarea id="out" readonly aria-label="Settings to send back"></textarea>
        <div class="actions">
          <button class="act" id="copy" type="button">Copy settings</button>
          <button class="act" id="reset" type="button">Back to Today</button>
          <span id="status" role="status"></span>
        </div>
      </div>
    </div>
  </section>

  <footer>Generated: @@DATE@@ by garmin/faces/terminal/editor/build_scanline_lab.py &middot; base render: Connect IQ simulator,
    fenix847mm, Retro tube, glow and overlay off.</footer>
</main>
<img id="baseClean" src="@@CLEAN@@" alt="" hidden>
<img id="baseCurrent" src="@@CURRENT@@" alt="" hidden>
<script>
(function () {
  "use strict";
  var W = 454, H = 454;
  var BG = [0, 12, 0];                 // the theme background as the watch shows it (020F06, 16-bit)
  var BAND = [80, 230];                // preset strips: prompt, time and date rows
  var ZOOM = { x: 40, y: 118, w: 374, h: 140, s: 3 };
  var PRESETS = [
    { id: "today",  name: "Today",               note: "every 3rd row, 45%",  p: { pitch: 3, rows: 1, text: 45, bgl: 45, bright: 1,    bleed: 60,  radius: 2 } },
    { id: "strong", name: "A · Stronger",        note: "same lines, darker",  p: { pitch: 3, rows: 1, text: 65, bgl: 65, bright: 1.5,  bleed: 70,  radius: 2 } },
    { id: "pip",    name: "B · Pip-Boy",         note: "4 px, thick, lit bg", p: { pitch: 4, rows: 2, text: 55, bgl: 55, bright: 3,    bleed: 90,  radius: 3 } },
    { id: "fine",   name: "C · Fine and dense",  note: "every 2nd row",       p: { pitch: 2, rows: 1, text: 45, bgl: 50, bright: 2,    bleed: 70,  radius: 2 } },
    { id: "heavy",  name: "D · Heavy CRT",       note: "5 px, deep, glowing", p: { pitch: 5, rows: 2, text: 70, bgl: 80, bright: 2.5,  bleed: 120, radius: 4 } },
    { id: "soft",   name: "E · Soft text, lit bg", note: "lines mostly on bg", p: { pitch: 3, rows: 1, text: 30, bgl: 75, bright: 3,    bleed: 80,  radius: 3 } },
    { id: "invert", name: "F · Light bg lines",  note: "bright lines on bg",  p: { pitch: 4, rows: 2, text: 50, bgl: -40, bright: 2.5, bleed: 80,  radius: 3 } }
  ];
  var KEYS = ["pitch", "rows", "text", "bgl", "bright", "bleed", "radius"];
  var base = null, mask = null;
  var cur = Object.assign({}, PRESETS[0].p);

  function pixels(img) {
    var c = document.createElement("canvas"); c.width = W; c.height = H;
    var x = c.getContext("2d"); x.drawImage(img, 0, 0);
    return x.getImageData(0, 0, W, H).data;
  }

  // Lit pixels (text, bars, icons) vs background, soft at anti-aliased edges.
  function buildMask() {
    mask = new Float32Array(W * H);
    for (var i = 0; i < W * H; i++) {
      var o = i * 4;
      var d = Math.max(Math.abs(base[o] - BG[0]), Math.abs(base[o + 1] - BG[1]), Math.abs(base[o + 2] - BG[2]));
      mask[i] = Math.min(1, d / 40);
    }
  }

  // Separable box blur, three passes (close to a gaussian), on one float channel.
  function boxBlur(src, w, h, r) {
    var a = Float32Array.from(src), b = new Float32Array(src.length), n = 2 * r + 1;
    function cx(v) { return v < 0 ? 0 : (v >= w ? w - 1 : v); }
    function cy(v) { return v < 0 ? 0 : (v >= h ? h - 1 : v); }
    for (var pass = 0; pass < 3; pass++) {
      for (var y = 0; y < h; y++) {          // horizontal: a -> b
        var row = y * w, acc = 0;
        for (var k = -r; k <= r; k++) acc += a[row + cx(k)];
        for (var x = 0; x < w; x++) {
          b[row + x] = acc / n;
          acc += a[row + cx(x + r + 1)] - a[row + cx(x - r)];
        }
      }
      for (var x2 = 0; x2 < w; x2++) {       // vertical: b -> a
        var acc2 = 0;
        for (var k2 = -r; k2 <= r; k2++) acc2 += b[cy(k2) * w + x2];
        for (var y2 = 0; y2 < h; y2++) {
          a[y2 * w + x2] = acc2 / n;
          acc2 += b[cy(y2 + r + 1) * w + x2] - b[cy(y2 - r) * w + x2];
        }
      }
    }
    return a;
  }

  function q(v, bits) { var m = (1 << bits) - 1; return Math.round(Math.max(0, Math.min(255, v)) * m / 255) * 255 / m; }

  // Rebuild rows y0..y1 of the face with settings p, as the watch would draw them.
  function render(p, y0, y1, quant) {
    var h = y1 - y0, n = W * h;
    var rows = Math.min(p.rows, p.pitch - 1);
    var t = p.text / 100, bl = p.bgl / 100;
    var k = (1 - bl) / Math.max(0.05, 1 - t);        // background colour in a scanline row, before the overlay
    var bgc = [BG[0] * p.bright, BG[1] * p.bright, BG[2] * p.bright];
    var out = [new Float32Array(n), new Float32Array(n), new Float32Array(n)];
    var lit = [new Float32Array(n), new Float32Array(n), new Float32Array(n)];
    var dark = new Uint8Array(h);
    for (var yy = 0; yy < h; yy++) dark[yy] = ((y0 + yy) % p.pitch) >= p.pitch - rows ? 1 : 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < W; x++) {
        var i = (y0 + y) * W + x, j = y * W + x, m = mask[i], o = i * 4;
        for (var c = 0; c < 3; c++) {
          var b = dark[y] ? Math.min(255, bgc[c] * k) : bgc[c];
          out[c][j] = b * (1 - m) + base[o + c] * m;
          lit[c][j] = base[o + c] * m;
        }
      }
    }
    if (p.bleed > 0) {
      for (var c2 = 0; c2 < 3; c2++) {
        var g = boxBlur(lit[c2], W, h, p.radius), s = p.bleed / 100;
        for (var j2 = 0; j2 < n; j2++) out[c2][j2] += g[j2] * s;
      }
    }
    var img = new ImageData(W, h);
    for (var y3 = 0; y3 < h; y3++) {
      var f = dark[y3] ? (1 - t) : 1;
      for (var x3 = 0; x3 < W; x3++) {
        var j3 = y3 * W + x3, o3 = j3 * 4;
        var r = out[0][j3] * f, gg = out[1][j3] * f, bb = out[2][j3] * f;
        if (quant) { r = q(r, 5); gg = q(gg, 6); bb = q(bb, 5); }
        img.data[o3] = r; img.data[o3 + 1] = gg; img.data[o3 + 2] = bb; img.data[o3 + 3] = 255;
      }
    }
    // Outside the round screen stays black.
    for (var y4 = 0; y4 < h; y4++) {
      var dy = y0 + y4 - H / 2 + 0.5;
      for (var x4 = 0; x4 < W; x4++) {
        var dx = x4 - W / 2 + 0.5;
        if (dx * dx + dy * dy > (W / 2) * (W / 2)) { var o4 = (y4 * W + x4) * 4; img.data[o4] = img.data[o4 + 1] = img.data[o4 + 2] = 0; }
      }
    }
    return img;
  }

  function fmt(k, v) {
    if (k === "pitch" || k === "radius") return v + " px";
    if (k === "rows") return v + (v === 1 ? " row" : " rows");
    if (k === "bright") return (+v).toFixed(2).replace(/0$/, "") + "×";
    return v + "%";
  }

  function readControls() {
    KEYS.forEach(function (k) { cur[k] = +document.getElementById(k).value; });
    var rowsEl = document.getElementById("rows");
    rowsEl.max = String(cur.pitch - 1);
    if (cur.rows > cur.pitch - 1) { cur.rows = cur.pitch - 1; rowsEl.value = String(cur.rows); }
  }

  function writeControls(p) {
    document.getElementById("rows").max = String(p.pitch - 1);
    KEYS.forEach(function (k) { document.getElementById(k).value = String(p[k]); });
    cur = Object.assign({}, p);
  }

  function describe(p) {
    return "Terminal scanlines: spacing " + p.pitch + " px, thickness " + p.rows + (p.rows === 1 ? " row" : " rows") +
      ", lines on text " + p.text + "%, lines on background " + p.bgl + "%, background brightness " +
      (+p.bright).toFixed(2).replace(/0$/, "") + "x, bleed " + p.bleed + "% radius " + p.radius + " px";
  }

  var faceCtx, zoomCtx, quant;
  function draw() {
    KEYS.forEach(function (k) { document.getElementById(k + "V").textContent = fmt(k, cur[k]); });
    var img = render(cur, 0, H, quant.checked);
    faceCtx.putImageData(img, 0, 0);
    zoomCtx.imageSmoothingEnabled = false;
    zoomCtx.drawImage(faceCtx.canvas, ZOOM.x, ZOOM.y, ZOOM.w, ZOOM.h, 0, 0, ZOOM.w * ZOOM.s, ZOOM.h * ZOOM.s);
    document.getElementById("out").value = describe(cur);
    var match = null;
    PRESETS.forEach(function (pr) { if (KEYS.every(function (k) { return pr.p[k] === cur[k]; })) match = pr.id; });
    document.querySelectorAll(".preset").forEach(function (el) { el.classList.toggle("on", el.dataset.id === match); });
  }

  function buildPresets() {
    var box = document.getElementById("presets"), h = BAND[1] - BAND[0];
    var shipped = document.createElement("div");
    shipped.className = "preset"; shipped.style.cursor = "default";
    shipped.innerHTML = '<div class="name"><span>As it ships</span><small>simulator render today</small></div><div class="strip"></div>';
    var c0 = document.createElement("canvas"); c0.width = W; c0.height = h;
    c0.getContext("2d").drawImage(document.getElementById("baseCurrent"), 0, BAND[0], W, h, 0, 0, W, h);
    shipped.querySelector(".strip").appendChild(c0);
    box.appendChild(shipped);
    PRESETS.forEach(function (pr) {
      var b = document.createElement("button");
      b.type = "button"; b.className = "preset"; b.dataset.id = pr.id;
      b.innerHTML = '<div class="name"><span></span><small></small></div><div class="strip"></div>';
      b.querySelector(".name span").textContent = pr.name;
      b.querySelector(".name small").textContent = pr.note;
      var c = document.createElement("canvas"); c.width = W; c.height = h;
      c.getContext("2d").putImageData(render(pr.p, BAND[0], BAND[1], true), 0, 0);
      b.querySelector(".strip").appendChild(c);
      b.addEventListener("click", function () { writeControls(pr.p); draw(); save(); });
      box.appendChild(b);
    });
  }

  var KEY = "terminal-scanline-lab-v1";
  function save() { try { localStorage.setItem(KEY, JSON.stringify(cur)); } catch (e) { /* storage blocked */ } }
  function load() { try { var v = JSON.parse(localStorage.getItem(KEY) || "null"); return v && KEYS.every(function (k) { return typeof v[k] === "number"; }) ? v : null; } catch (e) { return null; } }

  function start() {
    base = pixels(document.getElementById("baseClean"));
    buildMask();
    faceCtx = document.getElementById("face").getContext("2d");
    zoomCtx = document.getElementById("zoom").getContext("2d");
    quant = document.getElementById("quant");
    buildPresets();
    writeControls(load() || PRESETS[0].p);
    KEYS.forEach(function (k) { document.getElementById(k).addEventListener("input", function () { readControls(); draw(); save(); }); });
    quant.addEventListener("change", draw);
    document.getElementById("fit").addEventListener("change", function (e) { document.getElementById("wrap").classList.toggle("fit", e.target.checked); });
    document.getElementById("reset").addEventListener("click", function () { writeControls(PRESETS[0].p); draw(); save(); });
    document.getElementById("copy").addEventListener("click", function () {
      var out = document.getElementById("out"), st = document.getElementById("status");
      function fallback() { out.focus(); out.select(); st.textContent = "Selected. Copy it with your device's copy command."; }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(out.value).then(function () { st.textContent = "Copied. Paste it into the chat."; }, fallback);
      } else { fallback(); }
    });
    draw();
  }

  var imgs = [document.getElementById("baseClean"), document.getElementById("baseCurrent")];
  var pending = imgs.filter(function (i) { return !i.complete; }).length;
  if (!pending) start(); else imgs.forEach(function (i) { if (!i.complete) i.addEventListener("load", function () { if (--pending === 0) start(); }); });
})();
</script>
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--artifact", metavar="OUT", help="write the page without the document wrapper, for an Artifact")
    args = ap.parse_args()
    page = (PAGE.replace("@@CLEAN@@", data_uri(HERE / "lab" / "base_clean.png"))
                .replace("@@CURRENT@@", data_uri(HERE / "lab" / "base_current.png"))
                .replace("@@DATE@@", datetime.date.today().isoformat()))
    if args.artifact:
        out = Path(args.artifact)
        out.write_text(page, encoding="utf-8", newline="\n")
    else:
        out = HERE / "scanline-lab.html"
        out.write_text('<!doctype html>\n<html lang="en"><head><meta charset="utf-8">\n'
                       '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
                       + page + "</html>\n", encoding="utf-8", newline="\n")
    print("wrote %s (%d bytes)" % (out, out.stat().st_size))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
