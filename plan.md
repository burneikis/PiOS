# PiOS - Implementation Plan

Derived from `spec.md`. Phases 0-5 were ordered by risk: validate protocol
assumptions first, UI last. From Phase 6 the order flips: the PWA is the
product, so features, design, and cleanup come before native apps or push.
Each phase ends with a concrete artifact that can be demoed or thrown away.

Repo layout target (pnpm workspace):

```
packages/
  protocol/      shared types, JSONL framing, event schemas (zod)
  pi-host/       owns pi sessions (AgentSession or subprocess RPC)
  server/        pios-server: WS multiplex, HTTP files, pairing, push
  relay/         Cloudflare Worker + Durable Object, the phone's only route in
  client-core/   connection supervisor, outbox, session store (platform-free)
apps/
  web/           PWA (React + Vite)
  mobile/        Expo RN app (added in Phase 10)
spikes/          throwaway validation scripts
```

---

## Phase 0 - Premise validation (spec 12) - DONE

Results: `docs/protocol-findings.md`. Fixtures: `spikes/traces/`.
Host decision: in-process `AgentSession` for v0, subprocess kept as fallback.

Goal: prove the RPC contract before writing anything reusable.

1. `spikes/rpc-probe.ts`: spawn `pi --mode rpc`, hand-rolled LF-only JSONL
   splitter (no `readline`, spec 8 gotcha 1), send a `prompt`, dump events.
2. Record a full event trace to `spikes/traces/*.jsonl` as fixture data for
   later tests.
3. Kill the client mid-stream, reconnect, `get_entries --since <lastId>`,
   diff against the recorded trace. Verify no gaps, no dupes, `leafId` matches.
4. Probe the gotchas explicitly: trust fallback behaviour (`defaultProjectTrust`
   / `--approve`), `streamingBehavior` requirement while streaming,
   `message_update` delta assembly, `agent_settled` vs `agent_end` ordering.
5. Same spike against in-process `AgentSession` from
   `@earendil-works/pi-coding-agent`. Decide which is v0 host.

Exit: written notes in `docs/protocol-findings.md` answering the above, and
fixtures checked in.

---

## Phase 1 - `packages/protocol` - DONE

Shipped: `jsonl.ts`, `messages.ts`, `events.ts`, `commands.ts`, `assembler.ts`,
`wire.ts`, `parse.ts`, 42 tests replaying the Phase 0 fixtures.
Correction to step 3 below: `toolcall_delta` carries no `toolCallId`, only
`contentIndex`, so argument buffers are keyed by index. See
`docs/protocol-findings.md`.

1. TypeScript types for every RPC request/response and event in scope
   (spec 8 table). Generate or hand-write, validated with zod.
2. `JsonlFramer`: byte-level LF splitting, max line guard, partial buffering.
   Unit tests including U+2028/U+2029 inside strings.
3. `MessageAssembler`: `message_start` + `contentIndex` deltas ->
   partial message; `message_end.message` overrides. `toolcall_delta` buffer
   keyed by `contentIndex`. Tested against Phase 0 fixtures.
4. PiOS-level wire protocol (client <-> server): envelope with `sessionId`,
   `commandId`, `messageId`; schema version field from day one.

Exit: `pnpm test` replays fixtures through the assembler and reproduces the
final transcript exactly.

---

## Phase 2 - `packages/pi-host` - DONE

Shipped: `PiSession` plus `InProcessSession` and `SubprocessSession` behind one
contract suite, `EventRingBuffer`, `SessionRegistry` with the crash policy,
and `test/driver.ts` for two concurrent sessions.

Two behaviours worth carrying forward:

- `AgentSession.prompt()` resolves when the **run** finishes, not when the
  prompt is accepted. The in-process host resolves on the `preflightResult`
  hook instead, so both hosts answer on delivery. Never await a prompt to
  completion on a request path.
- An unknown `since` becomes a reset page, not an error. Only the host knows
  the difference between a bad cursor and a broken session.

1. `PiSession` interface: `prompt`, `steer`, `followUp`, `getEntries(since)`,
   `interrupt`, `dispose`, plus an event emitter.
2. Two implementations: `InProcessSession` (AgentSession) and
   `SubprocessSession` (stdio RPC). Same tests run against both.
3. Per-session ring buffer of events keyed by entry id for replay to late or
   reconnecting clients.
