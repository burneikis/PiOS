import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { connect, createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, type ChildProcess } from "node:child_process";
import { fileURLToPath } from "node:url";
import { WebSocket, type ClientOptions } from "ws";
import { WIRE_VERSION } from "@pios/protocol";
import { HOST_OFFLINE_CLOSE_CODE, HOST_OFFLINE_HEADER } from "@pios/relay/codec";
import { relayKeyPath, defaultConfig } from "../src/config.ts";
import { enrollAtRelay, RelayConnector, RelayRejectedError } from "../src/relay-connector.ts";
import { RelayKey } from "../src/relay-key.ts";
import { openSession, startHarness, type Harness } from "./helpers.ts";

/**
 * The real Worker, run by `wrangler dev` from its own wrangler.toml, in front
 * of a real daemon. Nothing is faked between the phone's fetch and the daemon's route
 * handler except pi itself.
 */

const SECRET = "first-enrollment-secret-0123456789abcdef";
const ROTATED = "rotated-enrollment-secret-0123456789abcdef";
const RELAY_DIR = fileURLToPath(new URL("../../relay/", import.meta.url));
const WRANGLER = join(RELAY_DIR, "node_modules", ".bin", "wrangler");

let wrangler: ChildProcess | null = null;
let relayUrl: string;
let relayPort = 0;
let harness: Harness;
const scratch = mkdtempSync(join(tmpdir(), "pios-relay-"));

/** Fixed across restarts, so connectors keep dialing the same URL. */
function freePort(): Promise<number> {
  return new Promise((resolve) => {
    const probe = createServer().listen(0, "127.0.0.1", () => {
      const address = probe.address();
      probe.close(() => resolve(typeof address === "object" && address ? address.port : 0));
    });
  });
}

