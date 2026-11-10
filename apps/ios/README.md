# PiOS for iOS (native SwiftUI)

A native iPhone and iPad client for the same daemon the PWA talks to. Same
wire protocol (v2), same pairing, same relay; nothing on the server changes.

```
apps/ios/
  project.yml        XcodeGen spec for the app target (the .xcodeproj is generated)
  PiOS/              SwiftUI app: views, WebSocket transport, Keychain, file storage
  PiOSCore/          Swift package, platform-free: wire types, supervisor, outbox,
                     session store, transcript view. Port of protocol + client-core.
  e2e/               Harness that drives PiOSCore against a live daemon
```

`PiOSCore` imports nothing but Foundation, so it builds and tests on Linux as
well as macOS. Everything with UIKit or SwiftUI lives in `PiOS/`.

## Build and run (macOS)

Requirements: Xcode 15.3+ (iOS 17 SDK), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd apps/ios
brew install xcodegen
xcodegen generate
open PiOS.xcodeproj                      # or, without the GUI:
xcodebuild -project PiOS.xcodeproj -scheme PiOS \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

For a device build set `DEVELOPMENT_TEAM` in `project.yml` (or pass it to
`xcodebuild`). Bundle id is `dev.pios.app`.

## Pair

Run `pios-server pair` on the machine. Then either:

- paste the printed link (`https://<relay>/#pt=...`) into the pairing screen,
- scan it as a QR code (`qrencode -t ansiutf8 '<link>'` on the machine), or
- open it with the scheme swapped, `pios://<relay>/#pt=...`, which lands in
  the pairing sheet.

The device token goes to the Keychain (this device only, never synced).
Caches and the outbox live in Application Support, excluded from backup.

For local development against `pnpm sandbox --no-web`, use the printed
daemon URL (`http://<mac-ip>:4311`) and a link minted by the sandbox's own
`pios-server pair`; ATS allows local-network HTTP only.

## Tests

```sh
swift test --package-path apps/ios/PiOSCore      # macOS or Linux
```

Covers the supervisor ladder and blocking rules, outbox durability and
idempotent redelivery, leafId divergence, live/persisted dedupe, dialogs,
paging, the background policy, and replays every trace in `spikes/traces`
through the Swift assembler, as the TypeScript tests do.

End to end against the real daemon with the stub agent:

```sh
pnpm sandbox --no-web                            # prints ...&token=<device token>
swift run --package-path apps/ios/e2e pios-e2e <token>
```

It connects, lists, resyncs, prompts through the outbox, answers an
extension dialog, runs a `!` command, creates a session from a draft, and
reads models and stats. On Linux, swift-corelibs drops WebSocket frames over
16 KB, so use a fresh sandbox there; the app's transport is Apple's
`URLSession` and has no such limit.

Linux toolchain without root: `swiftly init --platform ubuntu24.04`. On Arch
the toolchain wants `libncurses.so.6` and `libxml2.so.2`; symlinking
`libncursesw.so.6` and `libxml2.so.16` into the toolchain's
`usr/lib/swift/linux` is enough to build and test.

## What maps to what

| Concern | TypeScript | Swift |
|---|---|---|
| Wire frames | `protocol/src/wire.ts` | `PiOSCore/Wire.swift` |
| Stream assembly | `protocol/src/assembler.ts` | `PiOSCore/Assembler.swift` |
| Single retry owner | `client-core/src/supervisor.ts` | `PiOSCore/Supervisor.swift` |
| Durable outbox | `client-core/src/outbox.ts` | `PiOSCore/Outbox.swift` |
| Cursor + cache | `client-core/src/session-store.ts` | `PiOSCore/SessionStore.swift` |
| Render model | `client-core/src/view.ts` | `PiOSCore/SessionView.swift` |
| Socket | `webSocketTransport` | `PiOS/Platform/WebSocketTransport.swift` |
| Lifecycle | `visibilitychange` | `scenePhase` -> `AppStatePolicy` |
| Online/offline | `online`/`offline` events | `NWPathMonitor` |

One deliberate difference: in the Swift view, persisted entries are never
collapsed into each other, only a live copy onto its entry. Two identical
replies without timestamps (the stub agent writes those) stay two rows.

## Scope

At parity with the PWA: pairing (paste, QR, `pios://`), multiple machines,
the session list (search, paging, unread marks, docked sidebar or drawer),
drafts, streaming chat with markdown, thinking, tool rows, diffs and images,
the outbox, steer and follow-up, `!`/`!!`, `/` and `@` completion, photos
from the library, camera or clipboard, extension dialogs and presentation,
banners, model and thinking pickers, session commands, rewind, stats, the
git view (changes, commit and amend, history, branches, stashes, fetch, pull,
push), the file browser and editor (etag saves, conflicts, drafts kept on
the device), the terminal (SwiftTerm on the daemon's PTY), plan usage, and
export to the share sheet.

Different by necessity:

- **Notifications** come from the daemon's per-device inbox, not APNs,
  which needs a paid developer account's entitlement that a free SideStore
  signature cannot carry. With the Settings toggle on, the app shows each
  settled turn as a local notification and acknowledges it: at once while
  the socket is up (including the half minute iOS grants after leaving the
  app), and otherwise on the next reconnect or background refresh, which iOS
  schedules when it sees fit. The PWA's web push remains the instant path.
- **The editor** is a plain monospaced text view: no syntax highlighting or
  line numbers, which CodeMirror gives the PWA.
