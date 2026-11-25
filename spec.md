# PiOS - Spec

An iOS client for [pi coding agent](https://pi.dev) running on a remote machine.

**Status:** design draft. Nothing built yet. Open questions marked with "Q:".

---

## 1. Problem

Running `pi` on a Linux box from a phone means SSH'ing in with a terminal app.
That is workable but bad in three ways:

1. **Keystroke-at-a-time input.** No draft, no edit, no review before send.
2. **Connection-coupled sessions.** If `pi` is a child of the SSH session, a
   dropped connection SIGHUPs the agent mid-task.
3. **No rich rendering.** Images are invisible. Tool calls, diffs, and
   extension dialogs are ANSI soup.

PiOS talks to pi's **RPC mode** instead of scraping a terminal.

---

## 2. Core insight

`pi --mode rpc` is a headless JSON protocol over stdin/stdout. It exposes
everything the TUI has: streaming assistant text, tool events, session state,
forking, and a translated **Extension UI Protocol**. PiOS is a native client
for that protocol, with a raw terminal as a secondary feature.

Two protocol features do most of the work:

- **`get_entries` with a `since` cursor.** The session is an append-only tree
  with stable entry ids, so an entry id is a durable cursor that survives
  client restarts. Reconnect means "give me everything after id X". The
  response includes `leafId`, so one round trip tells you if the branch moved.
- **The Extension UI Protocol.** Dialogs (`select`, `confirm`, `input`,
  `editor`) become request/response pairs rendered natively. Fire-and-forget
  methods (`notify`, `setStatus`, `setWidget`, `setTitle`, `set_editor_text`)
  can be rendered or ignored.

So backgrounding is a *sync* problem, not a *liveness* problem, and extension
UI is a *rendering* problem, not an *execution* problem.

---

## 3. Architecture

```
┌─────────────────┐         ┌──────────────────────────────────┐
│  iOS app / PWA  │◄──WS───►│  pios-server (on user's machine) │
│                 │         │                                  │
│  - chat UI      │  HTTP   │  - owns N pi sessions            │
│  - session list │◄───────►│  - multiplexes over one socket   │
│  - image render │  (files)│  - buffers events for replay     │
│  - terminal tab │         │  - serves files/images           │
└─────────────────┘         │  - fires push on agent_settled   │
                            └──────────────┬───────────────────┘
                                           │ AgentSession (in-process)
                                           │ or `pi --mode rpc` subprocess
                                           ▼
                                      pi agent loop
```

Both the WS and HTTP legs ride the relay (see Relay below).

### Why a daemon and not raw SSH from the phone

- RPC is stdio, one process per session. Multi-session needs something
  server-side to own N children and multiplex them.
- Session lifetime decouples from connection lifetime.
- A browser cannot SSH. The daemon is what makes the PWA possible.
- Image serving, file upload, and push become ordinary HTTP.
- Windows support becomes a path-handling pass, not a PTY rewrite.

### Implementation language

Node/TypeScript. Pi's docs recommend using `AgentSession` from
`@earendil-works/pi-coding-agent` directly rather than spawning subprocesses,
which skips the stdio layer. Subprocess RPC stays as fallback and reference.

### Bootstrap: pairing, not SSH

**Decision: no native SSH in v0.** T3's mobile app never SSHes; its
`SshConnectionTarget` is desktop-managed, and the phone only speaks
HTTP/WebSocket via direct pairing, relay, or Tailscale
([`docs/internals/remote.md`][t3-remote]).

Flow: user runs an install command on their machine, server prints a pairing
URL/code, phone pairs, WebSocket from then on, all through the relay below. T3 puts the token in the URL
**hash**, exchanges it with the backend, and strips it from history
(`packages/shared/src/remote.ts`).

No native modules needed, so Expo stays clean. SSH becomes a later
convenience, not a dependency.

### Relay

**Decision: the phone reaches the daemon only through a relay.** Tailscale
worked, but it needs a VPN app running on the phone. The relay is personal and
self-hosted: one Cloudflare Worker with a Durable Object per host, on
`*.workers.dev`. Reference shape: pi-remote.

```
phone ──HTTPS/WSS──► Worker ─► Durable Object ◄──WSS (outbound)── daemon connector
                                                                   │
                                                          127.0.0.1:4111 (unchanged server)
```

- **The daemon dials out.** A relay connector inside the daemon holds one
  outbound WebSocket to the Durable Object. Phone HTTP requests and phone
  WebSockets become framed streams (stream id, chunked, since Workers cap
  WebSocket message size) on that socket. The connector replays each one
  against the daemon's own `127.0.0.1` listener. The server, its routes, and
  its auth stay the single code path; the relay is a transport, not a second
  server.
- **The relay is trusted and sees plaintext.** TLS ends at Cloudflare. No
  end-to-end envelope: the PWA's JavaScript is served through the same relay,
  so a malicious relay could ship JS that leaks keys anyway, and an envelope
  would force every HTTP route through a custom encrypted tunnel. The relay
  forwards but never authorizes: device tokens are still checked by the
  daemon, which trusts nothing about loopback.
- **The PWA is proxied from the daemon**, like any other route. App and daemon
  versions never skew, and there is no second deploy. When the host is
  offline, the service worker's cached shell still opens.
- **Host offline is transient, not an error.** The relay answers `503` with
  `x-pios-relay: host-offline` and closes phone sockets with a dedicated close
  code. The supervisor backs off as for a network drop, distinct from a `401`,
  which blocks.
- **One host per Worker for now.** The Durable Object is keyed by host id, so
  several machines later is a routing change, not a rewrite.
- **No relay-side gating of phone traffic.** `/pair` and every route are
  reachable from the internet, protected by the daemon's auth (256-bit
  single-use pairing tokens, hashed device tokens). The relay only bounds
  what an unauthenticated caller can hold, per `cf-connecting-ip`: pending
  host handshakes (2, expiring after 10 s), phone sockets (16), in-flight
  requests (64), and request bodies (32 MiB). Per address, so one flooder
  cannot crowd out the real daemon or phone.
