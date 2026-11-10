import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { WIRE_VERSION, type ServerFrame } from "@pios/protocol";
import { sessionDirName } from "@pios/pi-host";
import { startHarness, hello, openSession, TestClient, type Harness } from "./helpers.ts";

let harness: Harness;

before(async () => {
  harness = await startHarness();
});
after(async () => {
  await harness.close();
});

/**
 * A session for a test that is about something else.
 *
 * On the wire a session is born from its first prompt; these tests are not
 * about that, and a prompt would start a turn they did not ask for.
 */
async function createSession(_client: TestClient, cwd: string): Promise<string> {
  return openSession(harness, cwd);
}

function summaryOf(client: TestClient, sessionId: string) {
  const welcome = client.received.find((f) => f.type === "welcome");
  assert.ok(welcome?.type === "welcome");
  const summary = welcome.sessions.find((s) => s.sessionId === sessionId);
  assert.ok(summary, `no summary for ${sessionId}`);
  return summary;
}

function settled(client: TestClient, sessionId: string) {
  return client.waitFor(
    (f) =>
      f.type === "agent_event" && f.sessionId === sessionId && f.event.type === "agent_settled",
  );
}

test("health is public and says nothing about sessions", async () => {
  const res = await fetch(`${harness.baseUrl}/health`);
  assert.equal(res.status, 200);
  const body = (await res.json()) as Record<string, unknown>;
  assert.deepEqual(Object.keys(body).sort(), ["ok", "serverVersion", "wireVersion"]);
  assert.equal(body.wireVersion, WIRE_VERSION);
});

test("every other route rejects an unauthenticated caller", async () => {
  const posts = new Set(["/upload?session=x", "/push/subscribe", "/push/unsubscribe"]);
  for (const path of [
    "/sessions",
    "/dirs",
    "/file?session=x&path=y",
    "/upload?session=x",
    "/push/key",
    "/push/subscribe",
    "/push/unsubscribe",
  ]) {
    const res = await fetch(`${harness.baseUrl}${path}`, {
      method: posts.has(path) ? "POST" : "GET",
      body: posts.has(path) ? "{}" : undefined,
    });
    assert.equal(res.status, 401, path);
  }
  const wrong = await fetch(`${harness.baseUrl}/sessions`, {
    headers: { authorization: "Bearer wrong" },
  });
  assert.equal(wrong.status, 401);
});

test("a socket that never says hello is closed", async () => {
  const client = await TestClient.connect(harness);
  const { code } = await client.closed();
  assert.equal(code, 4401);
});

test("a socket with a bad token is closed, not answered", async () => {
  const client = await TestClient.connect(harness);
  client.send({ type: "hello", deviceToken: "nope", clientVersion: "test" });
  const { code } = await client.closed();
  assert.equal(code, 4401);
  assert.deepEqual(client.received, [], "nothing is disclosed to an unauthorised socket");
});

test("commands before hello are refused", async () => {
  const client = await TestClient.connect(harness);
  client.send({ type: "list_sessions" });
  const { code } = await client.closed();
  assert.equal(code, 4401);
});

test("a frame from another wire version is rejected with a clear reason", async () => {
  const client = await hello(harness);
  const socket = (client as unknown as { socket: { send(d: string): void } }).socket;
  socket.send(JSON.stringify({ v: 99, type: "list_sessions", commandId: "v99" }));

  const frame = await client.waitFor((f) => f.type === "error");
  assert.equal(frame.type === "error" && frame.code, "bad_request");
  assert.match(frame.type === "error" ? frame.message : "", /wire version 99/);
  client.close();
});

test("session lifecycle: create, prompt, stream, resync", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "work");
  mkdirSync(cwd, { recursive: true });

  const sessionId = await createSession(client, cwd);
  const subscribed = client.send({ type: "subscribe", sessionId });
  await client.waitForCommand(subscribed);

  const promptId = client.send({
    type: "prompt",
    sessionId,
    messageId: "m1",
    text: "hello",
    images: [],
  });
  const ack = await client.waitForCommand(promptId);
  assert.equal(ack.type, "ack");

  await settled(client, sessionId);

  const deltas = client.received
    .filter((f): f is Extract<ServerFrame, { type: "agent_event" }> => f.type === "agent_event")
    .map((f) => f.event)
    .filter((e) => e.type === "message_update" && e.assistantMessageEvent.type === "text_delta")
    .map((e) => (e.type === "message_update" && "delta" in e.assistantMessageEvent ? e.assistantMessageEvent.delta : ""));
  assert.equal(deltas.join(""), "echo: hello");

  const entriesId = client.send({ type: "get_entries", sessionId });
  const entries = await client.waitForCommand(entriesId);
  assert.equal(entries.type, "entries");
  assert.equal(entries.type === "entries" && entries.entries.length, 2);
  client.close();
});

