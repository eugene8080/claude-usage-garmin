# garmin/shared

Updated: 2026-09-29

Files used by more than one Garmin project, kept here once instead of copied into each.
A project pulls them in through its `monkey.jungle` by relative path — nothing is duplicated.

| Path | What | Used by |
| --- | --- | --- |
| `resources-round-454x454/` | Launcher icon, 454 px family (fēnix 8 47 mm / tactix 8, fēnix 8 Pro 47 mm) | watch app, Claude Grid, Claude Terminal |
| `resources-round-416x416/` | Launcher icon, 416 px family (fēnix 8 43 mm) | watch app, Claude Grid, Claude Terminal |
| `resources-mesh/` | `MeshTile` — the full-face VFD mesh overlay | Claude Grid, Claude Terminal |
| `source-weather/` | `WeatherNow` — the weather reading the faces show, falling back to the stored hourly forecast (marked "~") once the phone has been away long enough for the observation to go stale | Claude Grid, Claude Terminal |
| `tools/genfont.py` | TTF → Connect IQ bitmap font (`.fnt` + atlas) generator | both faces' `tools/build_fonts*.py` |
| `tools/mesh_tile.py` | Generator for `resources-mesh/` | both faces' glow generators |
| `tools/IBMPlexMono-Regular.ttf` | The faces' typeface (OFL — `tools/IBMPlexMono-OFL.txt`) | both faces' font builders |

## Using a shared folder from a project

Resource folders go on the jungle's resource path, relative to the jungle file:

```
# garmin/faces/<face>/monkey.jungle
base.resourcePath = resources;../../shared/resources-mesh
fenix847mm.resourcePath = $(base.resourcePath);../../shared/resources-round-454x454
```

(`garmin/watch-app/` is one level shallower, so it uses `../shared/`.)

Source folders go on the source path the same way: `base.sourcePath = source;../../shared/source-weather`.

Python generators import the shared tools by putting this folder on `sys.path`:

```python
sys.path.insert(0, str(GARMIN / "shared" / "tools"))   # GARMIN = the garmin/ folder
import mesh_tile
```

## What belongs here

- **Byte-identical today** in two or more projects → move it here. A resource id must be defined
  once per build, so a shared folder should hold only ids no project defines itself.
- **Similar but diverged** (e.g. the two faces' `source-glow/GlowTime.mc`: 20 per-position
  bitmaps in Grid vs 11 glyphs + themes in Terminal) → leave it in the face until a third face
  needs it, then extract one parameterised version.
- **One face wants to differ** (its own launcher icon, say) → give that face its own folder and
  point its jungle there instead of at the shared one; the others are unaffected.

Nothing here may depend on a specific face. The data the faces read from the watch app is
not a file and lives in [`../CONTRACT.md`](../CONTRACT.md).
