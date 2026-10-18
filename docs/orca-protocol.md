# How the widget reads usage from desktop Orca

Updated: 2026-10-18

The phone app gets Claude, Codex and Cursor usage from **desktop Orca**
([onorca.dev](https://www.onorca.dev), source [stablyai/orca](https://github.com/stablyai/orca)).
It pairs with Orca as one more "mobile device" and asks Orca for its accounts snapshot over
the same end-to-end encrypted WebSocket that the Orca phone app uses. This file records what
was ported, from where, and how to check it again when Orca changes.

## Why this route (and not the Orca phone app)

- **The Orca Android app (`com.stably.orca.mobile`) holds no usage data that another app can
  read.** Android keeps app data private, and Orca Mobile has no exported content provider,
  data intent or widget. It also only *displays* the numbers: it asks desktop Orca for them.
- **Desktop Orca does the fetching** (`src/main/rate-limits/`): Claude from
  `api.anthropic.com/api/oauth/usage` with the Claude Code login, Codex from
  `chatgpt.com/backend-api/wham/usage`, Cursor through its local sign-in. It polls every
  15 minutes, and `accounts.list` with `refreshUsage: true` forces a refresh (Orca debounces
  repeats within 5 minutes).
- **So the widget calls `accounts.list` itself.** The credentials stay on the computer. The
  phone holds only a device token that desktop Orca can revoke.

The cost: **the numbers only refresh while desktop Orca is running and the phone can reach
it** (LAN, or Tailscale from anywhere). While the computer is off, the widgets keep the last
numbers and show the amber stale dot once they are over 31 minutes old.

## Source of the port

Ported on 2026-10-18 from stablyai/orca @ `1938bd055aedd349d07172056fec6810992d5e0e`, for
desktop Orca **1.4.224** (the build on PSCAP11). Live check: not yet run. Orca is MIT-licensed
(Copyright (c) 2026 Lovecast Inc.).

| Kotlin | Orca source it follows |
| --- | --- |
| `orca/NaCl.kt` | tweetnacl `box.keyPair`, `box.before`, `secretbox` (what Orca runs) |
| `orca/OrcaE2eeSession.kt` | `src/shared/paired-e2ee-v2-client-session.ts`, `mobile-e2ee-v2-contract.ts`, `paired-e2ee-v2-key-schedule.ts`, `mobile-e2ee-v2-framing.ts`, `paired-e2ee-client-handshake.ts` (v2 token auth) |
| `orca/OrcaClient.kt` | `mobile/src/transport/rpc-client-socket-session.ts`, `mobile-e2ee-v2-physical-channel.ts`, `rpc-envelope-fields.ts` |
| `orca/OrcaPairing.kt` | `src/shared/pairing.ts`, `mobile-relay-pairing-offer.ts`, `mobile-pairing-protocol-limits.ts` |
| `data/OrcaAccountsParser.kt` | `src/shared/rate-limit-types.ts`, `mobile/src/components/accounts-snapshot.ts`, `src/main/rate-limits/cursor-usage-mapping.ts` |

The server side it talks to: `src/main/runtime/rpc/e2ee-channel.ts` (handshake),
`ws-transport.ts` (port 6768, no origin check), `rpc/methods/accounts.ts` (`accounts.list`).

## Pairing code

Desktop Orca: **Settings → Mobile → pair a new device**. Its QR code is
`orca://pair?code=<base64url JSON>`. The copy button gives the same link. The JSON (offer
version 2) is:

```
{ v: 2, endpoint: "ws://100.x.y.z:6768", deviceToken, publicKeyB64 (32-byte X25519),
  pairedDeviceId?, scope?, relay?, hostDescriptor? }
```

- Each "pair a new device" mints a **new device token**. Desktop Orca reuses a token only
  while no device has connected with it yet. So the widget gets its own entry (shown as
  "Mobile <date>"), separate from the Orca phone app, and each can be revoked on its own.
- The widget dials only `endpoint` and ignores `relay`. In a Relay-only code with no address,
  `endpoint` is loopback, which would point at the phone itself. The app refuses that and asks
  for the computer's Tailscale or LAN address instead.

## Wire protocol (E2EE v2, transport "direct")

1. **Phone → desktop, plaintext text frame:**
   `{type:"e2ee_hello", v:2, clientPublicKeyB64, clientNonceB64 (32 B), capabilities:{framing:[2],
   payloadKinds:["text","binary"]}, context:{protocol:"orca-mobile-e2ee", initiator:"mobile",
   responder:"desktop", transport:"direct"}}`. The client key pair is fresh for every socket.
2. **Desktop → phone, plaintext:** `{type:"e2ee_ready", v:2, desktopPublicKeyB64, clientNonceB64
   (echo), desktopNonceB64, selection:{framing:2, payloadKinds:[...]}, context:{same}}`. The
   phone checks the exact key sets and the echoed nonce, and **pins `desktopPublicKeyB64` to the
   pairing code's key**. A different key means re-keyed or another computer, and the phone must
   pair again.
3. **Keys:** `shared = HSalsa20(X25519(clientSecret, desktopPublic), 0^16)` (NaCl `box.before`).
   `transcript` = a list of named fields from hello and ready; each field is
   `u32 len(name) ‖ name ‖ u32 len(value) ‖ value`, big-endian. `salt = SHA256("orca-mobile-e2ee/v2/salt\0" ‖ clientNonce ‖ desktopNonce)`,
   `info = "orca-mobile-e2ee/v2/session\0" ‖ SHA256(transcript)`, and
   `HKDF-SHA256(shared, salt, info, 96)` = mobile→desktop key ‖ desktop→mobile key ‖ session id.
4. **Frames:** `base64(nonce24 ‖ secretbox(header42 ‖ payload))`, where
   `nonce = sessionId[0..12) ‖ 0x02 ‖ direction ‖ kind ‖ 0x00 ‖ u64 counter` and
   `header = sessionId ‖ direction ‖ kind ‖ u64 counter`. Direction is 0 for mobile→desktop and
   1 for desktop→mobile. Kind is 0 for text and 1 for binary. Each direction has its own counter,
   starting at 0 and shared by both kinds. A replayed or reordered frame does not open.
5. **Auth (sealed):** the phone sends `{type:"e2ee_auth", v:2, transcriptHashB64, deviceToken}`.
   The desktop replies `{type:"e2ee_authenticated", v:2, transcriptHashB64}`. If it refuses the
   device, it sends a sealed `e2ee_error` and closes with **4001**.
6. **RPC (sealed):** `{id, deviceToken, method:"accounts.list", params:{refreshUsage:true}}`.
   The reply is `{id, ok:true, result}` or `{id, ok:false, error:{code, message}}`. Frames with
   other ids are skipped.

Not implemented, because the widget does not need them: the Orca Relay transport, legacy
(pre-v2) framing, `runtime.clientCapabilities.update` (advisory only), and subscriptions.
The widget opens one socket per refresh and closes it.

## What the widget reads from `accounts.list`

`result.rateLimits.{claude,codex,cursor}`, each Orca's `ProviderRateLimits` or `null`:

| Provider | Windows → widget rows |
| --- | --- |
| Claude | `session` → **5H**, `weekly` → **1W**, `fableWeekly` → **1W Fable** (a null reset borrows the weekly one) |
| Codex | `session` → **5H**, `weekly` → **1W** |
| Cursor | `monthly` → **Plan**, `buckets` "Cursor Models" → **Auto**, "Other Models" → **API**, "On-demand" → **On-dem** (first three rows only) |

Each window is `{usedPercent 0–100, windowMinutes, resetsAt (epoch ms | null)}`. `status`
(`ok` / `error` / `unavailable` / `idle` / `fetching`), `error` and `updatedAt` (Orca's last
successful fetch) decide the widget's notice and its stale dot. The watch payload
(garmin/CONTRACT.md) is cut from the Claude block. Its `ts` is Claude's `updatedAt`.

## Checking it again

- **Unit tests** (`./gradlew :app:testDebugUnitTest`, also run by CI):
  - `OrcaE2eeVectorsTest` pins the crypto to values that **Orca's own TypeScript** produced.
  - `OrcaClientTest` runs the whole conversation against a MockWebServer that plays desktop Orca.
  - Plus tests for the two parsers.
- **Regenerating the vectors** (only when Orca changes the protocol):
  1. Copy `mobile-e2ee-v2-contract.ts`, `mobile-e2ee-v2-framing.ts`,
     `paired-e2ee-v2-client-session.ts`, `paired-e2ee-v2-key-schedule.ts` and
     `paired-e2ee-primitives.ts` from Orca's `src/shared/` into a `shared/` folder next to
     [`orca-vectors/gen.ts`](orca-vectors/gen.ts).
  2. Run `npm i tweetnacl@1.0.3 @noble/hashes@1.8.0 tsx`.
  3. Run `npx tsx gen.ts > app/src/test/resources/orca/e2ee_v2_vectors.json`.
- **Live check against an installed desktop Orca:**
  `ORCA_PAIRING_CODE='orca://pair?code=…' ORCA_ENDPOINT=ws://127.0.0.1:6768 ./gradlew :app:testDebugUnitTest --tests '*OrcaLiveTest*' -i`.
  It prints each provider's meters, never the token.

## When Orca changes

- The protocol is versioned. A host that drops v2 refuses the hello with 4001, and the app then
  says "Orca refused the handshake - update desktop Orca". If that happens after an Orca
  update, compare the files in the table above against the commit this was ported from.
- `accounts.list` is not a public API. Orca can rename fields in `RateLimitState`. The parser
  ignores fields it does not know and treats a missing `rateLimits` as a failed fetch, so the
  widgets keep their last numbers instead of drawing zeros.