test("a reconnecting client resumes from its entry cursor", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "resume");
  mkdirSync(cwd, { recursive: true });
  const sessionId = await createSession(client, cwd);

  await client.waitForCommand(client.send({ type: "subscribe", sessionId }));
  client.send({ type: "prompt", sessionId, messageId: "m1", text: "one", images: [] });
  await settled(client, sessionId);

  const first = await client.waitForCommand(client.send({ type: "get_entries", sessionId }));
  const cursor = first.type === "entries" ? first.leafId! : "";
  client.close();

  // A second prompt happens while nobody is connected: the daemon owns the
  // session, so the agent does not care that the client went away.
  const second = await hello(harness);
  // Subscribing from the live cursor, so the previous run is not replayed as
  // if it were happening now.
  const summary = summaryOf(second, sessionId);
  await second.waitForCommand(
    second.send({ type: "subscribe", sessionId, sinceSeq: summary.lastSeq }),
  );
  second.send({ type: "prompt", sessionId, messageId: "m2", text: "two", images: [] });
  await settled(second, sessionId);

  const delta = await second.waitForCommand(
    second.send({ type: "get_entries", sessionId, since: cursor }),
  );
  assert.equal(delta.type, "entries");
  assert.equal(delta.type === "entries" && delta.reset, false);
  assert.equal(delta.type === "entries" && delta.entries.length, 2, "only what was missed");
  second.close();
});

test("an unknown cursor asks the client to start over", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "cursor");
  mkdirSync(cwd, { recursive: true });
  const sessionId = await createSession(client, cwd);

  const frame = await client.waitForCommand(
    client.send({ type: "get_entries", sessionId, since: "bogus" }),
  );
  assert.equal(frame.type === "entries" && frame.reset, true);
  client.close();
});

test("a redelivered prompt is acked but not run twice", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "dedupe");
  mkdirSync(cwd, { recursive: true });
  const sessionId = await createSession(client, cwd);
  await client.waitForCommand(client.send({ type: "subscribe", sessionId }));

  const commandId = "outbox-1";
  client.send({ type: "prompt", sessionId, messageId: "m1", text: "once", images: [], commandId });
  await client.waitForCommand(commandId);
  await settled(client, sessionId);

  // Exactly what the outbox does after a lost ack.
  client.send({ type: "prompt", sessionId, messageId: "m1", text: "once", images: [], commandId });
  const repeat = await client.waitFor(
    (f) => f.type === "ack" && f.commandId === commandId && f.duplicate === true,
  );
  assert.equal(repeat.type === "ack" && repeat.duplicate, true);

  const entries = await client.waitForCommand(client.send({ type: "get_entries", sessionId }));
  assert.equal(entries.type === "entries" && entries.entries.length, 2, "one turn, not two");
  client.close();
});

