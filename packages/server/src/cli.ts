#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { AuthStore } from "./auth.ts";
import { authStorePath, defaultConfig, pushStorePath, relayKeyPath } from "./config.ts";
import { PushStore } from "./push.ts";
import { advertisedEndpoint } from "./endpoints.ts";
import { enrollAtRelay, RelayRejectedError } from "./relay-connector.ts";
import { RelayKey } from "./relay-key.ts";
import { PiosServer } from "./server.ts";

const [command = "serve", ...rest] = process.argv.slice(2);
const port = Number(process.env.PIOS_PORT ?? 4111);

switch (command) {
  case "serve":
    await serve();
    break;
  case "pair":
    pair();
    break;
  case "devices":
    devices();
    break;
  case "revoke":
    revoke(rest[0]);
    break;
  case "relay":
    await relay(rest[0]);
    break;
  default:
    console.error(
      `usage: pios-server [serve|pair|devices|revoke <deviceId>|--all|relay enroll|relay key]`,
    );
    process.exit(2);
}

async function serve(): Promise<void> {
  const server = new PiosServer({ port, piVersion: piVersion() });
  await server.listen();

  console.log(
    `pios-server listening on ${server.config.host}:${server.port} (${server.config.sessionHostMode})`,
  );
  const endpoint = server.endpoint();
  console.log(`  ${endpoint.key.padEnd(28)} ${endpoint.url}`);

  const shutdown = async () => {
    await server.close();
    process.exit(0);
  };
  process.on("SIGINT", () => void shutdown());
  process.on("SIGTERM", () => void shutdown());
}

function pair(): void {
  const config = defaultConfig({ port });
  const auth = new AuthStore(authStorePath(config));
  const { token, code, expiresAt } = auth.createPairing();

  const endpoint = advertisedEndpoint(port, config.relayUrl, config.publicUrl);

  // The token goes in the fragment: a fragment is never sent to a server and
  // never lands in an access log or a Referer header. The client strips it
  // from history after exchanging it.
  console.log(`\nPair this device within 10 minutes:\n`);
  console.log(`  ${endpoint.url}/#pt=${token}`);
  console.log(`\n  confirmation code: ${code}`);
  console.log(`  expires: ${new Date(expiresAt).toLocaleTimeString()}\n`);
  console.log(`  endpoint key: ${endpoint.key}\n`);
  if (endpoint.kind === "local") {
    console.log("  Neither PIOS_RELAY_URL nor PIOS_PUBLIC_URL is set, so this link only works on this machine.\n");
  }
}

function devices(): void {
  const auth = new AuthStore(authStorePath(defaultConfig({ port })));
  const list = auth.listDevices();
  if (list.length === 0) return console.log("no paired devices");
  console.table(
    list.map((d) => ({
      id: d.id,
      label: d.label,
      paired: new Date(d.createdAt).toISOString(),
      lastSeen: new Date(d.lastSeenAt).toISOString(),
    })),
  );
}

function revoke(deviceId: string | undefined): void {
  if (!deviceId) {
    console.error("usage: pios-server revoke <deviceId>|--all");
    process.exit(2);
  }
  const config = defaultConfig({ port });
  const auth = new AuthStore(authStorePath(config));
  // A revoked device must also stop being reachable by push: the endpoint is a
  // capability that outlives the token otherwise.
  const push = new PushStore(pushStorePath(config), config.pushSubject);

  if (deviceId === "--all") {
    const ids = auth.revokeAll();
    for (const id of ids) push.removeDevice(id);
    console.log(ids.length === 0 ? "no paired devices" : `revoked ${ids.length} device(s)`);
    return;
  }

  push.removeDevice(deviceId);
  console.log(auth.revoke(deviceId) ? `revoked ${deviceId}` : `no device ${deviceId}`);
}

async function relay(subcommand: string | undefined): Promise<void> {
  const config = defaultConfig({ port });
  const key = RelayKey.loadOrCreate(relayKeyPath(config));
  if (subcommand === "key") {
    console.log(`public key:  ${key.publicKey}`);
    console.log(`fingerprint: ${fingerprint(key.publicKey)}`);
    return;
  }
  if (subcommand !== "enroll") {
    console.error("usage: pios-server relay enroll|key");
    process.exit(2);
  }
  if (!config.relayUrl) {
    console.error("set PIOS_RELAY_URL to the relay's https URL first");
    process.exit(2);
  }

  // Read from stdin, never argv: arguments land in shell history and in the
  // process list, and this secret decides who holds the relay.
  const secret = (await readSecret("Paste ENROLL_SECRET, then Enter: ")).trim();
  if (!secret) {
    console.error("no secret given");
    process.exit(2);
  }
  try {
    await enrollAtRelay(config.relayUrl, key, secret);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    if (error instanceof RelayRejectedError) console.error(enrollHint(error.reason));
    process.exit(1);
  }
  console.log(`enrolled at ${config.relayUrl}`);
  console.log(`fingerprint: ${fingerprint(key.publicKey)}`);
  console.log("The secret is now spent. Restart the daemon if it is not already connected.");
}

function enrollHint(reason: string): string {
  switch (reason) {
    case "enroll_closed":
      return "The relay has no usable ENROLL_SECRET, or it already enrolled another key with it. Set a new one with `wrangler secret put ENROLL_SECRET`.";
    case "enroll_secret_invalid":
      return "That secret does not match the relay's ENROLL_SECRET.";
    case "version_mismatch":
      return "The relay and this daemon speak different protocol versions; redeploy the relay.";
    case "host_record_unreadable":
      return "The relay holds a host record it cannot read, so it admits no host. Redeploy a relay version that can migrate it.";
    default:
      return "";
  }
}

function fingerprint(publicKey: string): string {
  const digest = createHash("sha256").update(publicKey).digest("hex").slice(0, 16);
  return digest.match(/.{4}/g)!.join(":");
}

function readSecret(prompt: string): Promise<string> {
  const stdin = process.stdin;
  if (!stdin.isTTY) {
    return new Promise((resolve, reject) => {
      let text = "";
      stdin.setEncoding("utf8");
      stdin.on("data", (chunk: string) => (text += chunk));
      stdin.on("end", () => resolve(text));
      stdin.on("error", reject);
    });
  }
  process.stdout.write(prompt);
  return new Promise((resolve) => {
    let text = "";
    stdin.setRawMode(true);
    stdin.setEncoding("utf8");
    const onData = (chunk: string) => {
      for (const char of chunk) {
        if (char === "\u0003") {
          stdin.setRawMode(false);
          process.stdout.write("\n");
          process.exit(130);
        }
        if (char === "\r" || char === "\n") {
          stdin.setRawMode(false);
          stdin.off("data", onData);
          stdin.pause();
          process.stdout.write("\n");
          resolve(text);
          return;
        }
        if (char === "\u007f") text = text.slice(0, -1);
        else text += char;
      }
    };
    stdin.on("data", onData);
    stdin.resume();
  });
}

function piVersion(): string {
  try {
    return execFileSync("pi", ["--version"], { encoding: "utf8" }).trim();
  } catch {
    return "unavailable";
  }
}