4. Crash policy (spec Q2): detect exit, mark session `crashed`, auto-restart
   and resume from `~/.pi/agent/sessions/*.jsonl`, emit `session_recovered`.
5. Session registry: create/list/dispose, cwd + trust state per session.

Exit: unit tests plus a manual driver that runs 2 concurrent sessions.

---

## Phase 3 - `packages/server` (v0 daemon) - DONE

Shipped: `node:http` + `ws` daemon, pairing CLI, auth on every route, endpoint
advertisement, `CommandLedger` dedupe, file/upload routes with containment,
systemd user unit, and `test/smoke.sh` driving real pi end to end.

Correction to step 5: entries never come from the ring buffer. The buffer
holds *events*, including partials that were never persisted; entries come
from pi. Two cursors, two purposes: `leafId` to resync, `lastSeq` to tail.
Both now ride on `SessionSummary`.

1. HTTP + WS server (fastify or plain node:http + `ws`). Single WS multiplexes
   all sessions; subscribe/unsubscribe per session.
2. Pairing bootstrap (spec 3): `pios-server pair` prints URL + code, token
   delivered in URL **hash**, exchanged for a long-lived device token, stripped
   from history. Tokens stored hashed on disk.
3. Auth middleware on both HTTP and WS. Reject unauthenticated immediately.
4. Endpoint advertisement by **stable key** (`loopback:`, `lan:`, `tailscale-ip:`,
   `tailscale-magicdns:`), no unconditional loopback fallback. Superseded by
   Phase 7.8: one endpoint, the relay or the page's own origin.
5. Resume RPC: `get_entries(sessionId, since)` -> delta + `leafId`, served from
   pi (which owns the session JSONL); `subscribe(sinceSeq)` tails the ring
   buffer and reports a `gap` when the cursor was evicted.
6. Idempotent delivery: dedupe inbound prompts by `commandId`.
7. File/image HTTP: `GET /file?session=..&path=..` with cwd containment checks,
   `POST /upload` for phone-to-agent images.
8. Packaging: `systemd --user` unit + install script; tmux fallback documented
   but not required if the unit lands.

Exit: `curl` + `websocat` session can start a session, prompt, disconnect,
reconnect, and resync.

---

## Phase 4 - `packages/client-core` - DONE

Shipped: `ConnectionSupervisor`, `ThreadOutbox`, `SessionStore`,
`AppStatePolicy`, `webSocketTransport`, and `PiosClient` wiring them together.
47 fake-transport tests on an injected clock.

The outbox keeps a ladder separate from the supervisor's, so a client with a
healthy socket and a failing send retries without a reconnect. Both are capped
at 16s.

Platform-free, tested in Node.

1. **Connection supervisor** (spec 5): single retry owner, exponential backoff
   capped 16s, infinite retries, 30s stable resets the ladder, offline releases
   the lease with no timers, auth/config failure blocks until inputs change,
   `connected` only after socket open + initial config RPC succeeds.
2. Separate `transportHealth` from `syncStatus`. Never infer health from cache.
3. **Thread outbox** (spec 6): persisted schema-versioned queue, entries carry
   `messageId` + `commandId`, inline base64 images, own 16s-capped backoff,
   drains on reconnect. Pluggable storage adapter (localStorage / MMKV / fs).
4. **Session store**: entry-id cursor per session, delta application,
   `leafId` divergence detection -> full refetch.
5. Foreground/background policy hook: background >= 10s -> reconnect and reset
   ladder; < 10s -> probe.

Exit: fake-transport tests covering drop mid-stream, offline, auth failure,
outbox survival across restart, `leafId` divergence.

---

## Phase 5 - `apps/web` PWA (v0 UI) - DONE

Shipped: React + Vite PWA, pairing from the URL hash, endpoint picker probed
by `/health`, daemon-backed directory picker (new `GET /dirs`, rooted at the
home directory), chat view with streaming, thinking, tool cards, diffs, the
composer on the outbox, and the status banners.

Three corrections to the steps below:

- Trust is fixed at pi's launch flags, so the "trust this directory" action
  relaunches the child on the same session id (`set_session_trust`) instead of
  creating a second session. The transcript, subscribers, and cursors survive;
  clients see `session_recovered`.
- Cached entries and live events overlap after a resync, so `sessionView` in
  `client-core` collapses them on content and folds `toolResult` messages onto
  their tool card. The UI renders one list, not three sources.