test("a rewind branches into a new session and leaves the old one intact", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "rewind");
  mkdirSync(cwd, { recursive: true });
  const sessionId = await createSession(client, cwd);
  await client.waitForCommand(client.send({ type: "subscribe", sessionId }));

  // Counted rather than matched: the second turn's settle looks exactly like
  // the first one, which is already in the received log.
  const settles = () =>
    client.received.filter(
      (f) => f.type === "agent_event" && f.sessionId === sessionId && f.event.type === "agent_settled",
    ).length;
  for (const [turn, text] of ["first", "second"].entries()) {
    client.send({ type: "prompt", sessionId, messageId: text, text, images: [] });
    await client.waitFor(() => settles() > turn);
  }
  const before = await client.waitForCommand(client.send({ type: "get_entries", sessionId }));
  assert.equal(before.type === "entries" && before.entries.length, 4);
  const secondTurn = before.type === "entries" ? before.entries[2]! : null;

  const rewound = await client.waitForCommand(
    client.send({ type: "rewind", sessionId, entryId: secondTurn!.id }),
  );
  assert.equal(rewound.type, "rewound");
  assert.equal(rewound.type === "rewound" && rewound.text, "second");
  const branchId = rewound.type === "rewound" ? rewound.branchSessionId : "";
  assert.notEqual(branchId, sessionId, "the branch is a session of its own");

  const branch = await client.waitForCommand(
    client.send({ type: "get_entries", sessionId: branchId }),
  );
  assert.equal(branch.type === "entries" && branch.entries.length, 2, "history before the turn");

  const original = await client.waitForCommand(client.send({ type: "get_entries", sessionId }));
  assert.equal(original.type === "entries" && original.entries.length, 4, "nothing was dropped");

  const listed = await client.waitForCommand(client.send({ type: "list_sessions" }));
  const ids = listed.type === "sessions" ? listed.sessions.map((s) => s.sessionId) : [];
  assert.ok(ids.includes(sessionId) && ids.includes(branchId), "both are in the picker");
  client.close();
});

test("a late subscriber gets the in-flight turn, not a finished one", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "replay");
  mkdirSync(cwd, { recursive: true });
  const sessionId = await createSession(client, cwd);

  await client.waitForCommand(client.send({ type: "subscribe", sessionId }));
  client.send({ type: "prompt", sessionId, messageId: "m1", text: "buffered", images: [] });
  await settled(client, sessionId);
  client.close();

  const late = await hello(harness);
  const subscribed = await late.waitForCommand(late.send({ type: "subscribe", sessionId }));
  assert.equal(subscribed.type, "subscribed");
  assert.equal(subscribed.type === "subscribed" && subscribed.gap, false);
  assert.ok(
    !late.received.some((f) => f.type === "agent_event"),
    "a settled turn was replayed at a client that reads it from entries",
  );
  late.close();
});

test("files are served from inside the session cwd only", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "files");
  mkdirSync(cwd, { recursive: true });
  writeFileSync(join(cwd, "note.txt"), "visible");
  writeFileSync(join(harness.dir, "private.txt"), "hidden");
  const sessionId = await createSession(client, cwd);

  const auth = { authorization: `Bearer ${harness.deviceToken}` };
  const ok = await fetch(`${harness.baseUrl}/file?session=${sessionId}&path=note.txt`, {
    headers: auth,
  });
  assert.equal(ok.status, 200);
  assert.equal(await ok.text(), "visible");

  const escape = await fetch(
    `${harness.baseUrl}/file?session=${sessionId}&path=../private.txt`,
    { headers: auth },
  );
  // 404, not 403: a different answer would confirm the file exists.
  assert.equal(escape.status, 404);
  client.close();
});

test("editing a file goes through its etag", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "edit");
  mkdirSync(cwd, { recursive: true });
  writeFileSync(join(cwd, "a.txt"), "one\n");
  const sessionId = await createSession(client, cwd);
  const auth = { authorization: `Bearer ${harness.deviceToken}` };
  const file = `${harness.baseUrl}/file?session=${sessionId}&path=a.txt`;

  const loaded = await fetch(`${file}&text=1`, { headers: auth });
  const body = (await loaded.json()) as { text: string; etag: string; editable: boolean };
  assert.equal(body.text, "one\n");
  assert.equal(body.editable, true);

  const stale = await fetch(file, {
    method: "PUT",
    headers: { ...auth, "if-match": '"stale"' },
    body: "mine\n",
  });
  assert.equal(stale.status, 409);

  const saved = await fetch(file, {
    method: "PUT",
    headers: { ...auth, "if-match": body.etag },
    body: "two\n",
  });
  assert.equal(saved.status, 200);
  assert.equal(await (await fetch(file, { headers: auth })).text(), "two\n");

  const escape = await fetch(`${harness.baseUrl}/file?session=${sessionId}&path=../out.txt`, {
    method: "PUT",
    headers: auth,
    body: "nope",
  });
  assert.equal(escape.status, 404);
  client.close();
});

