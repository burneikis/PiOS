import assert from "node:assert/strict";
import { test } from "node:test";
import { defaultConfig } from "../src/config.ts";

test("sessions run as child processes unless in-process is asked for by name", () => {
  assert.equal(defaultConfig().sessionHostMode, "subprocess");
  assert.equal(withEnv("PIOS_HOST", "inprocess").sessionHostMode, "subprocess");
  assert.equal(withEnv("PIOS_HOST", "in-process").sessionHostMode, "in-process");
});

test("an explicit host mode wins over the environment", () => {
  const previous = process.env.PIOS_HOST;
  process.env.PIOS_HOST = "in-process";
  try {
    assert.equal(defaultConfig({ sessionHostMode: "subprocess" }).sessionHostMode, "subprocess");
  } finally {
    restore("PIOS_HOST", previous);
  }
});

test("terminals are reaped after twelve idle hours unless configured", () => {
  assert.equal(defaultConfig().terminalIdleMs, 12 * 60 * 60_000);
  assert.equal(withEnv("PIOS_TERMINAL_IDLE_MINUTES", "30").terminalIdleMs, 30 * 60_000);
  assert.equal(withEnv("PIOS_TERMINAL_IDLE_MINUTES", "0").terminalIdleMs, 0);
  assert.equal(withEnv("PIOS_TERMINAL_IDLE_MINUTES", "soon").terminalIdleMs, 12 * 60 * 60_000);
});

test("the daemon binds loopback unless told otherwise", () => {
  assert.equal(defaultConfig().host, "127.0.0.1");
  assert.equal(withEnv("PIOS_BIND", "0.0.0.0").host, "0.0.0.0");
});

test("an explicit null relay wins over the environment", () => {
  assert.equal(withEnv("PIOS_RELAY_URL", "https://r.example/").relayUrl, "https://r.example");
  const previous = process.env.PIOS_RELAY_URL;
  process.env.PIOS_RELAY_URL = "https://r.example";
  try {
    assert.equal(defaultConfig({ relayUrl: null }).relayUrl, null);
  } finally {
    restore("PIOS_RELAY_URL", previous);
  }
});

test("a relay URL must be https, except on loopback", () => {
  assert.equal(defaultConfig({ relayUrl: "http://127.0.0.1:8787" }).relayUrl, "http://127.0.0.1:8787");
  assert.equal(defaultConfig({ relayUrl: "http://localhost:8787/" }).relayUrl, "http://localhost:8787");
  assert.throws(() => defaultConfig({ relayUrl: "http://relay.example" }), /https/);
  assert.throws(() => defaultConfig({ relayUrl: "ws://relay.example" }), /https/);
  assert.throws(() => defaultConfig({ relayUrl: "not a url" }), /not a URL/);
});

function withEnv(name: string, value: string) {
  const previous = process.env[name];
  process.env[name] = value;
  try {
    return defaultConfig();
  } finally {
    restore(name, previous);
  }
}

function restore(name: string, previous: string | undefined): void {
  if (previous === undefined) delete process.env[name];
  else process.env[name] = previous;
}

test("relay and public url together are refused", () => {
  assert.throws(
    () => defaultConfig({ relayUrl: "https://r.example", publicUrl: "https://box.tail1.ts.net" }),
    /not both/,
  );
});
