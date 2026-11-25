import { test } from "node:test";
import assert from "node:assert/strict";
import { WIRE_VERSION } from "@pios/protocol";
import { PiosClient } from "../src/client.ts";
import { FakeScheduler, flush } from "../src/scheduler.ts";
import { MemoryStorage } from "../src/storage.ts";
import type { TerminalSink } from "../src/terminal.ts";
import { TransportFactoryStub } from "./fake-transport.ts";

async function setup() {
  const scheduler = new FakeScheduler();
  const transports = new TransportFactoryStub();
  let counter = 0;
  const client = new PiosClient({
    createTransport: transports.create,
    scheduler,
    storage: new MemoryStorage(),
    backoff: { baseMs: 1000, capMs: 16_000, factor: 2 },
    generateId: () => `id-${++counter}`,
    generateCommandId: () => `hello-${++counter}`,
  });
  client.start({ url: "ws://test", deviceToken: "token" });
  await flush();
  transports.last.acceptHello();
  return { scheduler, transports, client };
}

function recorder() {
  const log: string[] = [];
  const sink: TerminalSink = {
    reset: () => log.push("reset"),
    output: (data) => log.push(`out:${data}`),
    exit: (info) => log.push(`exit:${info.exitCode}`),
    error: (message) => log.push(`error:${message}`),
  };
  return { log, sink };
}

const SIZE = { cols: 80, rows: 24 };

test("a terminal resumes from its own offset after a reconnect", async () => {
  const { scheduler, transports, client } = await setup();
  const { log, sink } = recorder();
  client.terminals.open("t1", { cwd: "/w", size: SIZE }, sink);

  const [open] = transports.last.sentOfType("terminal_open");
  assert.equal(open?.since, undefined, "a new sink holds nothing");
  const emit = transports.last.emit.bind(transports.last);
  emit({ v: WIRE_VERSION, type: "terminal_attached", commandId: open!.commandId, terminalId: "t1", instance: "i1", offset: 0, reset: true });
  emit({ v: WIRE_VERSION, type: "terminal_output", terminalId: "t1", offset: 0, data: "$ " });
  emit({ v: WIRE_VERSION, type: "terminal_output", terminalId: "t1", offset: 2, data: "ls" });
  // A repeat of something held is dropped, an overlap is trimmed.
  emit({ v: WIRE_VERSION, type: "terminal_output", terminalId: "t1", offset: 0, data: "$ " });
  emit({ v: WIRE_VERSION, type: "terminal_output", terminalId: "t1", offset: 3, data: "s\n" });
  assert.deepEqual(log, ["reset", "out:$ ", "out:ls", "out:\n"]);

  transports.last.drop();
  await scheduler.runNext();
  transports.last.acceptHello();
  const [again] = transports.last.sentOfType("terminal_open");
  assert.deepEqual(again?.since, { instance: "i1", offset: 5 });
});

test("a gap in the stream re-attaches instead of writing past it", async () => {
  const { transports, client } = await setup();
  const { log, sink } = recorder();
  client.terminals.open("t1", { cwd: "/w", size: SIZE }, sink);
  const [open] = transports.last.sentOfType("terminal_open");
  const emit = transports.last.emit.bind(transports.last);
  emit({ v: WIRE_VERSION, type: "terminal_attached", commandId: open!.commandId, terminalId: "t1", instance: "i1", offset: 0, reset: true });
  emit({ v: WIRE_VERSION, type: "terminal_output", terminalId: "t1", offset: 0, data: "ab" });
  emit({ v: WIRE_VERSION, type: "terminal_output", terminalId: "t1", offset: 5, data: "xy" });

  assert.deepEqual(log, ["reset", "out:ab"]);
  const opens = transports.last.sentOfType("terminal_open");
  assert.equal(opens.length, 2);
  assert.deepEqual(opens[1]?.since, { instance: "i1", offset: 2 });
  // Live output racing the re-attach is covered by its replay.
  emit({ v: WIRE_VERSION, type: "terminal_output", terminalId: "t1", offset: 7, data: "zz" });
  assert.deepEqual(log, ["reset", "out:ab"]);
});

test("a refused open reaches the terminal, and keystroke errors reach nobody", async () => {
  const { transports, client } = await setup();
  const { log, sink } = recorder();
  const notices: string[] = [];
  client.onCommandError((error) => notices.push(error.message));
  const handle = client.terminals.open("t1", { cwd: "/nope", size: SIZE }, sink);
  const [open] = transports.last.sentOfType("terminal_open");
  transports.last.emit({ v: WIRE_VERSION, type: "error", commandId: open!.commandId, code: "bad_request", message: "not a directory" });

  assert.ok(handle.write("x"));
  const [input] = transports.last.sentOfType("terminal_input");
  transports.last.emit({ v: WIRE_VERSION, type: "error", commandId: input!.commandId, code: "bad_request", message: "no terminal" });

  assert.deepEqual(log, ["error:not a directory"]);
  assert.deepEqual(notices, []);
});

test("input is never queued while disconnected", async () => {
  const { transports, client } = await setup();
  const handle = client.terminals.open("t1", { cwd: "/w", size: SIZE }, recorder().sink);
  transports.last.drop();
  assert.equal(handle.write("rm -rf build\r"), false);
  handle.detach();
  assert.equal(handle.write("x"), false, "a detached handle is inert");
});

test("the running shells are tracked whoever opened them", async () => {
  const { transports, client } = await setup();
  const seen: string[][] = [];
  client.terminals.subscribeLive((running) => seen.push([...running.keys()]));
  const emit = transports.last.emit.bind(transports.last);
  emit({ v: WIRE_VERSION, type: "terminals", terminals: [{ terminalId: "s1", cwd: "/w", startedAt: 1 }] });
  emit({ v: WIRE_VERSION, type: "terminals", terminals: [] });

  assert.deepEqual(seen, [["s1"], []]);
  assert.equal(client.terminals.live().size, 0);
});
