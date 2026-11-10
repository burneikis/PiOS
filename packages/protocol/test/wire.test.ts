import { test } from "node:test";
import assert from "node:assert/strict";
import { ClientFrameSchema, ServerFrameSchema, WIRE_VERSION, isWireVersionMismatch } from "../src/wire.ts";
import { RpcCommandSchema, isUnknownCursorError } from "../src/commands.ts";
import { parseWith } from "../src/parse.ts";
import { AgentEventSchema } from "../src/events.ts";

test("a prompt frame requires an idempotency key and a message id", () => {
  const ok = ClientFrameSchema.safeParse({
    v: WIRE_VERSION,
    type: "prompt",
    commandId: "c1",
    sessionId: "s1",
    messageId: "m1",
    text: "hi",
  });
  assert.ok(ok.success);
  assert.deepEqual(ok.data.type === "prompt" ? ok.data.images : null, []);

  const missing = ClientFrameSchema.safeParse({
    v: WIRE_VERSION,
    type: "prompt",
    sessionId: "s1",
    messageId: "m1",
    text: "hi",
  });
  assert.equal(missing.success, false);
});

test("a frame from another schema version is rejected, not coerced", () => {
  const frame = { v: WIRE_VERSION + 1, type: "hello", commandId: "c1" };
  assert.ok(isWireVersionMismatch(frame));
  assert.equal(ClientFrameSchema.safeParse(frame).success, false);
});

test("entries frames carry leafId and a reset flag", () => {
  const parsed = ServerFrameSchema.parse({
    v: WIRE_VERSION,
    type: "entries",
    sessionId: "s1",
    entries: [{ id: "e1", type: "message" }],
    leafId: "e1",
  });
  assert.equal(parsed.type === "entries" && parsed.reset, false);

  const nullLeaf = ServerFrameSchema.safeParse({
    v: WIRE_VERSION,
    type: "entries",
    sessionId: "s1",
    entries: [],
    leafId: null,
  });
  assert.ok(nullLeaf.success, "an empty session has a null leafId");
});

test("streamingBehavior is optional on the wire but constrained", () => {
  assert.ok(RpcCommandSchema.safeParse({ type: "prompt", message: "x" }).success);
  assert.ok(
    RpcCommandSchema.safeParse({ type: "prompt", message: "x", streamingBehavior: "steer" }).success,
  );
  assert.equal(
    RpcCommandSchema.safeParse({ type: "prompt", message: "x", streamingBehavior: "queue" }).success,
    false,
  );
});

test("an unknown cursor is identified from the failed response", () => {
  assert.ok(
    isUnknownCursorError({
      type: "response",
      command: "get_entries",
      success: false,
      error: "Entry not found: abc",
    }),
  );
  assert.equal(
    isUnknownCursorError({ type: "response", command: "get_entries", success: true }),
    false,
  );
});

test("an unrecognised event reports unknown_shape instead of throwing", () => {
  const result = parseWith(AgentEventSchema, '{"type":"telepathy_start"}');
  assert.equal(result.ok, false);
  assert.equal(result.ok === false && result.reason, "unknown_shape");
});

test("unknown fields on a known event survive validation", () => {
  const result = parseWith(
    AgentEventSchema,
    '{"type":"agent_settled","futureField":{"nested":true}}',
  );
  assert.ok(result.ok);
  assert.deepEqual((result.value as Record<string, unknown>).futureField, { nested: true });
});

test("a bash frame defaults to keeping its output in context", () => {
  const parsed = ClientFrameSchema.parse({
    v: WIRE_VERSION,
    type: "run_bash",
    commandId: "c1",
    sessionId: "s1",
    command: "pnpm test",
  });
  assert.equal(parsed.type === "run_bash" && parsed.excludeFromContext, false);

  const result = ServerFrameSchema.parse({
    v: WIRE_VERSION,
    type: "bash_state",
    sessionId: "s1",
    command: "pnpm test",
    running: false,
    result: { output: "ok\n", exitCode: 0 },
  });
  assert.equal(result.type === "bash_state" && result.result?.cancelled, false);
});

test("a prompt can carry what it takes to create the session it addresses", () => {
  const parsed = ClientFrameSchema.parse({
    v: WIRE_VERSION,
    type: "prompt",
    commandId: "c1",
    sessionId: "draft-1",
    create: { cwd: "/tmp/project" },
    messageId: "m1",
    text: "hi",
  });
  assert.ok(parsed.type === "prompt");
  // Trust is never inherited: an unspecified session is untrusted.
  assert.deepEqual(parsed.create, { cwd: "/tmp/project", trustProject: false });
});

