import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ServerFrame } from "@pios/protocol";
import { TerminalHost, type TerminalListener } from "../src/terminals.ts";
import { startHarness, hello, type Harness, type TestClient } from "./helpers.ts";

// A bare shell with a fixed prompt: the developer's rc files are not the subject.
const SHELL = { shell: "/bin/sh", args: [], env: { PS1: "$ ", ENV: "" } };

let harness: Harness;
let cwd: string;

before(async () => {
  harness = await startHarness(undefined, { terminals: SHELL });
  cwd = mkdtempSync(join(tmpdir(), "pios-term-"));
});
after(async () => {
  await harness.close();
  rmSync(cwd, { recursive: true, force: true });
});

type Output = Extract<ServerFrame, { type: "terminal_output" }>;
type Attached = Extract<ServerFrame, { type: "terminal_attached" }>;

function outputOf(client: TestClient, terminalId: string): string {
  return client.received
    .filter((f): f is Output => f.type === "terminal_output" && f.terminalId === terminalId)
    .map((f) => f.data)
    .join("");
}

function waitForText(client: TestClient, terminalId: string, text: string) {
  return client.waitFor(() => outputOf(client, terminalId).includes(text));
}

async function open(client: TestClient, terminalId: string, extra: Record<string, unknown> = {}) {
  const commandId = client.send({ type: "terminal_open", terminalId, cwd, cols: 80, rows: 24, ...extra } as never);
  return (await client.waitForCommand(commandId)) as Attached;
}

test("a shell runs in the requested directory and reports how it ended", async () => {
  const client = await hello(harness);
  const attached = await open(client, "t-basic");
  assert.equal(attached.type, "terminal_attached");
  assert.equal(attached.reset, true);

  client.send({ type: "terminal_input", terminalId: "t-basic", data: "pwd; echo done-$((1+2))\n" });
  await waitForText(client, "t-basic", "done-3");
  assert.ok(outputOf(client, "t-basic").includes(cwd));

  client.send({ type: "terminal_input", terminalId: "t-basic", data: "exit 7\n" });
  const exit = await client.waitFor((f) => f.type === "terminal_exit" && f.terminalId === "t-basic");
  assert.equal(exit.type === "terminal_exit" && exit.exitCode, 7);
  client.close();
});

test("a reconnect with a cursor gets only what it missed", async () => {
  const first = await hello(harness);
  const attached = await open(first, "t-resume");
  first.send({ type: "terminal_input", terminalId: "t-resume", data: "echo before\n" });
  await waitForText(first, "t-resume", "before");
  // Settle, so the cursor covers the prompt that follows the echo.
  await new Promise((resolve) => setTimeout(resolve, 100));
  const held = outputOf(first, "t-resume");
  first.close();

  const second = await hello(harness);
  const watcher = await hello(harness);
  await open(watcher, "t-resume");
  watcher.send({ type: "terminal_input", terminalId: "t-resume", data: "echo after\n" });
  await waitForText(watcher, "t-resume", "after");

  const resumed = await open(second, "t-resume", {
    since: { instance: attached.instance, offset: attached.offset + held.length },
  });
  assert.equal(resumed.reset, false);
  await waitForText(second, "t-resume", "after");
  assert.ok(!outputOf(second, "t-resume").includes("before"), "nothing held is sent twice");

  // A cursor into another shell is no cursor at all.
  const stranger = await hello(harness);
  const fresh = await open(stranger, "t-resume", { since: { instance: "other", offset: 3 } });
  assert.equal(fresh.reset, true);
  await waitForText(stranger, "t-resume", "before");

  for (const client of [second, watcher, stranger]) client.close();
  harness.server.terminals.close("t-resume");
});

test("an exited shell is shown to a cursor into it, and replaced for anyone else", async () => {
  const client = await hello(harness);
  const first = await open(client, "t-restart");
  client.send({ type: "terminal_input", terminalId: "t-restart", data: "exit 2\n" });
  await client.waitFor((f) => f.type === "terminal_exit" && f.terminalId === "t-restart");

  // A reconnect that held the old screen learns how it ended.
  const again = await hello(harness);
  const reattached = await open(again, "t-restart", { since: { instance: first.instance, offset: 0 } });
  assert.equal(reattached.instance, first.instance);
  await again.waitFor((f) => f.type === "terminal_exit" && f.terminalId === "t-restart");

  // A screen opened afresh gets a new shell, not a finished one.
  const fresh = await hello(harness);
  const restarted = await open(fresh, "t-restart");
  assert.notEqual(restarted.instance, first.instance);
  assert.equal(restarted.reset, true);
  fresh.send({ type: "terminal_input", terminalId: "t-restart", data: "echo alive\n" });
  await waitForText(fresh, "t-restart", "alive");

  const closeId = fresh.send({ type: "terminal_close", terminalId: "t-restart" });
  await fresh.waitForCommand(closeId);
  await fresh.waitFor((f) => f.type === "terminal_exit" && f.terminalId === "t-restart");
  for (const c of [client, again, fresh]) c.close();
});

