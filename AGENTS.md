# AGENTS.md

iOS/PWA client for the `pi` coding agent over its RPC mode.

- `spec.md` - design, rationale, open questions. Source of truth for *why*.
- `plan.md` - phased implementation order. Source of truth for *next*.

Do not duplicate either file here.

## Commands

```
pnpm install
pnpm test
pnpm -F <pkg> dev
pnpm sandbox                  # live app + fake agent, prints a URL that pairs itself
pnpm sandbox:shot --tap api   # phone-sized screenshots into .sandbox/shots
swift test --package-path apps/ios/PiOSCore   # Swift core of the iOS app
```

UI work goes through the sandbox (`packages/sandbox/README.md`): real daemon,
stubbed pi, scenarios as data, temp dirs only. Never test the UI against a
real agent or a real repository.

## Invariants

These are expensive to get wrong; everything else is negotiable.

- **LF-only JSONL framing.** Never `readline` on the RPC stream: it splits on
  U+2028/U+2029, which are legal inside JSON strings.
- **`agent_settled`, not `agent_end`.** `agent_end` can be followed by retry,
  compaction, or queued continuations.
- **Entry id is the cursor.** Resync is `get_entries --since <id>`; compare
  `leafId` to detect a moved branch. Never infer state from cached data.
- **One retry owner.** UI code never opens sockets, transports, or retry loops.
- **Prompts go through the outbox.** Never write to a live socket from the UI.
  Every queued entry carries `messageId` + `commandId` for idempotent delivery.
- **`streamingBehavior` is mandatory** on `prompt` while the agent streams.
- **Persisted structures are versioned** with a migration path.
- **The daemon runs arbitrary code as the user.** Auth on every route, path
  containment on file serving, tokens hashed at rest.

## Non-goals

No pi reimplementation, no permission/approval layer, no network management.

## Conventions

- TypeScript, pnpm workspace. Shared logic is platform-free so web and native
  reuse it unchanged.
- Protocol changes ship with a fixture-replay test.
- The web UI composes the primitives in `apps/web/src/components/ui.tsx` and
  the `.line`/`.scroll-y`/`.list-row` CSS utilities; no ad-hoc row, card, or
  scroll-container styling.
- Comments are short and explain *why*. No restating the code, no changelogs,
  no section numbers, no references to `spec.md` or `plan.md` from source.
  Code must read standalone; docs move, code stays.
- No git write actions unless asked.