test("the session list is paged and searched by the daemon", () => {
  const asked = ClientFrameSchema.parse({
    v: WIRE_VERSION,
    type: "list_sessions",
    commandId: "c1",
    query: "refactor",
    limit: 20,
    offset: 40,
  });
  assert.ok(asked.type === "list_sessions" && asked.offset === 40);

  const page = ServerFrameSchema.parse({
    v: WIRE_VERSION,
    type: "sessions",
    sessions: [
      { sessionId: "s1", cwd: "/tmp", status: "cold", updatedAt: 1 },
    ],
    offset: 40,
    total: 97,
    hasMore: true,
  });
  assert.ok(page.type === "sessions");
  // A cold row is mostly absences: no process, so no cursor and no seq.
  assert.deepEqual(page.sessions[0]?.leafId, null);
  assert.equal(page.sessions[0]?.lastSeq, 0);
  assert.equal(page.sessions[0]?.trusted, false);
});

test("entries can be asked for as a tail and paged backwards", () => {
  const asked = ClientFrameSchema.parse({
    v: WIRE_VERSION,
    type: "get_entries",
    commandId: "c1",
    sessionId: "s1",
    limit: 200,
    before: 400,
  });
  assert.ok(asked.type === "get_entries" && asked.before === 400);

  const page = ServerFrameSchema.parse({
    v: WIRE_VERSION,
    type: "entries",
    sessionId: "s1",
    entries: [],
    leafId: null,
    offset: 200,
    total: 600,
  });
  assert.ok(page.type === "entries" && page.offset === 200 && page.total === 600);
});

test("renaming refuses an empty name rather than clearing it", () => {
  const frame = { v: WIRE_VERSION, commandId: "c1", type: "set_session_name", sessionId: "s1" };
  const ok = ClientFrameSchema.safeParse({ ...frame, name: "  release notes " });
  assert.ok(ok.success);
  assert.equal(ok.data.type === "set_session_name" ? ok.data.name : null, "release notes");
  assert.equal(ClientFrameSchema.safeParse({ ...frame, name: "   " }).success, false);
});

test("compaction takes optional instructions and a separate auto toggle", () => {
  const base = { v: WIRE_VERSION, commandId: "c1", sessionId: "s1" };
  assert.ok(ClientFrameSchema.safeParse({ ...base, type: "compact" }).success);
  assert.ok(
    ClientFrameSchema.safeParse({ ...base, type: "compact", customInstructions: "keep the API" }).success,
  );
  assert.ok(ClientFrameSchema.safeParse({ ...base, type: "set_auto_compaction", enabled: false }).success);
  assert.equal(ClientFrameSchema.safeParse({ ...base, type: "set_auto_compaction" }).success, false);
});

test("an export names its file only when asked to, and its reply is a path", () => {
  const base = { v: WIRE_VERSION, commandId: "c1", sessionId: "s1" };
  assert.ok(ClientFrameSchema.safeParse({ ...base, type: "export_session" }).success);
  assert.ok(
    ClientFrameSchema.safeParse({ ...base, type: "export_session", outputPath: "out.html" }).success,
  );
  assert.equal(
    ClientFrameSchema.safeParse({ ...base, type: "export_session", outputPath: "  " }).success,
    false,
  );
  assert.ok(ClientFrameSchema.safeParse({ ...base, type: "reload_session" }).success);
  const reply = ServerFrameSchema.safeParse({
    v: WIRE_VERSION,
    type: "exported",
    sessionId: "s1",
    path: "/work/pi-session-s1.html",
  });
  assert.ok(reply.success);
});

test("a terminal open defaults to attaching, and sizes are bounded", () => {
  const open = ClientFrameSchema.parse({
    v: WIRE_VERSION,
    type: "terminal_open",
    commandId: "c1",
    terminalId: "t1",
    cwd: "/w",
    cols: 80,
    rows: 24,
  });
  assert.equal(open.type === "terminal_open" && open.restart, false);
  const huge = { v: WIRE_VERSION, type: "terminal_resize", commandId: "c2", terminalId: "t1", cols: 0, rows: 24 };
  assert.equal(ClientFrameSchema.safeParse(huge).success, false);

  const output = ServerFrameSchema.parse({
    v: WIRE_VERSION,
    type: "terminal_output",
    terminalId: "t1",
    offset: 12,
    data: "\u001b[32mok\u2028\r\n",
  });
  assert.equal(output.type === "terminal_output" && output.data, "\u001b[32mok\u2028\r\n");
});