- `@pios/protocol` no longer exports the JSONL framer from its index: it is
  Node-only and broke the browser bundle. It lives at `@pios/protocol/jsonl`.

1. Pairing screen (token from URL hash), machine list, endpoint picker.
2. Session list sidebar + create session (directory picker via daemon listing).
3. Chat view: streaming text, thinking blocks, tool-call cards correlated on
   `toolCallId`, diff rendering.
4. Composer: draft, edit, attach, send via outbox. Pending-queue rendering from
   `queue_update`. `streamingBehavior` selector (steer / follow-up) when the
   agent is busy.
5. Status banners: `compaction_start/end`, `auto_retry_start/end`,
   `extension_error` (surface, never swallow), trust state with a
   "trust this directory" action.

Exit: full v0 scope usable from a phone browser.

---

## Phase 6 - PWA feature completion - DONE

The PWA is the product until it stops being enough. Everything here lands in
`apps/web` + `client-core`; no native work, no push.

Shipped as listed. Three notes:

- `/name`, `/compact [instructions]` and `/autocompact [on|off]` are native
  commands, like `/model`: typed or picked, they never reach the model. A
  native command now takes the rest of the line as arguments. Later joined by
  `/thinking [level]`, `/copy`, `/session`, `/export [path]` (HTML only; the
  file is downloaded to the device when it lands in the project) and
  `/reload` (RPC has no reload, so the daemon relaunches pi in place and
  refuses while a turn, compaction or `!` command runs).
- A manual compaction is acked once pi starts it; progress and the outcome are
  the same `compaction_start`/`compaction_end` events an automatic one sends.
  The transcript keeps the full history and marks where the summary was cut.
- `abort_retry` needs no control of its own: pi's `abort` cancels a pending
  retry and a running compaction too, so the banners' Stop is `interrupt`.

1. Inline image rendering via the file HTTP endpoint.
2. Phone-to-agent images (base64 `ImageContent` on prompt/steer/follow_up):
   camera + photo library + paste, through the outbox.
3. Extension UI. Dialogs (`select` / `confirm` / `input` / `editor`) with a
   daemon-side deadline, pending-dialog state, and redelivery on subscribe;
   presentation (`notify` / `setStatus` / `setWidget` / `setTitle` /
   `set_editor_text`) as snapshotted session state. `custom()` stays a hard
   gap, documented in spec.md.
4. `@path` file picker backed by daemon fuzzy search (`GET /files`, git
   ls-files with a walk fallback, scoped to the session cwd). Matching has to
   live daemon-side: `addAutocompleteProvider` is a no-op in RPC mode, so an
   installed picker extension (pi-fzfp) cannot serve the client.
5. Slash commands with `/` autocomplete. Includes `/name` on
   `set_session_name`, which also feeds the session list (Phase 7, item 7).
6. Session controls: model switching, thinking level, compaction UI
   (`compact` + `set_auto_compaction`), interrupt affordance.
7. One-shot `bash`: run a single command in the session cwd, stream
   `bash_execution_update` deltas, render `BashResult` (exit code, truncation),
   `abort_bash` to cancel, per-command `excludeFromContext` toggle. Serialised
   one at a time per session, since `abort_bash` carries no id. Not the
   terminal tab: no PTY, no interactivity.
8. Session stats from `get_session_stats`, rendered at the foot of the
   transcript after agent output, behind a Settings toggle. Distinct from the
   plan-level `/usage` report, which stays.

---

## Phase 7 - PWA polish and design pass

Making it feel like an app rather than a page. Driven by real phone use, so
order inside this phase is expected to churn.

1. Design system pass over `ui.tsx` and the CSS utilities: spacing, type scale,
   colour tokens, dark mode, one source for rows/cards/scrollers.
2. Session list layout (spec 9). Mostly shipped: one component, docked at
   280px on wide screens and an overlay drawer with scrim and edge swipe below
   720px, with the chat kept mounted. Still open: a toggle for the docked
   column, the 320px width, the centred 760px transcript, and one shared
   progress value driving drawer position and backdrop blur.
   Target: one component, two presentations.
   - Wide: docked 320px column, list and transcript scroll independently,
     transcript capped around 760px and centred. No scrim, no blur. Selecting
     a session or starting a new one leaves it open; a menu button toggles it.
   - Narrow: overlay drawer over the chat, swipe and scrim, closes on select.
     Position and backdrop blur driven by one shared progress value.
   - Crossing the breakpoint re-presents only. Open session, transcript scroll,
     and composer draft stay mounted.
   - Not doing: pi-remote's pull-up-from-bottom new-chat gesture. Deliberate.
     The guard matrix (run state, tools, queue, offline, keyboard, draft,
     selection) costs more than the button it replaces.