test("the session file tree lists files and skips noise", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "tree");
  mkdirSync(join(cwd, "node_modules"), { recursive: true });
  mkdirSync(join(cwd, "src"), { recursive: true });
  writeFileSync(join(cwd, "readme.md"), "");
  const sessionId = await createSession(client, cwd);

  const res = await fetch(`${harness.baseUrl}/dirs?session=${sessionId}&files=1`, {
    headers: { authorization: `Bearer ${harness.deviceToken}` },
  });
  const listing = (await res.json()) as {
    root: string;
    entries: { name: string; dir: boolean }[];
  };
  assert.deepEqual(
    listing.entries.map((e) => e.name),
    ["src", "readme.md"],
  );
  client.close();
});

test("file search is scoped to the session cwd", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "search");
  mkdirSync(join(cwd, "src"), { recursive: true });
  writeFileSync(join(cwd, "src", "composer.tsx"), "");
  writeFileSync(join(harness.dir, "composer-outside.tsx"), "");
  const sessionId = await createSession(client, cwd);

  const res = await fetch(`${harness.baseUrl}/files?session=${sessionId}&q=composer`, {
    headers: { authorization: `Bearer ${harness.deviceToken}` },
  });
  assert.equal(res.status, 200);
  const body = (await res.json()) as { files: string[] };
  assert.deepEqual(body.files, ["src/composer.tsx"]);
  client.close();
});

test("uploads land inside the session cwd", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "uploads");
  mkdirSync(cwd, { recursive: true });
  const sessionId = await createSession(client, cwd);

  const res = await fetch(
    `${harness.baseUrl}/upload?session=${sessionId}&name=../../escape.png`,
    {
      method: "POST",
      headers: { authorization: `Bearer ${harness.deviceToken}` },
      body: Buffer.from("image-bytes"),
    },
  );
  assert.equal(res.status, 200);
  const { path } = (await res.json()) as { path: string };
  assert.ok(path.startsWith(join(cwd, ".pios-uploads")), `escaped to ${path}`);
  client.close();
});

test("directory listing stays inside the home directory", async () => {
  const auth = { authorization: `Bearer ${harness.deviceToken}` };
  const home = await fetch(`${harness.baseUrl}/dirs`, { headers: auth });
  assert.equal(home.status, 200);
  const listing = (await home.json()) as {
    root: string;
    parent: string | null;
    entries: { name: string; path: string }[];
  };
  assert.equal(listing.parent, null, "the root has nowhere further up");
  assert.ok(listing.entries.every((e) => e.path.startsWith(listing.root)));
  assert.ok(listing.entries.every((e) => !e.name.startsWith(".")));

  const escape = await fetch(`${harness.baseUrl}/dirs?path=/etc`, { headers: auth });
  assert.equal(escape.status, 404);
});

test("directories with recent pi sessions sort first", async () => {
  const auth = { authorization: `Bearer ${harness.deviceToken}` };
  const before = (await (await fetch(`${harness.baseUrl}/dirs`, { headers: auth })).json()) as {
    entries: { name: string; path: string }[];
  };
  // Needs two real home subdirectories to have an order to change.
  if (before.entries.length < 2) return;
  const last = before.entries[before.entries.length - 1]!;
  mkdirSync(join(harness.dir, "sessions", sessionDirName(last.path)), { recursive: true });

  const after = (await (await fetch(`${harness.baseUrl}/dirs`, { headers: auth })).json()) as {
    entries: { name: string; lastSessionAt: number | null }[];
  };
  assert.equal(after.entries[0]?.name, last.name);
  assert.ok((after.entries[0]?.lastSessionAt ?? 0) > 0);
  // Everything without a session keeps alphabetical order.
  const rest = after.entries.slice(1).map((e) => e.name);
  assert.deepEqual(rest, [...rest].sort((a, b) => a.localeCompare(b)));
});

test("an unknown session reads as empty, and a command on it is refused", async () => {
  const client = await hello(harness);
  // Reading is a file read: an id with nothing behind it has no transcript,
  // which is what a composer that has not sent its first prompt looks like.
  const entries = await client.waitForCommand(
    client.send({ type: "get_entries", sessionId: "ghost" }),
  );
  assert.ok(entries.type === "entries");
  assert.deepEqual(entries.entries, []);

  // Anything that needs the agent cannot invent a directory to start it in.
  const frame = await client.waitForCommand(
    client.send({ type: "get_stats", sessionId: "ghost" }),
  );
  assert.equal(frame.type === "error" && frame.code, "unknown_session");

  // The socket still works afterwards.
  const list = await client.waitForCommand(client.send({ type: "list_sessions" }));
  assert.equal(list.type, "sessions");
  client.close();
});