async function startRelay(enrollSecret: string): Promise<void> {
  await stopRelay();
  relayPort ||= await freePort();
  relayUrl = `http://127.0.0.1:${relayPort}`;
  let output = "";
  wrangler = spawn(
    WRANGLER,
    [
      "dev",
      "--ip",
      "127.0.0.1",
      "--port",
      String(relayPort),
      "--var",
      `ENROLL_SECRET:${enrollSecret}`,
      // On disk, so the enrolled key survives the restart a rotation needs.
      "--persist-to",
      join(scratch, "state"),
      "--show-interactive-dev-session=false",
      "--log-level",
      "warn",
    ],
    {
      cwd: RELAY_DIR,
      env: { ...process.env, WRANGLER_SEND_METRICS: "false", CI: "1", NO_UPDATE_NOTIFIER: "1" },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  wrangler.stdout?.on("data", (chunk) => (output += chunk));
  wrangler.stderr?.on("data", (chunk) => (output += chunk));
  try {
    await until(async () => {
      try {
        return (await fetch(`${relayUrl}/health`)).status > 0;
      } catch {
        return false;
      }
    }, 60_000);
  } catch (error) {
    throw new Error(`wrangler dev did not start:\n${output}`, { cause: error });
  }
}

async function stopRelay(): Promise<void> {
  const child = wrangler;
  wrangler = null;
  if (!child || child.exitCode !== null) return;
  const exited = new Promise((resolve) => child.once("exit", resolve));
  child.kill("SIGTERM");
  await Promise.race([exited, new Promise((resolve) => setTimeout(resolve, 5_000))]);
  if (child.exitCode === null) child.kill("SIGKILL");
}

function relayWs(path: string): WebSocket {
  // The close frame arrives at once, but wrangler dev holds the TCP socket
  // open for seconds after it; browsers stop waiting sooner than ws does.
  // `closeTimeout` exists in ws but not yet in its published types.
  const options = { closeTimeout: 500 } as ClientOptions;
  return new WebSocket(relayUrl.replace(/^http/, "ws") + path, options);
}

function opened(ws: WebSocket): Promise<void> {
  return new Promise((resolve, reject) => {
    ws.once("open", () => resolve());
    ws.once("error", reject);
  });
}

function closed(ws: WebSocket): Promise<{ code: number; reason: string }> {
  return new Promise((resolve) =>
    ws.once("close", (code, reason) => resolve({ code, reason: reason.toString() })),
  );
}

async function until(check: () => boolean | Promise<boolean>, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!(await check())) {
    if (Date.now() > deadline) throw new Error("condition not met in time");
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

before(async () => {
  await startRelay(SECRET);

  harness = await startHarness(undefined, {
    relayUrl,
    // Enrolled before the daemon starts, the way an operator would.
    beforeListen: async (dataDir) => {
      const key = RelayKey.loadOrCreate(relayKeyPath(defaultConfig({ dataDir })));
      await enrollAtRelay(relayUrl, key, SECRET);
    },
  });
  await until(() => harness.server.relay?.state === "online");
});

after(async () => {
  await harness?.close();
  await stopRelay();
  rmSync(scratch, { recursive: true, force: true });
});

test("the key file is private and survives a reload", () => {
  const path = relayKeyPath(harness.server.config);
  const again = RelayKey.loadOrCreate(path);
  assert.equal(again.publicKey, RelayKey.loadOrCreate(path).publicKey);
  assert.ok(again.acceptedAt);
  assert.doesNotMatch(readFileSync(path, "utf8"), /BEGIN/);
});

test("public routes answer through the relay", async () => {
  const response = await fetch(`${relayUrl}/health`);
  assert.equal(response.status, 200);
  assert.deepEqual(((await response.json()) as { wireVersion: number }).wireVersion, WIRE_VERSION);
});

test("the relay forwards but never authorizes", async () => {
  const denied = await fetch(`${relayUrl}/sessions`);
  assert.equal(denied.status, 401);
  const allowed = await fetch(`${relayUrl}/sessions`, {
    headers: { authorization: `Bearer ${harness.deviceToken}` },
  });
  assert.equal(allowed.status, 200);
});

test("pairing works end to end through the relay", async () => {
  const { token } = harness.server.auth.createPairing();
  const paired = await fetch(`${relayUrl}/pair`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ pairingToken: token, label: "relay test" }),
  });
  assert.equal(paired.status, 200);
  const { deviceToken } = (await paired.json()) as { deviceToken: string };
  assert.ok(harness.server.auth.verify(deviceToken));
});

test("an oversized upload is refused through the relay and the route stays usable", async () => {
  const cwd = mkdtempSync(join(scratch, "cwd-"));
  const session = await openSession(harness, cwd);
  const auth = { authorization: `Bearer ${harness.deviceToken}` };
  const config = harness.server.config as { maxUploadBytes: number };
  const limit = config.maxUploadBytes;
  config.maxUploadBytes = 64 * 1024;
  try {
    const refused = await fetch(`${relayUrl}/upload?session=${session}&name=big.bin`, {
      method: "POST",
      headers: auth,
      body: new Uint8Array(1024 * 1024),
    });
    assert.equal(refused.status, 413);
    const small = await fetch(`${relayUrl}/upload?session=${session}&name=small.bin`, {
      method: "POST",
      headers: auth,
      body: new Uint8Array(10),
    });
    assert.equal(small.status, 200);
  } finally {
    config.maxUploadBytes = limit;
  }
});

test("large bodies cross in both directions byte for byte", async () => {
  const cwd = mkdtempSync(join(scratch, "cwd-"));
  const session = await openSession(harness, cwd);
  const auth = { authorization: `Bearer ${harness.deviceToken}` };

  const upload = new Uint8Array(3 * 1024 * 1024 + 17).map((_, i) => (i * 31) & 0xff);
  const posted = await fetch(`${relayUrl}/upload?session=${session}&name=big.bin`, {
    method: "POST",
    headers: auth,
    body: upload,
  });
  assert.equal(posted.status, 200);
  const { path } = (await posted.json()) as { path: string };
  assert.deepEqual(new Uint8Array(readFileSync(path)), upload);

  const download = new Uint8Array(2 * 1024 * 1024 + 5).map((_, i) => (i * 7) & 0xff);
  writeFileSync(join(cwd, "down.bin"), download);
  const fetched = await fetch(`${relayUrl}/file?session=${session}&path=down.bin`, { headers: auth });
  assert.equal(fetched.status, 200);
  assert.deepEqual(new Uint8Array(await fetched.arrayBuffer()), download);
});