3. Mobile ergonomics: safe areas, keyboard-aware composer, scroll anchoring on
   stream, pull-to-refresh vs resync, gesture navigation between sessions.
4. Transcript rendering quality: markdown, code blocks with syntax highlight,
   collapsible tool cards, better diffs, long-output truncation.
5. Performance: virtualised transcript, delta rendering cost, cold-start time,
   bundle size budget.
6. PWA shell: manifest, icons, install prompt, offline app-shell caching,
   standalone-mode routing.
7. Session list quality: naming, ordering, search, archive/delete, unread and
   busy indicators. Naming, search, unread and busy have shipped. Ordering is
   by the last prompt or shell command (`activeAt`), not mtime. Archive is
   open; delete stays out (spec: the TUI owns the transcript too).
8. Accessibility and error surfaces: focus order, contrast, every failure has a
   visible, actionable state. The event half has shipped: retries,
   summarisation retries, widgets, editor text and provider failures all
   render, and every retry or compaction banner has a Stop. Focus order and
   contrast are open.
9. Activity-lease reporting: 25s report, 45s TTL, carrying
   `visible` / `focused` / `appState` and warm scopes.

Exit: usable as a daily driver from the phone home screen.

---

## Phase 7.5 - File viewer and editor - DONE

Opening, reading and editing a file in the session directory, without asking
the agent to do it. Its own phase because it adds a write route and a
persisted structure, and both need their own exit criteria.

1. `packages/server/src/file-edit.ts`: `GET /file?text=1` (LF-normalised text,
   sha256 etag, eol + trailing-newline flags, refusal reason) and
   `PUT /file` guarded by `If-Match`. No `If-Match` means create and refuses to
   clobber. Caps: 1 MB, NUL in the first 8 KB, invalid UTF-8, 50k-char lines;
   over the cap degrades to a read-only head preview. Rename, delete and mkdir
   stay out: that is a file manager, and the agent is better at it.
2. `GET /dirs?session=..&files=1` roots the browse at the session cwd and
   includes files, minus the shared skip list. Search keeps `GET /files`, which
   is gitignore-aware; browsing is explicit intent and shows what git hides.
3. `apps/web`: a header file button opening a full-screen view (search on top,
   tree below when the query is empty), read mode by default, explicit Edit and
   Save, dirty dot, and a two-button conflict banner (Reload / Overwrite).
4. `code-editor.tsx`: lazily imported CodeMirror 6, soft wrap, line numbers,
   a fixed set of languages per extension, an accessory row (indent, outdent,
   undo, redo) above the keyboard. No find panel yet.
5. Unsaved buffers persist on the device only (IndexedDB, capped, dropped on
   save or on disposing the session); the open file lives in `sessionStorage`,
   so backgrounding keeps it and a real close forgets it.

Exit: `pnpm sandbox --scenario files` browses, reads, edits and saves; a file
rewritten underneath the buffer shows the conflict banner; oversized, binary
and minified files degrade to a preview. Covered by `packages/server/test/
file-edit.test.ts` and `packages/sandbox/test/files.test.ts`.

---

## Phase 7.6 - Session model: disk is the session - DONE

Sessions were live objects the daemon created and held; files on disk were a
separate "resumable" list behind a second picker. One session was two things
depending on an implementation detail the user could not see.

1. `SessionIndex` replaces `discovery.ts`: stat-only candidate pass, skim
   bounded by bytes, mtime+size caches, seed file for warm cold starts.
   Listing 1300 sessions went from 1.8s to 40ms cold, 20ms warm.
2. `transcript-file.ts`: transcripts read from the session JSONL, with tail
   paging (`limit`/`before`) beside the `since` delta.
3. Lazy processes: `sleep`/`wake` on the subprocess host, an idle sweep in the
   registry, `cold` as the resting status.
4. Wire v2: `list_sessions` paged and searched over the index,
   `list_resumable`, `dispose_session` and `create_session` deleted, `prompt`
   carrying `create`, `sessions_changed` nudge from a store watcher, trust
   stored per project directory.
5. Web: one session list with search and infinite scroll, drafts for sessions
   that do not exist yet, no delete affordance, cached list and transcript for
   an instant cold launch.