test("a cross-origin preflight is answered without credentials", async () => {
  const res = await fetch(`${harness.baseUrl}/pair`, {
    method: "OPTIONS",
    headers: {
      origin: "http://phone.local:5173",
      "access-control-request-method": "POST",
      "access-control-request-headers": "content-type",
    },
  });
  assert.equal(res.status, 204);
  assert.equal(res.headers.get("access-control-allow-origin"), "http://phone.local:5173");
  assert.ok(res.headers.get("access-control-allow-headers")?.includes("authorization"));
  // Never set: a bearer token is not a cookie, and allowing credentials would
  // let a hostile page ride an ambient session.
  assert.equal(res.headers.get("access-control-allow-credentials"), null);

  const listing = await fetch(`${harness.baseUrl}/dirs`, {
    headers: { authorization: `Bearer ${harness.deviceToken}`, origin: "http://phone.local:5173" },
  });
  assert.equal(listing.headers.get("access-control-allow-origin"), "http://phone.local:5173");
});

test("a session started by one client is announced to every other", async () => {
  const watcher = await hello(harness);
  const actor = await hello(harness);
  const cwd = join(harness.dir, "shared");
  mkdirSync(cwd, { recursive: true });

  const sessionId = `00000000-0000-4000-8000-aaaaaaaaaaaa`;
  await actor.waitForCommand(
    actor.send({
      type: "prompt",
      sessionId,
      create: { cwd, trustProject: false },
      messageId: "shared-m1",
      text: "hello",
      images: [],
    }),
  );

  // A nudge, not a payload: the other client re-asks for the page it is on.
  await watcher.waitFor((f) => f.type === "sessions_changed");
  const listed = await watcher.waitForCommand(watcher.send({ type: "list_sessions" }));
  assert.ok(
    listed.type === "sessions" && listed.sessions.some((s) => s.sessionId === sessionId),
    "the other client learns about a session it did not create",
  );
  watcher.close();
  actor.close();
});

test("thinking levels follow the model and a switch crosses the wire", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "thinking");
  mkdirSync(cwd, { recursive: true });

  const sessionId = await createSession(client, cwd);
  // The starting model does not reason, so there is nothing to choose from.
  const reasoning = await client.waitForCommand(
    client.send({ type: "set_model", sessionId, provider: "acme", modelId: "deep-1" }),
  );
  assert.deepEqual(
    reasoning.type === "session_state" ? reasoning.summary.thinkingLevels : null,
    ["off", "low", "medium", "high"],
  );

  const raised = await client.waitForCommand(
    client.send({ type: "set_thinking_level", sessionId, level: "high" }),
  );
  assert.equal(raised.type === "session_state" ? raised.summary.thinkingLevel : null, "high");

  // Moving back to a model without reasoning clamps the level pi reports.
  const plain = await client.waitForCommand(
    client.send({ type: "set_model", sessionId, provider: "acme", modelId: "fast-1" }),
  );
  assert.equal(plain.type === "session_state" ? plain.summary.thinkingLevel : null, "off");
  assert.deepEqual(plain.type === "session_state" ? plain.summary.thinkingLevels : null, ["off"]);
  client.close();
});

test("a draft can list models before its first prompt", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "draft-models");
  mkdirSync(cwd, { recursive: true });

  // The id the draft composed against: the session it starts is the one the
  // first prompt will land on, not a second one.
  const sessionId = "00000000-0000-4000-8000-bbbbbbbbbbbb";
  const listed = await client.waitForCommand(
    client.send({ type: "list_models", sessionId, all: false, create: { cwd, trustProject: false } }),
  );
  assert.equal(listed.type, "models");
  assert.ok(listed.type === "models" && listed.models.length >= 2);

  const page = await client.waitForCommand(client.send({ type: "list_sessions" }));
  assert.ok(
    page.type === "sessions" && page.sessions.some((s) => s.sessionId === sessionId),
    "the draft's id is the session's id",
  );
  client.close();
});