- **Frames are validated on decode**, on both ends. Paths must be
  origin-relative ASCII, and headers Node would refuse are dropped, so no
  frame a stranger can cause makes the connector throw.
- **The daemon binds `127.0.0.1` by default.** The relay is the only remote
  path, so LAN exposure buys nothing. `PIOS_BIND` opts back in (`PIOS_HOST`
  already names the session host mode).
- Frames carry a protocol version in the host handshake; a mismatch is a
  clear rejection, not garbled streams.

### Relay host identity

Whoever holds the host slot receives every phone request, device tokens
included, and could replay them to the real daemon. A static shared secret is
therefore too weak.

- The Worker has an `ENROLL_SECRET` (`wrangler secret`), used once. On first
  connect the daemon presents it plus an Ed25519 public key; the private key
  stays in `~/.pios/relay-key.json` (0600). The Durable Object stores the
  public key and the hash of the secret that enrolled it, in a versioned
  record. A record the running version cannot read locks the slot rather
  than counting as absent, which would reopen the spent secret; a new record
  version ships with a migration.
- After that the secret is dead. Every host connection is challenge-response:
  the Durable Object sends a nonce, the daemon signs it.
- **A new host requires a new secret.** Rotating `ENROLL_SECRET` reopens
  enrollment because its hash no longer matches, and enrolling replaces the
  stored key. There is no other way in.
- The same key reconnecting (daemon restart) replaces a stale socket. A
  different key is rejected, even while the slot is empty.
- If the relay rejects the daemon's key, someone re-enrolled. The daemon logs
  it loudly and pushes a "relay host key replaced" notification, so a takeover
  is visible even when it was not you.

### Endpoints

A machine has one endpoint: the relay URL, or the page's own origin for local
dev and the sandbox. LAN and Tailscale discovery are gone. An HTTPS PWA cannot
call `http://` addresses anyway (mixed content), and a second live path would
double the reconnect logic for little gain.

