# Phone ↔ watch apps ↔ face contract

Updated: 2026-10-22

The Android app, the two Connect IQ watch apps and the watch faces are built separately, and no
compiler sees across them. Every value they must agree on is listed here — the app ids, message
keys and how they group, complication ids and label text. A mismatch builds cleanly and fails
silently on the watch (a face shows `--`, a push is dropped), so:

- **Change a value on one side → change the other side and this file in the same commit.**
- [`tools/check_contract.py`](tools/check_contract.py) reads every codebase *and the tables
  below* and fails on any disagreement. CI runs it on every push and pull request
  ([`contract.yml`](../.github/workflows/contract.yml)); run it locally with
  `python garmin/tools/check_contract.py`.

```
Android app ──(1) Connect IQ phone message──► Claude Usage    ──(2) complications 0-3──► watch faces
WatchBridge.kt   (the same message to both)   watch-app/                                 Claude Grid
                                          └─► Codex + Cursor  ──(2) complications 0-3──► Claude Terminal
                                              feed-app/
                 both build garmin/shared/source-usage/ (Snapshot.mc, the pages, the background service)
```

**Why two watch apps.** Connect IQ lets one app publish at most **four** complications — the
compiler refuses a fifth (`Exceeds maximum of 4 complications`). Claude's three meters fill most
of Claude Usage, and Codex and Cursor bring five more, so Claude Usage publishes Claude's three
plus Cursor API, and the Codex + Cursor app publishes the other four. Both get the same message
and keep their own copy; both show provider pages when opened (Claude Usage: Claude, Codex,
Cursor; Codex + Cursor: Codex, Cursor).

A face never talks to the phone: Connect IQ gives a watch face no phone-message channel and no
access to another app's Storage, so link (2) is the faces' only data source.

## 1. Phone → watch apps

The phone addresses each watch app by its Connect IQ app id:

<!-- check:app-id -->
| Where | Value |
| --- | --- |
| `app/src/main/java/com/usage/claudewidget/watch/WatchBridge.kt` — `WATCH_APP_ID` | `8a5bd20e02f34f58afb5f357a23a4a65` |
| `garmin/watch-app/manifest.xml` — `<iq:application id=…>` (Claude Usage) | the same |
| `app/src/main/java/com/usage/claudewidget/watch/WatchBridge.kt` — `FEED_APP_ID` | `43bb7ac1ca954af9a00dfff271303aee` |
| `garmin/feed-app/manifest.xml` — `<iq:application id=…>` (Codex + Cursor) | the same |
<!-- /check -->

The phone pushes to Claude Usage first (with one retry), then once to Codex + Cursor — only after
Claude Usage took the push, so the second app can neither delay nor fail the first.

The message is a flat dictionary built by `WatchBridge.payloadOf()` and read by
`Snapshot.store()` (`garmin/shared/source-usage/Snapshot.mc`), which also uses the keys as its
Storage keys. The keys come in **groups**; each group is one `payload += mapOf(...)` on the phone
and one `G_` array in `Snapshot.mc`:

<!-- check:payload -->
| Key | Type | Group | Meaning |
| --- | --- | --- | --- |
| `fh` | Number | `claude` | Claude 5-hour window, % used (0–100, rounded on the phone) |
| `fhr` | Number | `claude` | Claude 5-hour window reset, epoch **seconds** |
| `wk` | Number | `claude` | Claude weekly pool, % used |
| `wkr` | Number | `claude` | Claude weekly pool reset, epoch seconds |
| `ts` | Number | `claude` | When Orca fetched Claude's numbers, epoch seconds |
| `mw` | Number | `model` | Claude per-model weekly cap, % used |
| `mwr` | Number | `model` | Claude per-model weekly reset, epoch seconds |
| `mwn` | String | `model` | The capped model's name as the API gives it (e.g. `Fable`) |
| `xfh` | Number | `codex` | Codex 5-hour window, % used, or `-1` when Orca reported none |
| `xfhr` | Number | `codex` | Codex 5-hour window reset, epoch seconds (`0` = none) |
| `xwk` | Number | `codex` | Codex weekly window, % used, or `-1` |
| `xwkr` | Number | `codex` | Codex weekly window reset, epoch seconds |
| `xts` | Number | `codex` | When Orca fetched Codex's numbers, epoch seconds |
| `upl` | Number | `cursor` | Cursor monthly plan, % used, or `-1` |
| `uplr` | Number | `cursor` | Cursor plan reset (the billing cycle), epoch seconds |
| `uau` | Number | `cursor` | Cursor Auto pool ("Cursor Models"), % used, or `-1` |
| `uaur` | Number | `cursor` | Cursor Auto pool reset, epoch seconds |
| `uap` | Number | `cursor` | Cursor API pool ("Other Models"), % used, or `-1` |
| `uapr` | Number | `cursor` | Cursor API pool reset, epoch seconds |
| `uts` | Number | `cursor` | When Orca fetched Cursor's numbers, epoch seconds |
<!-- /check -->

Rules the table can't show:

- **A group travels whole or not at all.** The watch stores a group only when every key of it
  arrived with the right type, and **clears** a group that is absent: a provider the phone has no
  numbers for is blanked, not left stale. A message with no complete group is rejected and
  changes nothing, so a stray message cannot blank the display.