test("the model list and a model switch cross the wire", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "models");
  mkdirSync(cwd, { recursive: true });

  const sessionId = await createSession(client, cwd);
  const listed = await client.waitForCommand(
    client.send({ type: "list_models", sessionId, all: false }),
  );
  assert.equal(listed.type, "models");
  assert.ok(listed.type === "models" && listed.models.length >= 2);

  const target = listed.type === "models" ? listed.models[1]! : null;
  assert.ok(target);
  const switched = await client.waitForCommand(
    client.send({ type: "set_model", sessionId, provider: target.provider, modelId: target.modelId }),
  );
  assert.equal(switched.type, "session_state");
  assert.equal(
    switched.type === "session_state" ? switched.summary.model?.modelId : null,
    target.modelId,
  );
  client.close();
});

test("the slash command list crosses the wire", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "commands");
  mkdirSync(cwd, { recursive: true });

  const sessionId = await createSession(client, cwd);
  const listed = await client.waitForCommand(client.send({ type: "list_commands", sessionId }));
  assert.equal(listed.type, "commands");
  assert.ok(listed.type === "commands" && listed.commands.length > 0);
  assert.ok(
    listed.type === "commands" && listed.commands.some((command) => command.source === "skill"),
  );
  client.close();
});

test("session stats cross the wire", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "stats");
  mkdirSync(cwd, { recursive: true });

  const sessionId = await createSession(client, cwd);
  const reply = await client.waitForCommand(client.send({ type: "get_stats", sessionId }));
  assert.equal(reply.type, "session_stats");
  assert.equal(reply.type === "session_stats" ? reply.stats.tokens?.total : null, 2400);
  client.close();
});

test("a device registers a push subscription and takes it back", async () => {
  const key = await fetch(`${harness.baseUrl}/push/key`, {
    headers: { authorization: `Bearer ${harness.deviceToken}` },
  });
  assert.equal(key.status, 200);
  assert.ok(((await key.json()) as { publicKey: string }).publicKey.length > 0);

  const bad = await fetch(`${harness.baseUrl}/push/subscribe`, {
    method: "POST",
    headers: { authorization: `Bearer ${harness.deviceToken}` },
    body: JSON.stringify({ endpoint: "http://push.example/1" }),
  });
  assert.equal(bad.status, 400);

  const ok = await fetch(`${harness.baseUrl}/push/subscribe`, {
    method: "POST",
    headers: { authorization: `Bearer ${harness.deviceToken}` },
    body: JSON.stringify({
      endpoint: "https://push.example/1",
      keys: { p256dh: "a", auth: "b" },
    }),
  });
  assert.equal(ok.status, 200);
  assert.equal(harness.server.push.list().length, 1);

  const gone = await fetch(`${harness.baseUrl}/push/unsubscribe`, {
    method: "POST",
    headers: { authorization: `Bearer ${harness.deviceToken}` },
    body: JSON.stringify({ endpoint: "https://push.example/1" }),
  });
  assert.equal(gone.status, 200);
  assert.equal(harness.server.push.list().length, 0);
});

test("a bash command streams to every subscriber and is acked once", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "bash");
  mkdirSync(cwd, { recursive: true });
  const sessionId = await createSession(client, cwd);
  await client.waitForCommand(client.send({ type: "subscribe", sessionId }));

  const commandId = client.send({ type: "run_bash", sessionId, command: "echo hi", excludeFromContext: true });
  const started = await client.waitFor((f) => f.type === "bash_state" && f.running);
  assert.equal(started.type === "bash_state" && started.excludeFromContext, true);

  const ack = await client.waitForCommand(commandId);
  assert.equal(ack.type, "ack");

  const finished = await client.waitFor((f) => f.type === "bash_state" && !f.running);
  assert.equal(finished.type === "bash_state" && finished.result?.exitCode, 0);

  // A redelivery must not run the command a second time. Matched on the flag
  // as well as the id: the first ack for it is already in `received`.
  client.send({ type: "run_bash", sessionId, command: "echo hi", excludeFromContext: true, commandId });
  await client.waitFor((f) => f.type === "ack" && f.commandId === commandId && f.duplicate);

  const entries = await client.waitForCommand(client.send({ type: "get_entries", sessionId }));
  assert.equal(entries.type === "entries" && entries.entries.length, 1);
  client.close();
});