type Terminals = Extract<ServerFrame, { type: "terminals" }>;

function liveIds(client: TestClient): string[] | undefined {
  const last = client.received.filter((f): f is Terminals => f.type === "terminals").at(-1);
  return last?.terminals.map((t) => t.terminalId);
}

test("every device hears which shells are running", async () => {
  const watcher = await hello(harness);
  await watcher.waitFor((f) => f.type === "terminals");
  assert.ok(!liveIds(watcher)?.includes("t-list"));

  const client = await hello(harness);
  await open(client, "t-list");
  await watcher.waitFor(() => liveIds(watcher)?.includes("t-list") === true);
  const late = await hello(harness);
  await late.waitFor(() => liveIds(late)?.includes("t-list") === true);

  client.send({ type: "terminal_input", terminalId: "t-list", data: "exit\n" });
  await watcher.waitFor(() => liveIds(watcher)?.includes("t-list") === false);
  for (const c of [watcher, client, late]) c.close();
});

test("a directory that is not there is refused", async () => {
  const client = await hello(harness);
  const commandId = client.send({
    type: "terminal_open",
    terminalId: "t-missing",
    cwd: join(cwd, "nope"),
    cols: 80,
    rows: 24,
    restart: false,
  });
  const reply = await client.waitForCommand(commandId);
  assert.equal(reply.type, "error");
  const input = client.send({ type: "terminal_input", terminalId: "t-missing", data: "x" });
  assert.equal((await client.waitForCommand(input)).type, "error");
  client.close();
});

function sink(): TerminalListener & { text: string; exited: boolean } {
  return {
    text: "",
    exited: false,
    output(data) {
      this.text += data;
    },
    exit() {
      this.exited = true;
    },
    congested: () => false,
  };
}

test("scrollback is bounded and replays from a line start", async () => {
  const host = new TerminalHost({ ...SHELL, scrollback: 4096 });
  const terminal = host.open("bounded", { cwd, cols: 80, rows: 24 });
  const live = sink();
  terminal.attach(live);
  terminal.write("i=0; while [ $i -lt 2000 ]; do echo line-$i; i=$((i+1)); done; exit 0\n");
  await new Promise<void>((resolve) => {
    const timer = setInterval(() => {
      if (live.exited) resolve(), clearInterval(timer);
    }, 20);
  });

  const late = terminal.attach(sink());
  assert.equal(late.reset, true);
  assert.ok(late.offset > 0, "the front was trimmed");
  assert.ok(late.data.length <= 4096);
  assert.ok(late.data.includes("line-1999"));
  assert.equal(late.offset + late.data.length, terminal.end);
  host.closeAll();
});

test("the number of live shells is capped", async () => {
  const host = new TerminalHost({ ...SHELL, maxTerminals: 2 });
  host.open("a", { cwd, cols: 80, rows: 24 });
  host.open("b", { cwd, cols: 80, rows: 24 });
  assert.throws(() => host.open("c", { cwd, cols: 80, rows: 24 }), /close one/);
  // The same id is the same shell, not a third one.
  assert.equal(host.open("a", { cwd, cols: 80, rows: 24 }), host.get("a"));
  host.closeAll();
});

test("a shell nobody is attached to is closed after the idle timeout", async () => {
  let changes = 0;
  const host = new TerminalHost({ ...SHELL, idleMs: 150 }, () => changes++);
  const watched = host.open("watched", { cwd, cols: 80, rows: 24 });
  const live = sink();
  watched.attach(live);
  const left = host.open("left", { cwd, cols: 80, rows: 24 });
  assert.equal(changes, 2);

  await new Promise((resolve) => setTimeout(resolve, 400));
  assert.equal(host.get("left"), undefined, "the detached shell is gone");
  assert.ok(!host.live().includes(left));
  assert.deepEqual(host.live().map((t) => t.id), ["watched"]);

  // Detaching starts the clock; attaching again stops it.
  watched.detach(live);
  await new Promise((resolve) => setTimeout(resolve, 50));
  watched.attach(live);
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.equal(host.get("watched"), watched);
  assert.ok(changes >= 3);
  host.closeAll();
});
