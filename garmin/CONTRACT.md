# Phone ↔ watch app ↔ face contract

Updated: 2026-09-27

The Android app, the Connect IQ watch app and the watch faces are built separately, and no
compiler sees across them. Every value they must agree on is listed here — an app id, message
keys, complication ids and label text. A mismatch builds cleanly and fails silently on the watch
(a face shows `--`, a push is dropped), so:

- **Change a value on one side → change the other side and this file in the same commit.**
- [`tools/check_contract.py`](tools/check_contract.py) reads all three codebases *and the tables
  below* and fails on any disagreement. CI runs it on every push and pull request
  ([`contract.yml`](../.github/workflows/contract.yml)); run it locally with
  `python garmin/tools/check_contract.py`.

```
Android app ──(1) Connect IQ phone message──► watch app ──(2) complications──► watch faces
WatchBridge.kt                                Snapshot.mc  Publisher.mc        Claude Grid
                                                                               Claude Terminal
```

A face never talks to the phone: Connect IQ gives a watch face no phone-message channel and no
access to another app's Storage, so link (2) is the faces' only data source.

## 1. Phone → watch app

The phone addresses the watch app by its Connect IQ app id:

<!-- check:app-id -->
| Where | Value |
| --- | --- |
| `app/src/main/java/com/usage/claudewidget/watch/WatchBridge.kt` — `WATCH_APP_ID` | `8a5bd20e02f34f58afb5f357a23a4a65` |
| `garmin/watch-app/manifest.xml` — `<iq:application id=…>` | the same |
<!-- /check -->

The message is a flat dictionary built by `WatchBridge.payloadOf()` and read by
`Snapshot.store()` (`garmin/watch-app/source/Snapshot.mc`), which also uses the keys as its
Storage keys:

<!-- check:payload -->
| Key | Type | Sent | Meaning |
| --- | --- | --- | --- |
| `fh` | Number | always | 5-hour window, % used (0–100, rounded on the phone) |
| `fhr` | Number | always | 5-hour window reset, epoch **seconds** |
| `wk` | Number | always | Weekly pool, % used |
| `wkr` | Number | always | Weekly pool reset, epoch seconds |
| `ts` | Number | always | When the phone fetched these numbers, epoch seconds |
| `mw` | Number | with a model cap | Per-model weekly cap, % used |
| `mwr` | Number | with a model cap | Per-model weekly reset, epoch seconds |
| `mwn` | String | with a model cap | The capped model's name as the API gives it (e.g. `Fable`) |
<!-- /check -->

Rules the table can't show:

- **Epoch seconds, never milliseconds** — a Monkey C `Number` is 32-bit.
- `Snapshot.store()` **rejects** a message unless `fh` and `wk` are Numbers, so both must be
  sent every time.
- `mw` / `mwr` / `mwn` go **all together or not at all**. A message without them *clears* the
  model meter on the watch (it doesn't keep the last value).

## 2. Watch app → faces (complications)

The watch app publishes three public complications (`garmin/watch-app/resources/complications.xml`,
labels in `resources/strings/strings.xml`, published by `source/Publisher.mc` from the background
service every ~5 minutes):

<!-- check:complications -->
| Id | longLabel | shortLabel at runtime | Claude Terminal row |
| --- | --- | --- | --- |
| `0` | `Claude 5-hour usage` | `5H` | `5H` |
| `1` | `Claude weekly usage` | `1W` | `1W` |
| `2` | `Claude model weekly usage` | the model name, ≤ 5 chars (`1W` when there is no cap) | `model` |
<!-- /check -->

Each complication carries:

| Field | Content |
| --- | --- |
| `value` | % used as a Number, or `null` for "no data" (drawn empty, not `0%`) |
| `unit` | the reset time as a decimal **epoch-seconds string** — the face formats it (the background publisher has no date formatting) |
| `ranges` | `[0, 50, 80, 100]` — low / mid / near-cap zones for colouring a gauge |

**The ids are permanent.** A face configured to show complication `N` loses it if `N` changes.

### How a face finds the Claude meters

A face cannot construct the `Complications.Id` of another app's complication (its UUID is
internal), so it enumerates `Complications.getComplications()` and **matches on `longLabel`**:

- A complication is a Claude meter when its `longLabel` contains **`Claude`** — Claude Grid
  (`ClaudeGridView.isClaudeMeter`) and Claude Terminal (`ClaudeFaceView.findAndSubscribe`).
- Claude Terminal picks the row from the same label (`ClaudeFaceView.slotFor`): contains
  **`5-hour`** → `5H`; contains **`weekly`** but not **`model`** → `1W`; contains **`model`** → `model`.

So **the longLabel text is part of the API**: rewording it breaks installed faces. The checker
applies these rules to the labels in `strings.xml` and confirms each lands on its row, and that
both faces' source still contains the literals above.

## 3. Build targets and permissions

- Every face must declare `ComplicationSubscriber`; the watch app declares `ComplicationPublisher`.
- A face must only target devices the watch app also targets — elsewhere there is nothing to
  subscribe to. Today all three target `fenix847mm`, `fenix8pro47mm` and `fenix843mm`.

## Adding a new face

1. Put it in `garmin/faces/<name>/`; take shared files from [`shared/`](shared/README.md).
2. Declare `ComplicationSubscriber`, find the meters by `longLabel` as above, and parse `unit`
   as epoch seconds.
3. If it relies on label text beyond `Claude`, add its literals to `FACE_LABEL_LITERALS` in
   `tools/check_contract.py` and describe the rule in the section above.
4. `python garmin/tools/check_contract.py` — it picks up the new face's manifest automatically.