- No unconditional loopback fallback.
- The endpoint is still persisted by **stable key**, not raw URL, and only a
  successful connection proves it reachable.
- Moving origin means fresh storage on the phone: devices re-pair and
  re-subscribe to push. Web Push itself is unaffected; the daemon sends
  straight to the push service, never through the relay.

---

## 4. Backgrounding

**Position:** the agent loop must survive independent of the phone. Whether
iOS holds the socket open is polish, not correctness.

Server-side durability, in preference order:

1. Daemon owns the `pi` sessions and is a systemd user unit / launchd agent.
2. `tmux new-session -d -s pios-<id>` as a simpler v0.
3. Sessions auto-save to `~/.pi/agent/sessions/` as JSONL, so state survives a
   daemon crash.

Client reconnect: on foreground, send `get_entries` with the last seen entry
id, apply the delta, compare `leafId`.

Prior art settles this. T3 Code does not attempt background socket survival at
all. [`apps/mobile/src/connection/app-state-wakeups.ts`][t3-wakeups] is 15
lines:

```ts
export const MOBILE_BACKGROUND_RECONNECT_AFTER_MS = 10_000;
// backgrounded >= 10s -> "application-active-reconnect"
// backgrounded  < 10s -> "application-active-probe"
```

Under 10 seconds they probe the existing session. Over it, they replace the
lease outright: [`docs/internals/connection-runtime.md`][t3-conn] says
`application-active-reconnect` interrupts establishment and resets the retry
ladder "because the OS may have silently killed the socket underneath the
attempt."

Design for reconnect, not for liveness.

Q: Termius appears to hold interactive SSH sessions alive longer than this.
Mechanism unconfirmed. Live Activities are rendered out-of-process and do not
grant background execution. Possibly relevant to the terminal tab, not worth
chasing for v0.

**Live Activity** is still worth building as a status surface
("Session 2: running tests, 4m") driven by push, not as a liveness mechanism.

---

## 5. Connection supervisor

Rules adapted from [`packages/client-runtime/src/connection/supervisor.ts`][t3-sup]
and the connection-runtime doc.

- **One retry owner.** React components never create connections, transports,
  retry loops, or RPC clients.
- **Backoff** exponential, capped at 16s, retries forever. 30s of stable
  connection resets the ladder.
- **Ignore plain foreground activation during an in-flight attempt.** Only a
  background suspension of 10s or more interrupts.
- **Offline** releases the session and waits for a signal: no retries
  consumed, no timer running.
- **Auth/config failures block permanently** until an input changes.
- **Never infer health from cached data.** An environment is `connected` only
  after the socket opens and an initial config RPC succeeds.
- **Transport health and sync status are separate.** A healthy socket with a
  failed subscription is "connected, sync error", not a fake reconnect.

---

## 6. Thread outbox

Prompts are queued durably, not fired at a live socket. Modelled on
[`apps/mobile/src/state/thread-outbox-model.ts`][t3-outbox] and
[`use-thread-outbox-drain.ts`][t3-drain].

- Persisted, schema-versioned queue of composed messages
- Each entry carries `messageId` + `commandId` for idempotent delivery
- Image attachments inline in the queued entry
- Own retry backoff, also capped at 16s
- Survives app restart, drains on reconnect

This is what makes compose-and-send work on a phone: write a prompt on the
tube, it sends when signal returns. Without it, "nicer typing UX" is just an
input box.

---

## 7. Scope

### v0

- Connect to a machine, pick a directory, start a pi session
- Compose-then-send prompts via the durable outbox (section 6)
- Render streaming assistant text, tool calls, diffs
- Sessions survive backgrounding; resync on foreground via `get_entries --since`
- Multi-session sidebar
- Push notification on `agent_settled`

### v1

- Inline image rendering (agent reads a `.png`, fetch, display)
- Send images from phone to agent
- Activity-lease reporting so the server knows what to keep warm
- Extension UI dialogs rendered natively
- `@path` file picker via SFTP/daemon listing