Follow-ups, also shipped:

- A subscription made while a session is cold attaches when any socket wakes
  it, not only the one that did, and gets the summary the startup announced
  before anyone could listen. Subscribing always returns the session's
  summary, so a session opened from outside the list page has one.
- Models and commands asked for before the socket is up are asked again once
  it is, for the sessions still on screen.
- A woken session is launched from its file without `--name` or `--model`,
  which would otherwise undo a rename or a model switch on every wake.
- File, search, tree and git routes resolve a cold session's directory from
  the index, and a draft's from the directory it names.
- The list is ordered by `activeAt`; a rename deep in a large file is read
  from the tail.
- A turn finished in the TUI is pushed from the session file once it is quiet.
- The stub pi writes pi's JSONL, so the sandbox lists, reads and resumes its
  sessions through the same index and reader as real ones.

---

## Phase 7.8 - Relay instead of Tailscale - DONE

The phone reaches the daemon only through a self-hosted Cloudflare relay; the
PWA stays a PWA. Design and threat model live in spec.md, section 3, Relay.
Setup steps: `packages/relay/README.md`.

Shipped:

- `packages/relay`: `codec.ts` (length-prefixed JSON header + binary
  payload, stream ids, 256 KiB chunks, text `ping`/`pong` only),
  `gate.ts` (enrollment and challenge as pure WebCrypto functions),
  `worker.ts` (Worker + one SQLite-backed Durable Object, hibernatable
  sockets, `503` + `x-pios-relay: host-offline`, close code 4503).
- `packages/server`: `RelayConnector` replays frames against the daemon's own
  loopback listener with `http.request` and `ws`; `RelayKey` in
  `~/.pios/relay-key.json`; `pios-server relay enroll|key`; `PIOS_RELAY_URL`
  replaces `PIOS_PUBLIC_URL`; default bind `127.0.0.1`, `PIOS_BIND` to
  override; the key-replaced alarm is a log line plus one push.
- `apps/web`: machine store v2 (one `url` per machine, v1 migrated), the
  endpoint picker replaced by a Machine row in Settings, a "Machine offline"
  banner for close reason `host offline`.

Two corrections to the original steps:

- The connector is tested against the real Worker under `wrangler dev`
  (`packages/server/test/relay.test.ts`), not a Node fake relay. A fake would
  have re-implemented the Durable Object and tested the copy.
- `PIOS_HOST` already selects the session host mode, so the bind address is
  `PIOS_BIND`.

Still open: the exit check on a real phone on cellular, which needs the
Cloudflare account.

---

## Phase 8 - Cleanup and hardening

Done so far: `discovery.ts` removed, git split into reads (`git.ts`) and
writes (`git-actions.ts`), `pnpm test:browser` as the browser smoke run, and
`docs/setup.md` for install, pairing, configuration, troubleshooting and the
sandbox workflow. Git moved from a floating chip and card over the
transcript to a header chip and a full-screen view beside the file editor:
changes, history, branches and stashes as tabs, every patch full width, stash
patches read with `stash show --include-untracked`.

1. Prune dead code and duplicated view logic surfaced by Phases 6-7.
2. Done: `cc-usage` absorbed. `usage.ts` calls `/api/oauth/usage` with pi's
   Anthropic login, refreshes under pi's `auth.json` lock, and shares the pi
   status bar's cache file and 429 backoff.
3. Test debt: the browser smoke run exists (`packages/sandbox/test/
   browser.smoke.ts`) and is where chat view behaviour gets pinned; no jsdom
   layer. Fixture-replay coverage for any new events stays the rule.
4. Daemon hardening review: auth, path containment, upload limits, token
   rotation.
5. Docs: install path, pairing, systemd unit, troubleshooting, and how an
   agent runs and tests the web app locally. Done: `docs/setup.md`.

---

## Phase 9 - Push + settle notifications

Web push shipped ahead of the phases above: `PushStore` (VAPID keys and
subscriptions, 0600, versioned), `SettleNotifier`, `/push/key`,
`/push/subscribe`, `/push/unsubscribe`, service-worker `push` and
`notificationclick` handlers, and a Settings toggle.

Two things worth carrying forward:

- iOS only exposes `PushManager` to a home-screen web app, and only asks for
  permission from a user gesture, so the toggle spells out `needs-install`
  rather than failing silently in a tab.
