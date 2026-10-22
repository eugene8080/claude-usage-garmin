# Codex + Cursor - Garmin companion app

Generated: 2026-10-22

Publishes **Codex and Cursor usage as watch-face complications**, so a face can show them. It is
the companion of [Claude Usage](../watch-app/README.md) and exists for one reason: Connect IQ lets
one app publish at most **four** complications (`monkeyc` refuses a fifth: "Exceeds maximum of 4
complications"), and Claude Usage's four are taken by Claude's three meters and Cursor API.

| Id | longLabel | shortLabel |
| --- | --- | --- |
| `0` | `Codex 5-hour usage` | `5H` |
| `1` | `Codex weekly usage` | `1W` |
| `2` | `Cursor plan usage` | `Plan` |
| `3` | `Cursor Auto usage` | `Auto` |

The ids are permanent and the labels are part of the contract with the faces
([`../CONTRACT.md`](../CONTRACT.md)): none may contain the word "Claude", or the Claude faces would
take it for a Claude meter. A meter the phone has no number for (Codex sent no 5-hour window on
2026-10-19) is published as `null`, so a face shows it empty, not `0%`.

## How it gets its numbers

The phone sends the same message to both watch apps (`WatchBridge.kt`, `FEED_APP_ID`): first to
Claude Usage, then - only once that push landed - once to this app. Each app keeps its own copy in
its own Storage; a watch app cannot read another app's Storage. The background service stores a
push and publishes at once, and republishes every 5 minutes.

**Open it once after every install or sideload**, so `onStart()` registers the background events;
until then nothing is published. Opening it shows the Codex and Cursor pages - the same pages as
Claude Usage's second and third. It has no glance of its own (the compiler notes that the shared
`(:glance)` code is ignored here - expected).

If it is not installed, the phone's status line says *"sent to … (Codex + Cursor app not
installed)"* and Claude Usage works as before.

## Build

Almost all the code is shared with Claude Usage in [`../shared/source-usage/`](../shared/README.md);
`source/` here is only the App class and the `Publisher` that maps meters to this app's ids.

```
monkeyc -f monkey.jungle -o dist/CodexCursor-fenix847mm.prg -y ~/.garmin-keys/developer_key.der -d fenix847mm -r
python ../tools/sideload.py feed          # copy the newest build to the watch
```

The version is the shared `../shared/source-usage/Version.mc`: both apps always show the same
number, so a mismatched pair on the watch is visible.

## Showing these on a face

Claude Grid's data fields accept any complication (hold the face → edit a field), these included.
Grid draws them as a plain number - no `%` and no ring fill, which it gives only to Claude meters.
Claude Terminal shows only its three Claude rows. Holding one of these on a face opens this app on
the matching page.