### Later

- macOS / Windows daemon support
- Branch browsing (`clone`, `get_fork_messages`, `get_tree`)

### Non-goals

- Reimplementing pi. PiOS is a view onto pi, not a fork.
- A permission/approval system. Pi has none by design; users who want gating
  install an extension and PiOS renders its dialogs.
- Managing the user's network security.
- Being a plugin inside another harness GUI. T3 Code is reference
  architecture, not a host.

---

## 8. Protocol notes

### The session model

**A session is a file in pi's session store.** Its id is the one in the JSONL
header, so it outlives any process, and the store is shared with the TUI: a
conversation started there and one started here are the same kind of thing and
appear in the same list.

A `pi --mode rpc` process is a cache in front of that file, nothing more.

- **Lazy.** Nothing spawns to list a session or to read one. The first prompt
  is what starts a session: a composer with no prompt sent is a draft, holding
  a client-minted id, and the prompt that creates the session takes that id.
- **Reaped.** A process idle for 30 minutes is stopped and the session goes
  `cold`, which is its normal resting state. Only prompts and agent events
  refresh the idle clock; a client polling for models or stats cannot pin a
  process open. A session that is streaming, or blocked on a dialog, is never
  reaped.
- **Woken by use.** Any command that needs the agent starts it again, under the
  same id, and announces it with `session_recovered` carrying the leaf the new
  process loaded. Ring-buffer `seq` is only meaningful within one process; the
  durable cursor is always `leafId`.
- **Read from disk.** pi persists an entry before it announces it, so
  `get_entries` is a file read: `since` for a delta, `limit`/`before` for tail
  paging. A live process only adds partials on top. Entry id is the dedupe key
  and the persisted copy wins over the streamed one.
- **Listed from disk.** `list_sessions` reads the head of each file for id,
  cwd and preview, and the tail for the last prompt and the latest name,
  cached on mtime+size and seeded from a file so a restarted daemon answers
  instantly. Search matches path, name and preview, never whole transcripts.
- **Ordered by the user, not the agent.** The list sorts on the last prompt or
  shell command (`activeAt`), not on mtime: an unattended run keeps writing
  and would otherwise bury the conversation that was just open. `activeAt` is
  never later than mtime, so a walk in mtime order stops as soon as nothing
  further down can make the page.
- **Files without a process.** File, search, tree and git routes resolve a
  session's directory from the index as well as the registry, so a cold
  session shows its images and git state without waking pi. A draft, which
  has no session yet, names its directory instead, contained to home.
- **Turns that ran elsewhere.** A turn the TUI finishes never reaches this
  daemon's event stream. The store watcher passes the written files on, and a
  file that goes quiet with a finished assistant message as its last entry is
  pushed like a local `agent_settled`. A failure waits longer, because pi
  retries it after a delay.
- **Trust is a directory's, not a session's.** It is a launch flag, and launches
  now happen whenever a session is woken, so asking per session would ask the
  same question forever.

There is no delete: removing a row would mean deleting a transcript the TUI
also owns.

### Sending prompts

`prompt`, `steer`, and `follow_up` accept an optional `images` array of base64
`ImageContent` blocks, so phone-to-agent image upload is native.

While the agent is streaming, `prompt` **must** specify `streamingBehavior`
(`"steer"` or `"followUp"`) or it errors. `queue_update` events report pending
queue contents.

### Events worth wiring

| Event | Use |
|---|---|
| `message_update` | Stream assistant text/thinking into the bubble |
| `tool_execution_start/update/end` | Tool call cards; correlate on `toolCallId` |
| `agent_settled` | Push notification trigger |
| `queue_update` | Render pending steering/follow-up |
| `compaction_start/end` | Context-compaction indicator |
| `auto_retry_start/end` | "Retrying, provider overloaded" banner |
| `extension_error` | Surface, do not swallow |
| `summarization_retry_*` | Same class as `auto_retry`; surface, do not swallow |