- **When a group is sent.** `claude` when the phone has Claude numbers; `model` only with
  `claude` and only when the account has a per-model cap; `codex` and `cursor` when the phone has
  any number for that provider. The phone keeps a provider's last numbers when Orca has none this
  time, with their own older fetch time, so the watch shows them as stale rather than losing them.
- **A missing window inside `codex` or `cursor` is `-1`** with reset `0`, and the watch leaves that
  row and complication empty. Claude's `fh` / `wk` instead go as `0` when one is missing: a watch
  app older than the provider pages rejects a message without both.
- **Epoch seconds, never milliseconds** — a Monkey C `Number` is 32-bit.

## 2. Watch apps → faces (complications)

Each app publishes four public complications (`resources/complications.xml` in its folder, labels
in `resources/strings/strings.xml`, published by `source/Publisher.mc` from the background service
on every push and every ~5 minutes). An id belongs to its app: Claude Usage's `3` and Codex +
Cursor's `3` are different complications.

<!-- check:complications -->
| App | Id | longLabel | shortLabel at runtime | Claude Terminal row |
| --- | --- | --- | --- | --- |
| `watch-app` | `0` | `Claude 5-hour usage` | `5H` | `5H` |
| `watch-app` | `1` | `Claude weekly usage` | `1W` | `1W` |
| `watch-app` | `2` | `Claude model weekly usage` | the model name, ≤ 5 chars (`1W` when there is no cap) | `model` |
| `watch-app` | `3` | `Cursor API usage` | `API` | — |
| `feed-app` | `0` | `Codex 5-hour usage` | `5H` | — |
| `feed-app` | `1` | `Codex weekly usage` | `1W` | — |
| `feed-app` | `2` | `Cursor plan usage` | `Plan` | — |
| `feed-app` | `3` | `Cursor Auto usage` | `Auto` | — |
<!-- /check -->

Each complication carries:

| Field | Content |
| --- | --- |
| `value` | % used as a Number, or `null` for "no data" (drawn empty, not `0%`) |
| `unit` | the reset time as a decimal **epoch-seconds string** — the face formats it (the background publisher has no date formatting) |
| `ranges` | `[0, 50, 80, 100]` — low / mid / near-cap zones for colouring a gauge |

**The ids are permanent.** A face configured to show complication `N` loses it if `N` changes.
Holding one on a face (hold-to-launch) opens its app on that provider's page.

### How a face finds the Claude meters

A face cannot construct the `Complications.Id` of another app's complication (its UUID is
internal), so it enumerates `Complications.getComplications()` and **matches on `longLabel`**:

- A complication is a Claude meter when its `longLabel` contains **`Claude`** — Claude Grid
  (`ClaudeGridView.isClaudeMeter`) and Claude Terminal (`ClaudeFaceView.findAndSubscribe`).
- Claude Terminal picks the row from the same label (`ClaudeFaceView.slotFor`): contains
  **`5-hour`** → `5H`; contains **`weekly`** but not **`model`** → `1W`; contains **`model`** → `model`.
- **No other label may contain `Claude`**, or the faces would take it for a Claude meter. The
  Codex and Cursor complications don't, so Claude Terminal ignores them (row "—"), and in Claude
  Grid they can be placed on any slot through the face's editor but are drawn as a plain number:
  no `%` sign and no ring fill, which Claude Grid gives only to Claude meters. Neither face was
  changed for Codex or Cursor (2026-10-22).

So **the longLabel text is part of the API**: rewording it breaks installed faces. The checker
applies these rules to the labels in each app's `strings.xml` and confirms each lands on its row
(or on none), and that both faces' source still contains the literals above.

## 3. Build targets and permissions

- Every face must declare `ComplicationSubscriber`; both watch apps declare
  `ComplicationPublisher`, `Communications` and `Background`.
- Both watch apps target the same devices, and a face must only target those — elsewhere there is
  nothing to subscribe to. Today all four apps target `fenix847mm`, `fenix8pro47mm` and
  `fenix843mm`.
- Each app publishes at most four complications (Connect IQ's limit; the checker repeats it).

## Adding a new face

1. Put it in `garmin/faces/<name>/`; take shared files from [`shared/`](shared/README.md).
2. Declare `ComplicationSubscriber`, find the meters by `longLabel` as above, and parse `unit`
   as epoch seconds.
3. If it relies on label text beyond `Claude`, add its literals to `FACE_LABEL_LITERALS` in
   `tools/check_contract.py` and describe the rule in the section above.
4. `python garmin/tools/check_contract.py` — it picks up the new face's manifest automatically.

## Adding a meter

1. Phone: put its keys in its provider's `payload += mapOf(...)` group in `WatchBridge.payloadOf`.
2. Watch: add `K_` constants and the keys to the matching `G_` array in `Snapshot.mc`, and a row
   to `UsagePageView.rowsOf()` in `UsagePages.mc`.
3. A complication for it goes in whichever app has a free id (each has four); add the id to that
   app's `Publisher.mc` and `complications.xml`, and classify it in `APPS` in
   `tools/check_contract.py`.
4. The tables above, then `python garmin/tools/check_contract.py`.