test("concurrent requests do not cross streams", async () => {
  const results = await Promise.all(
    Array.from({ length: 12 }, (_, i) =>
      fetch(`${relayUrl}/sessions?n=${i}`, {
        headers: { authorization: i % 2 ? `Bearer ${harness.deviceToken}` : "Bearer nope" },
      }).then((r) => r.status),
    ),
  );
  assert.deepEqual(results, Array.from({ length: 12 }, (_, i) => (i % 2 ? 200 : 401)));
});

test("the phone socket reaches the daemon and hears back", async () => {
  const ws = relayWs("/ws");
  await opened(ws);
  const welcome = new Promise<{ type: string }>((resolve) =>
    ws.once("message", (data) => resolve(JSON.parse(String(data)))),
  );
  ws.send(
    JSON.stringify({
      type: "hello",
      v: WIRE_VERSION,
      commandId: "c1",
      deviceToken: harness.deviceToken,
      clientVersion: "relay-test",
    }),
  );
  assert.equal((await welcome).type, "welcome");
  ws.close();
});

test("a phone stream is cut, not queued, while the uplink is backed up", async () => {
  // Private, and the one thing a slow uplink changes.
  const uplink = (harness.server.relay as unknown as { socket: WebSocket }).socket;
  Object.defineProperty(uplink, "bufferedAmount", { configurable: true, get: () => 64 * 1024 * 1024 });
  try {
    const ws = relayWs("/ws");
    await opened(ws);
    const heard: string[] = [];
    ws.on("message", (data) => heard.push(String(data)));
    const done = closed(ws);
    ws.send(
      JSON.stringify({
        type: "hello",
        v: WIRE_VERSION,
        commandId: "c1",
        deviceToken: harness.deviceToken,
        clientVersion: "relay-test",
      }),
    );
    const outcome = await Promise.race([
      done.then(() => "closed"),
      new Promise((resolve) => setTimeout(() => resolve("still open"), 5_000)),
    ]);
    if (outcome !== "closed") ws.terminate();
    assert.equal(outcome, "closed");
    assert.deepEqual(heard, []);
  } finally {
    delete (uplink as unknown as Record<string, unknown>).bufferedAmount;
  }
});

test("the daemon's auth close code reaches the phone unchanged", async () => {
  const ws = relayWs("/ws");
  await opened(ws);
  const done = closed(ws);
  ws.send(
    JSON.stringify({
      type: "hello",
      v: WIRE_VERSION,
      commandId: "c1",
      deviceToken: "wrong",
      clientVersion: "relay-test",
    }),
  );
  const { code } = await done;
  assert.ok(code === 4401 || code === 4403, `closed ${code}`);
});

/** Bytes a fetch client would refuse to send, straight onto the socket. */
function rawRequest(head: Buffer): Promise<string> {
  return new Promise((resolve, reject) => {
    const socket = connect(relayPort, "127.0.0.1", () => socket.write(head));
    let out = "";
    socket.on("data", (chunk) => {
      out += chunk;
      if (out.includes("\r\n\r\n")) {
        socket.destroy();
        resolve(out.split("\r\n")[0]!);
      }
    });
    socket.on("error", reject);
  });
}

test("a header only the edge accepts cannot take the daemon down", async () => {
  for (const value of [Buffer.from([0xe9]), Buffer.from("\u20ac")]) {
    const status = await rawRequest(
      Buffer.concat([
        Buffer.from("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Probe: "),
        value,
        Buffer.from("\r\nConnection: close\r\n\r\n"),
      ]),
    );
    assert.match(status, / 200 /);
  }
  assert.equal(harness.server.relay?.state, "online");
  assert.equal((await fetch(`${relayUrl}/health`)).status, 200);
});