Use `agent_settled`, not `agent_end`; `agent_end` may be followed by retry,
compaction, or queued continuations.

### Extension UI

Render `select`/`confirm`/`input`/`editor` as native sheets; reply with
`extension_ui_response` and the matching `id`.

A dialog carries a `timeout` only when the extension asked for one, and pi
arms no timer otherwise, so an unanswered dialog blocks the agent forever.
The daemon therefore caps every dialog itself and cancels on expiry: a session
must never be wedgeable by an extension the client cannot render. A pending
dialog is session state, not connection state, so it survives reconnects and is
delivered to whichever clients are attached; the first answer wins and a
duplicate id is a no-op.

The other half of the protocol is presentation, not questions: `setStatus` and
`setWidget` replace by key, `setTitle` and `set_editor_text` replace outright,
`notify` is a one-shot message. Those four are last-value-wins session state,
held by the daemon and snapshotted on subscribe, because a client that
reconnects needs the current status line rather than the history of how it got
there. `notify` is deliberately not state: replaying it would announce
something that already happened. Both the daemon and the client fold requests
with the same reducer, so neither can drift.

The daemon tolerates non-JSON noise on the RPC stream. Extensions share pi's
stdout and write terminal control bytes without a newline, so a bell would
otherwise arrive glued to the front of the next record and destroy it.

Degraded in RPC mode (already stubbed): `custom()` returns undefined;
`setWorkingMessage`, `setFooter`, `setHeader`, `setEditorComponent`,
`setToolsExpanded` are no-ops; `getTheme`/`setTheme` unavailable. `setWidget`
accepts string arrays only.

`custom()` is the only genuine gap in the dialog/presentation half. Extensions
using it are invisible in RPC mode regardless of what PiOS does.

The other gap is input, not output: `addAutocompleteProvider` and
`setEditorComponent` are no-ops in RPC mode, so an extension that replaces `@`
file completion (pi-fzfp, for example) loads and runs its hooks but its
provider is dropped. PiOS therefore implements fuzzy file search daemon-side
rather than borrowing the user's extension. The editor half is inherently
TUI-shaped and can never cross RPC; the provider half could, since
`AutocompleteItem` is plain data, and is worth raising upstream as an RPC
command that runs registered providers and returns their items.

### Unreachable commands

The daemon exposes an allowlist, not a passthrough, so a pi command is only
reachable once it has a route. Deliberately unrouted today, with the reason:

| Command | Why not |
|---|---|
| `cycle_model`, `cycle_thinking_level` | pickers set values explicitly; cycling is a TUI ergonomic |
| `set_steering_mode`, `set_follow_up_mode` | the composer picks per message instead |
| `clear_queue` | queue is rendered but rarely needs a bulk drop |
| `get_messages`, `get_last_assistant_text` | superseded by `get_entries` |
| `export_html` | no phone use |
| (none for bash) | `bash` / `abort_bash` are routed for one-shot commands; see below |
| `clone`, `get_fork_messages`, `get_tree` | branch browsing needs an RPC command to move the leaf, which pi does not expose |

### Gotchas

1. **Framing.** Strict LF-only JSONL. Node `readline` is explicitly
   non-compliant (it splits on U+2028/U+2029, valid inside JSON strings).
   Hand-roll the splitter.
2. **Trust.** RPC mode shows no trust prompt and falls back to
   `defaultProjectTrust`, which defaults to `ask`, and in non-interactive mode
   `ask` behaves like `never`. Project-local extensions, settings, and packages
   silently do not load. Surface trust state in the UI and offer to trust the
   directory (or pass `--approve`).
3. **Streaming assembly.** `message_update` deltas carry no cumulative
   snapshot. Assemble partials from `message_start` + `contentIndex`; treat
   `message_end.message` as authoritative. Buffer `toolcall_delta` for args.
