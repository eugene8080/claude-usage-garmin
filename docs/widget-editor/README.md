# Usage Grid widget editor

Updated: 2026-10-19

**Built:** Eugene's design (2026-10-19) is in [`usage-grid-design.jsonc`](usage-grid-design.jsonc), and
the app draws it from `GridDesign` in `app/src/main/java/com/usage/claudewidget/widget/UsageGridGlanceUi.kt`
(gloss and bevel in `res/drawable/grid_box_overlay.xml`). To change the design:
1. Paste the `.jsonc` block into the editor and press **Apply pasted**.
2. Adjust it, then **Copy settings**.
3. Update `GridDesign`, `grid_box_overlay.xml` and the `.jsonc` together.

A self-contained page for designing the planned fourth home-screen widget, the 2&times;1
**usage grid**:
- 7 rows: Claude 5H / 1W / FA, Codex 1W, Cursor PL / AU / AP.
- Each row has 10 boxes, and each box is 10&nbsp;%.
- The box a percentage lands in is shaded by how far into its band the usage is, and carries the
  number.
- A right-hand column shows each row's reset time.

Open **`usage-grid-editor.html`** in any browser. Its only external requests are Google Fonts,
which supply the preview samples.

## Only native options

The widget will be drawn by Glance like the other three. It will not be a picture of the widget.
So the editor offers only what a RemoteViews widget can draw itself:

- Boxes in any colour, including a **gradient across the 10 boxes**. Each box gets its own
  colour, from the row's start colour to its end colour.
- **Rounded corners** (Android 12+), and **unused boxes** as a fill, an outline (nested boxes)
  or both.
- **Halo**: a translucent ring, or two, around each lit box. A widget can't blur, and a view
  can't paint outside its cell, so the ring sits in the gap between boxes: at most half the gap
  wide.
- **Gloss** and **bevel**: fixed drawables layered over the lit boxes.
- **Background gradient**: a fixed drawable built from the chosen colours.
- **Fonts**: Android's built-in families only, named the way Glance's `FontFamily("…")` takes
  them, in Normal / Medium / Bold:
  - `sans-serif` and its thin / light / medium / black aliases;
  - `sans-serif-condensed` (+ light / medium);
  - `serif`, `monospace`, `serif-monospace`, `casual`, `cursive`, `sans-serif-smallcaps`;
  - on recent Android, `roboto-flex` and `source-sans-pro`.

  I checked this list against the Android 16 emulator's `/system/etc/fonts.xml` on 2026-10-19.
  Phone makers can swap the default sans: ColorOS may render `sans-serif` in OPPO Sans.

Blur glow and bundled fonts would need the widget drawn as one picture. Eugene ruled that out on
2026-10-19.

## Use it

- **Theme** sets every colour and effect at once. There are 12 techy variations of the default
  orange / blue / grey. Editing any colour or effect switches to **Custom**.
- **Preview data**:
  - samples: today's numbers, a busier day, edge cases (0 / 5 / 60 / 61 / 69 / 97 / 100), all full,
    all empty;
  - plus a slider per row and 12/24-hour reset times.
- **Fonts the widget can use**: a table of every family with samples. Click a row to use it.
- **Size & spacing**:
  - presets for the 2&times;1 cell (GitHub-widget shape 180&times;114 dp, Pixel-class
    178&times;104 dp, foldable 230&times;150 dp);
  - padding, column widths and gaps;
  - "fit" sizes the boxes to the space left.
- **Address shortcut**: `usage-grid-editor.html#theme=neon&sample=busy` opens on a theme and
  sample. `font=` is also accepted.
- **Copy settings** and paste the block back to the agent. **Apply pasted** reads a block back in.
  **Reset to default** restores the approved v3 design.

The page remembers your last design in this browser (localStorage), so a reload keeps it.