test("a session is named, compacted and switched off auto-compaction from the client", async () => {
  const client = await hello(harness);
  const sessionId = await openSession(harness, harness.dir);
  await client.waitForCommand(client.send({ type: "subscribe", sessionId }));

  const named = await client.waitForCommand(
    client.send({ type: "set_session_name", sessionId, name: "release notes" }),
  );
  assert.equal(named.type === "session_state" ? named.summary.name : null, "release notes");
  // Persisted by pi, so the list reads it back from the file, not from memory.
  const listed = await client.waitForCommand(client.send({ type: "list_sessions" }));
  assert.equal(
    listed.type === "sessions"
      ? listed.sessions.find((row) => row.sessionId === sessionId)?.name
      : null,
    "release notes",
  );

  const auto = await client.waitForCommand(
    client.send({ type: "set_auto_compaction", sessionId, enabled: false }),
  );
  assert.equal(auto.type === "session_state" ? auto.summary.autoCompaction : null, false);

  const compact = client.send({ type: "compact", sessionId, customInstructions: "keep the API" });
  assert.equal((await client.waitForCommand(compact)).type, "ack", "acked before the summary exists");
  const ended = await client.waitFor(
    (f) => f.type === "agent_event" && f.sessionId === sessionId && f.event.type === "compaction_end",
  );
  assert.ok(ended.type === "agent_event" && ended.event.type === "compaction_end");
  assert.equal(ended.event.result?.summary, "summary (keep the API)");

  const page = await client.waitForCommand(client.send({ type: "get_entries", sessionId }));
  assert.ok(page.type === "entries");
  assert.equal(page.entries.at(-1)?.type, "compaction");
  client.close();
});

test("a session is exported and reloaded from the client", async () => {
  const client = await hello(harness);
  const cwd = join(harness.dir, "export");
  mkdirSync(cwd, { recursive: true });
  const sessionId = await openSession(harness, cwd);
  await client.waitForCommand(client.send({ type: "subscribe", sessionId }));

  const exported = await client.waitForCommand(client.send({ type: "export_session", sessionId }));
  assert.ok(exported.type === "exported");
  assert.ok(exported.path.startsWith(`${cwd}/`), "anchored to the session, not the daemon");
  assert.ok(existsSync(exported.path));

  const reload = client.send({ type: "reload_session", sessionId });
  assert.equal((await client.waitForCommand(reload)).type, "ack");
  const recovered = await client.waitFor(
    (f) => f.type === "session_recovered" && f.sessionId === sessionId,
  );
  assert.equal(recovered.type === "session_recovered" ? recovered.reason : null, "reloaded");
  client.close();
});

test("a draft browses, searches and reads its directory before it is a session", async () => {
  const bearer = { authorization: `Bearer ${harness.deviceToken}` };
  // Drafts are contained to home, like the directory picker that chose them.
  const dir = mkdtempSync(join(homedir(), ".pios-draft-files-"));
  try {
    mkdirSync(join(dir, "src"));
    writeFileSync(join(dir, "src", "main.ts"), "export {};\n");
    const project = `session=draft-not-started&cwd=${encodeURIComponent(dir)}`;

    const tree = await fetch(`${harness.baseUrl}/dirs?${project}&files=1`, { headers: bearer });
    assert.equal(tree.status, 200);
    const listing = (await tree.json()) as { root: string; entries: { name: string }[] };
    assert.equal(listing.root, dir);
    assert.deepEqual(listing.entries.map((entry) => entry.name), ["src"]);

    const search = await fetch(`${harness.baseUrl}/files?${project}&q=main`, { headers: bearer });
    assert.deepEqual(((await search.json()) as { files: string[] }).files, ["src/main.ts"]);

    const text = await fetch(`${harness.baseUrl}/file?${project}&path=src/main.ts&text=1`, {
      headers: bearer,
    });
    assert.equal(((await text.json()) as { text: string }).text, "export {};\n");

    const outside = await fetch(
      `${harness.baseUrl}/file?session=x&cwd=${encodeURIComponent("/etc")}&path=passwd`,
      { headers: bearer },
    );
    assert.equal(outside.status, 404, "a draft cannot name a directory outside home");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