4. **Bash is not a terminal.** The RPC `bash` command adds output to
   conversation context and only reaches the LLM on the next prompt. The
   terminal tab is a separate shell channel (`terminal_*` frames), never
   routed through pi.

### One-shot bash

PiOS routes `bash` for single commands only: check a build, read a log, run a
test, from the phone without spending a turn. It is not the terminal tab, and
the distinction is load-bearing because the two differ in kind.

- No PTY, so no interactivity. Anything that expects a TTY, prompts for input,
  or paints a full-screen UI hangs until `abort_bash`. The client makes the
  one-shot shape obvious rather than pretending to be a shell.
- Output is conversation state by default. `excludeFromContext` keeps a
  command out of the transcript, and the client chooses per command: a command
  the user ran to inform themselves should not silently become context the
  agent then reasons about.
- `bash_execution_update` streams output deltas keyed by the command `id`;
  `BashResult` closes it with `exitCode`, `cancelled`, `truncated`, and
  optionally `fullOutputPath` for output past the truncation threshold, which
  the file route can serve.
- An extension can intercept via `user_bash` and return its own result, so the
  client must not assume the command actually ran as written.
- One command at a time per session: `abort_bash` takes no id, so a second
  concurrent command makes cancellation ambiguous. The daemon serialises.
- Same trust and containment rules as everything else. This runs arbitrary
  code as the user, and the auth boundary is the only boundary there is.

### Terminal

The interactive shell does not go through pi at all. The daemon owns PTYs
(`node-pty`), keyed by a client-chosen id (the web app uses the session id),
and streams them over the same authenticated socket as everything else, so
there is still one retry owner and no second auth path.

- **Daemon-owned, not socket-owned.** Leaving the screen, a dropped socket or
  an app reload detaches; the shell keeps running until it exits or is
  closed. Several devices can attach at once; the last resize wins.
- **Offset cursor.** Output is kept as a bounded scrollback with a running
  offset. `terminal_open` carries `since: {instance, offset}`, and the
  daemon replays from there or, if that is not continuous with what it holds,
  replies `reset` and replays everything it has. `instance` changes when the
  shell is replaced, so an offset never addresses the wrong shell. A gap in
  live output makes the client re-attach from its own offset.
- **Input is never queued.** Keystrokes replayed after a reconnect would land
  in whatever the shell is doing by then. Offline keys are dropped and the
  screen says so.
- **Exit leaves the screen.** A shell ending, by `exit` or by a close from
  any device, takes every attached client back to the chat. A reconnect
  holding a cursor into an exited shell still learns how it ended; any other
  open of that id starts a new shell.
- **Backpressure.** A socket behind on output pauses the PTY, so a runaway
  `yes` blocks on the PTY instead of filling daemon memory.
- A cap on live shells, since each is a process the phone may forget about.
- **Forgotten shells are visible and reaped.** The daemon pushes the set of
  running shells (`terminals`) after `welcome` and on every change, and the
  session list marks rows that have one. A shell with no device attached for
  `PIOS_TERMINAL_IDLE_MINUTES` (default 12 h) is closed.

---

## 9. Client platform

- **Avoid Xcode, avoid the cloud.** React Native / Expo. T3's mobile app is
  React Native, shipping on both stores. Cloud EAS Build is deliberately not a
  dependency: device iteration happens through Expo Go / a dev client over LAN,
  and native builds run locally on a Mac through the `xcodebuild` CLI
  (`eas build --local`, `npx expo run:ios`, `xcrun simctl`), never the GUI.
- With pairing instead of SSH bootstrap, v0 needs no native modules, so the
  dev-client path holds until APNs, Live Activity, or Secure Enclave keys land.
- **Terminal tab: xterm.js first.** T3 abandoned xterm.js: web runs a
  WebAssembly build of `libghostty-vt`, Android links the native library
  ([`docs/architecture/terminal-renderers.md`][t3-term]). PTYs stay
  server-owned (`node-pty` in the daemon); renderer choice never crosses the
  wire, which carries text output tagged with an offset into the shell's
  output. The web app uses xterm.js, lazy-loaded; swapping it for
  `libghostty-vt` later is a client-only change.