- Suppression needs attention, not a subscription: `activity` reports (25s,
  45s TTL on the daemon) now carry `visible` / `appState` / `sessionIds`, and
  a device watching the session is skipped.

1. `agent_settled` -> push. Web push for the PWA first; APNs later for native.
2. Device registration table in the daemon, per-device token. `revoke` drops
   the device's push subscriptions with its token.
3. Notification content: session name, last tool, elapsed.
4. Turns finished in the TUI are pushed too, read from the session file.
5. Native without APNs: a per-device inbox on the daemon (`set_notifications`,
   `notification`, `ack_notifications`), drained by the iOS app live, on
   reconnect, and on background refresh. Remaining: APNs for a paid-signed
   build, and richer content than one line.

---

## Phase 10 - `apps/mobile` (Expo)

Superseded on the `native-ios` branch by a native SwiftUI app in `apps/ios`
(see its README): `PiOSCore` ports `protocol` + `client-core` to Swift and is
tested against the same `spikes/traces` fixtures and a live sandbox daemon.
Open there: files, git and terminal views, APNs, Live Activity. The Expo
plan below is kept for reference.

Only worth starting once the PWA is a daily driver and web push has proven the
notification model.

1. Expo app reusing `client-core` verbatim; RN storage adapter for the outbox.
2. `AppState` wiring to the Phase 4 background policy.
3. Iterate on device through Expo Go / dev client over LAN, Metro served from
   the dev machine. No Mac, no build pipeline, real RN runtime and real
   backgrounding. Valid until the first custom native module.
4. Native builds run locally on a Mac (`eas build --local` or
   `npx expo run:ios`), both `xcodebuild` CLI, no Xcode GUI. Simulator via
   `xcrun simctl`. Cloud EAS is a fallback, not a dependency.
5. Distribution: sideload, then TestFlight via `eas submit` / `xcrun altool`.
6. APNs push.
7. Live Activity as a status surface driven by push only (not a liveness
   mechanism).

---

## Phase 11 - Later

- Raw terminal tab - DONE. Shipped: daemon-owned PTY (`node-pty`),
  `terminal_*` frames on the main socket with an offset cursor, xterm.js in
  the web app. Open: whether xterm.js holds up on iOS or `libghostty-vt` is
  needed.
- Branch browsing (`clone`, `get_fork_messages`, `get_tree`). Rewind-to-a-turn
  ships on `fork`; browsing the whole tree needs an RPC command to move the
  leaf, which pi does not expose.
- Editor extras deferred from Phase 7.5: find-in-file, a wider language set,
  and rename/delete once the header has room for them
- Lazygit
- Extension-authored panels: an extension publishes a declarative view tree
  (text/list/buttons/input/rows) on pi's event bus, the daemon validates and
  forwards without interpreting, the client owns styling and sends taps back.
  Only worth it if third-party extensions want UI we refuse to ship ourselves.
  Phase 6 item 3 already covers the half that pi emits natively.

## Unplanned
- macOS / Windows daemon (path-handling pass + launchd unit).

---

## Cross-cutting

- **Testing:** fixture-replay tests for the protocol layer; fake-transport
  tests for client-core; one end-to-end smoke test spawning a real daemon.
- **Schema versioning:** every persisted structure (outbox, session cache,
  device tokens) carries a version and a migration path.
- **Security:** daemon executes arbitrary code as the user. Auth required on
  every route, path containment on file serving, tokens hashed at rest,
  daemon bound to loopback, relay host slot held by an enrolled Ed25519 key.
  Secure Enclave keys only if SSH is ever added.
- **Non-goals guardrail:** no permission system, no pi reimplementation, no
  network management.

## Open questions to resolve during the phases

| Q | Resolve in |
|---|---|
| Two clients on one session simultaneously | **Yes.** Subscriptions fan out per session and every subscriber sees the same seq for the same event, so a late client replays and then tails. |
| pi process crash recovery | **Restart in place.** Same id, resumed from the session file, `session_recovered` with the new leaf; a crash loop stops after the budget. |
| Offline transcript caching on device | **Cached.** `SessionStore` persists entries per session, schema-versioned. Cached data renders while offline but never decides freshness: that is always `leafId` from the daemon. |
| Two agents writing one file | Document in Phase 3, no code |
| Terminal renderer cost | **xterm.js first**, lazy-loaded (~85 kB gzip). Renderer never crosses the wire, so a swap is client-only. |
