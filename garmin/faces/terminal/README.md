# Claude Terminal - Garmin watch face

A terminal/CLI-styled watch face for fenix 8 class watches (incl. tactix 8), modelled on the
"Agentic Pro" look. Shows a prompt line, the time, the date, and the three Claude usage meters
(5H / 1W / model) as CLI rows with bars, percentages, and reset times, plus a segmented battery
bar (the straight counterpart of Claude Grid's battery arc), in IBM Plex Mono - by default in the
Retro tube theme with scanlines (Night Owl is the alternative), with a glowing VFD time. In always-on (low power) the time becomes a 2 px outline HH:MM
(`stm_time_o`, from `tools/build_fonts_terminal.py`), the seconds and grey tracks go and the VFD mesh
(or scanlines) stays, much as
on Claude Grid.

A weather line sits at the top (condition icon + temperature, from `Toybox.Weather`; the icons
are Claude Grid's `cg_icon`, copied as `stm_icon` by `tools/build_fonts_terminal.py`). Garmin
Connect settings add a **colour theme** - **Retro tube** by default (green phosphor on a dark
green background, 80 %+ bars in the brightest green #11ff00; its own glow digit set, `rt*`, from
`tools/build_glow_time.py`) or Night Owl - and **Scanlines** (on by default), which swaps the VFD
mesh for horizontal CRT lines (`scan_tile`). Always-on stays
black in every theme, with the mesh / scanlines still over it.

In Retro tube *everything* glows. CIQ can't blur, so the text, the prompt and the weather icon
each have a pre-rendered halo font (`*_glow`, `glow_from_bmfont` in `tools/build_fonts_terminal.py`)
drawn under the sharp text in the text colour blended halfway to the background, and the lit bars
and battery segments get a two-step halo of rectangles. CIQ renders font coverage in only 4 levels,
so the halo is generated at full strength and quantises into three even glow steps.

All four settings are also on the watch (hold the face > Settings, `ClaudeFaceSettings.mc`),
including the prompt text via the watch's text entry (`WatchUi.TextPicker`) - the only way to set
them on a sideloaded face, since Garmin Connect edits settings only for store installs.

Updated: 2026-09-25

## Where the data comes from

A watch face cannot receive phone pushes or read another app's storage, so it **subscribes to
the complications the companion "Claude Usage" watch-app publishes**. The percentage is the
complication value; the reset time rides in the complication's `unit` field as raw
epoch-seconds and is formatted here (keeping the background publisher free of date formatting).
Because the identity of a custom complication is an internal UUID, the face can't construct
its Id directly - it enumerates `getComplications()` and matches ours by the "Claude..." label.

So this face needs BOTH apps sideloaded: the watch-app (publisher) and this face (subscriber),
and the watch-app opened once so its 5-minute background publish is registered.

## Settings (Garmin Connect)

- **Show seconds** (on by default) - the time shows `HH:MM:SS`. In high-power mode the whole
  face redraws every second. In always-on (low-power) mode the AMOLED tactix 8 doesn't call
  `onPartialUpdate`, so it holds the last second until you raise your wrist.
- **Prompt text** - the top line (default `fenix@tactix ~ $`, up to 24 characters). The layout
  editor's Prompt text is the default; the setting overrides it without a rebuild.
- A face that was already installed keeps its **stored** settings when you sideload a new build.
  So if it still shows the old prompt or no seconds, change them in Garmin Connect.

## Rendering

- **Sharp text.** Fonts are CIQ bitmap fonts generated from the TTF by
  `tools/build_fonts_terminal.py`. The generator writes the anti-aliased coverage into the atlas's
  **RGB as well as alpha**: the CIQ font compiler takes ink from RGB and uses alpha only as a mask,
  so a white-RGB atlas compiles 1-bit and bold (the old build rendered `claude ~ %` as `claude - %`).
- **Whole pixels.** Every text origin and every bar edge is snapped to an integer pixel
  (`text()` / `rect()` in the view), so bar ends are hard and glyphs aren't resampled.
- **VFD style (the default build)** - the time drawn from pre-rendered glow bitmaps and one 3 px
  mesh tiled over the whole face (same scheme as Claude Grid). The glow colours are baked into the
  bitmaps, so regenerate them after changing the time font or the theme:

  ```
  python tools/build_glow_time.py --face d6deeb --glow 82aaff
  ```

  To build the plain face, switch the three `base.*` lines in `monkey.jungle` as its comment shows.
- **Seconds repaint.** `onPartialUpdate` clips to the time's real band. In the VFD build that is
  the glow cell (`GlowTimeMetrics.Y0/H`); in the plain build it is the time font's line box. The
  band is capped at the first meter row. Inside the clip it blanks the band and redraws the
  prompt, time and date in full-update order, so a descender or a line box that crosses the band
  is never cut off or double-drawn.
- **Targets.** fenix 8 47mm / 51mm (= tactix 8), fenix 8 Pro 47mm and fenix 8 43mm - all AMOLED.
  The fonts are fixed pixel sizes laid out for the 454 px tactix 8; the 416 px 43mm fits too.
  The fenix 8 Solar models were dropped (not needed; their MIP screens can't show the glow).

## Fonts

IBM Plex Mono Regular (OFL, `resources/fonts/OFL.txt`), at the editor's sizes: prompt 26 px
(`STMono`), date + rows 25 px (`STMonoSmall`), time 70 px (`STMonoTime`). The `stm_*` file names
are the face's generic font slots, kept from the earlier Share Tech Mono build. To change the
typeface or a size, edit `TTF` / `FACE` / `WEIGHT` and the `generate(...)` calls in
`tools/build_fonts_terminal.py`, run it, then run `build_glow_time.py`:

```
python tools/build_fonts_terminal.py
```

## Layout editor

`editor/claude-terminal-editor.html` - drag / arrow-key / Tab through the elements, themes, a
grouped font menu (incl. dot-matrix faces), a preview time & date, and a VFD preview. It places
text by the watch's own rule (line top + font ascent + 1 row), so it matches the simulator. See
`editor/README.md`.

## Build

```
monkeyc -f monkey.jungle -o dist/ClaudeFace-fenix847mm.prg \
        -y ~/.garmin-keys/developer_key.der -d fenix847mm -r
```