- **Layout: one list, two presentations.** Wide viewports keep the session
  list docked beside the chat; narrow ones show it as an overlay over the
  chat. Crossing the breakpoint changes presentation only: the open session,
  its scroll position, and the composer draft stay mounted, so a rotation or
  a resize is never a navigation event. Chat text gets a reading-width cap
  independent of the window, because a docked list plus a full-bleed
  transcript is unreadable on a desktop.
- **PWA first** validates the daemon protocol, chat UI, session sidebar, and
  image rendering with fast iteration. It cannot validate backgrounding, but
  since the daemon owns the sessions, that is fine.
- **Distribution:** sideload, TestFlight, App Store if it is good. App Store
  review has opinions about remote code execution and background modes; check
  before depending on either.

---

## 10. Keys / auth

- Prefer generating an Ed25519 key in the Secure Enclave and having the user
  paste the public key into `authorized_keys`, rather than importing an
  existing private key.
- Daemon needs its own auth (a token minted during bootstrap). SSH's auth
  model does not come along for free over WebSocket, and the daemon can
  execute arbitrary code as the user.
- The daemon's relay identity is a separate Ed25519 key, enrolled once per
  enrollment secret (section 3, Relay host identity).

---

## 11. Open questions

- Q: Can two clients attach to one session simultaneously (phone + laptop)?
- Q: How does the daemon handle a `pi` process crash: auto-restart and resume
  from session file?
- Q: Does the phone cache transcripts for offline reading, or always read
  through the daemon?
- Q: Multi-session in one repo is allowed by pi's model, but what happens when
  two agents write the same file? Probably just document it.
- Q: Terminal tab renderer: xterm.js is the shipped cut. Whether it holds up
  on iOS (selection, IME, long scrollback) decides if `libghostty-vt` is worth
  the WebAssembly build.

---

## 12. First thing to build

A ~100-line Node script that spawns `pi --mode rpc`, sends a prompt, prints the
event stream, then reconnects with `get_entries --since` and verifies the delta
is correct. That validates the premise of this document before any UI exists.

---

## References

- pi RPC docs: https://pi.dev/docs/latest/rpc
- pi repo: https://github.com/earendil-works/pi
- ACP discussion (prior art on headless extension behaviour):
  https://github.com/earendil-works/pi/discussions/4444
- Termius: closed source, reference for SSH UX

### T3 Code (`pingdotgg/t3code`, MIT, @ `30be311`)

Closest prior art: RN mobile app + Node WebSocket server wrapping agent CLIs
over JSON-RPC stdio. Same shape as PiOS, different agent.

[t3-wakeups]: https://github.com/pingdotgg/t3code/blob/main/apps/mobile/src/connection/app-state-wakeups.ts
[t3-conn]: https://github.com/pingdotgg/t3code/blob/main/docs/internals/connection-runtime.md
[t3-sup]: https://github.com/pingdotgg/t3code/blob/main/packages/client-runtime/src/connection/supervisor.ts
[t3-outbox]: https://github.com/pingdotgg/t3code/blob/main/apps/mobile/src/state/thread-outbox-model.ts
[t3-drain]: https://github.com/pingdotgg/t3code/blob/main/apps/mobile/src/state/use-thread-outbox-drain.ts
[t3-remote]: https://github.com/pingdotgg/t3code/blob/main/docs/internals/remote.md
[t3-term]: https://github.com/pingdotgg/t3code/blob/main/docs/architecture/terminal-renderers.md
[t3-bg]: https://github.com/pingdotgg/t3code/blob/main/apps/mobile/src/connection/background-activity.ts

Also relevant: `apps/mobile/src/features/agent-awareness/` (push when an agent
finishes or asks a question) and [`background-activity.ts`][t3-bg]: a 25s
activity report with a 45s TTL lease carrying `visible`/`focused`/`appState`
and background scopes the client wants kept warm.