test("an oversized body is refused before it reaches the daemon", async () => {
  const status = await rawRequest(
    Buffer.from(
      "POST /upload HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 999999999\r\n\r\n",
    ),
  );
  assert.match(status, / 413 /);
});

test("one address cannot hold more than two pending host handshakes", async () => {
  const sockets = Array.from({ length: 5 }, () => relayWs("/_pios/host"));
  await Promise.all(sockets.map(opened));
  await until(() => sockets.filter((ws) => ws.readyState === WebSocket.OPEN).length <= 2);
  for (const ws of sockets) ws.terminate();
  assert.equal(harness.server.relay?.state, "online");
});

test("an unenrolled key cannot take the host slot", async () => {
  const key = RelayKey.loadOrCreate(join(scratch, "intruder.json"));
  const intruder = new RelayConnector({
    relayUrl,
    key,
    local: { host: "127.0.0.1", port: 1 },
    log: () => {},
    rejectedRetryMs: 60_000,
  });
  intruder.start();
  await until(() => intruder.state === "rejected");
  await intruder.stop();
  assert.equal(harness.server.relay?.state, "online");
  assert.equal((await fetch(`${relayUrl}/health`)).status, 200);
});

test("a spent secret cannot enroll a second key", async () => {
  const key = RelayKey.loadOrCreate(join(scratch, "second.json"));
  await assert.rejects(enrollAtRelay(relayUrl, key, SECRET), (error: unknown) => {
    return error instanceof RelayRejectedError && error.reason === "enroll_closed";
  });
  await assert.rejects(enrollAtRelay(relayUrl, key, "x".repeat(40)), (error: unknown) => {
    return error instanceof RelayRejectedError && error.reason === "enroll_secret_invalid";
  });
});

test("host offline is reported as transient, on both kinds of request", async () => {
  await harness.server.relay!.stop();
  await until(async () => (await fetch(`${relayUrl}/health`)).status === 503);

  const response = await fetch(`${relayUrl}/sessions`);
  assert.equal(response.status, 503);
  assert.equal(response.headers.get(HOST_OFFLINE_HEADER), "host-offline");

  const ws = relayWs("/ws");
  const { code } = await closed(ws);
  assert.equal(code, HOST_OFFLINE_CLOSE_CODE);

  harness.server.relay!.start();
  await until(() => harness.server.relay?.state === "online");
});

test("an open phone socket is closed as offline when the host drops", async () => {
  const ws = relayWs("/ws");
  await opened(ws);
  const done = closed(ws);
  await harness.server.relay!.stop();
  assert.equal((await done).code, HOST_OFFLINE_CLOSE_CODE);
  harness.server.relay!.start();
  await until(() => harness.server.relay?.state === "online");
});

test("rotating the secret admits a new key, and the old host raises the alarm", async () => {
  // A second daemon identity standing in for the enrolled one, so the alarm
  // can be observed without the server's push path.
  const ownerKey = RelayKey.loadOrCreate(relayKeyPath(harness.server.config));
  let alarms = 0;
  await harness.server.relay!.stop();
  const owner = new RelayConnector({
    relayUrl,
    key: ownerKey,
    local: { host: "127.0.0.1", port: harness.server.port },
    log: () => {},
    retryBaseMs: 20,
    rejectedRetryMs: 50,
    onKeyReplaced: () => (alarms += 1),
  });
  owner.start();
  await until(() => owner.state === "online");

  // Same port and state directory; the owner reconnects on its own.
  await startRelay(ROTATED);
  await until(() => owner.state === "online", 10_000);

  const newcomer = RelayKey.loadOrCreate(join(scratch, "newcomer.json"));
  await enrollAtRelay(relayUrl, newcomer, ROTATED);

  await until(() => owner.state === "rejected");
  await until(() => alarms === 1);
  await new Promise((resolve) => setTimeout(resolve, 200));
  assert.equal(alarms, 1, "the alarm fires once, not on every retry");
  await owner.stop();
});
