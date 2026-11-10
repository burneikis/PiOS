import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

export interface ServerConfig {
  /**
   * Loopback by default: the relay is the only remote path, and it reaches
   * the daemon through a connector on this same machine.
   */
  host: string;
  port: number;
  dataDir: string;
  /**
   * Where pi session JSONL lives. Defaults to pi's own directory so the TUI
   * and PiOS see one set of sessions and can resume each other's work.
   */
  sessionDir: string;
  /** pi's own config directory, which holds the project-trust decisions. */
  agentDir: string;
  /**
   * Plan usage cache, shared with the pi status bar extension so that
   * together they stay under the usage endpoint's rate limit.
   */
  usageCachePath: string;
  /**
   * How sessions run: `subprocess` spawns `pi --mode rpc` per session,
   * `in-process` drives an `AgentSession` inside the daemon.
   */
  sessionHostMode: SessionHostMode;
  /**
   * Idle time before a session's `pi` process is stopped. The session itself
   * survives: its transcript is on disk and the next command starts it again.
   */
  sessionIdleMs: number;
  /** Cap on a single upload, so a phone cannot fill the disk. */
  maxUploadBytes: number;
  /** How long a socket has to authenticate before it is closed. */
  helloTimeoutMs: number;
  /**
   * How long an activity report stands for. Longer than the client's 25s
   * report interval, so one dropped report does not cost a notification.
   */
  activityTtlMs: number;
  /** `mailto:` or `https:` identity sent to push services in the VAPID JWT. */
  pushSubject: string;
  /**
   * Built PWA served by the daemon, or null to serve no app at all.
   *
   * Same origin as the API on purpose: a service worker, Web Push, and an
   * installable home-screen app all need one secure origin, and one origin
   * also means no CORS and no endpoint picker guessing a second port.
   */
  webDir: string | null;
  /**
   * The relay the daemon dials out to, and the origin a phone uses. Null
   * means local only: a browser on this machine, the sandbox, development.
   */
  relayUrl: string | null;
  /**
   * An https reverse proxy in front of the loopback daemon, e.g.
   * `tailscale serve`. Only changes what `pair` prints; the app remembers
   * whatever origin it was opened from.
   */
  publicUrl: string | null;
}

export type SessionHostMode = "subprocess" | "in-process";

export const SERVER_VERSION = "0.0.0";

/**
 * Fallback VAPID subject.
 *
 * Push services validate it: Apple rejects a JWT whose subject is a `mailto:`
 * at an unresolvable domain (`BadJwtToken`), which is what any `localhost`
 * default would produce. A real https URL is accepted everywhere.
 */
const DEFAULT_PUSH_SUBJECT = "https://github.com/earendil-works/pi";

export function defaultConfig(overrides: Partial<ServerConfig> = {}): ServerConfig {
  // Env override so a second daemon can run against a scratch dir without
  // faking HOME, which would also hide pi's own credentials from it.
  const dataDir = overrides.dataDir ?? process.env.PIOS_DATA_DIR ?? join(homedir(), ".pios");
  const relayUrl = checkRelayUrl(
    normalizeUrl(
      overrides.relayUrl !== undefined ? overrides.relayUrl : (process.env.PIOS_RELAY_URL ?? null),
    ),
  );
  const publicUrl = checkPublicUrl(
    normalizeUrl(
      overrides.publicUrl !== undefined ? overrides.publicUrl : (process.env.PIOS_PUBLIC_URL ?? null),
    ),
  );
  // One route per daemon: a second origin is a second install and pairing on
  // the phone, and the pairing link could only ever name one of them.
  if (relayUrl && publicUrl) throw new Error("set PIOS_RELAY_URL or PIOS_PUBLIC_URL, not both");
  return {
    host: overrides.host ?? process.env.PIOS_BIND ?? "127.0.0.1",
    port: overrides.port ?? 4111,
    dataDir,
    sessionDir:
      overrides.sessionDir ??
      process.env.PIOS_SESSION_DIR ??
      join(homedir(), ".pi", "agent", "sessions"),
    agentDir: overrides.agentDir ?? process.env.PI_AGENT_DIR ?? join(homedir(), ".pi", "agent"),
    usageCachePath:
      overrides.usageCachePath ?? join(homedir(), ".claude", ".pi-usage-cache.json"),
    sessionHostMode: overrides.sessionHostMode ?? sessionHostMode(process.env.PIOS_HOST),
    sessionIdleMs: overrides.sessionIdleMs ?? 30 * 60_000,
    maxUploadBytes: overrides.maxUploadBytes ?? 25 * 1024 * 1024,
    helloTimeoutMs: overrides.helloTimeoutMs ?? 5_000,
    activityTtlMs: overrides.activityTtlMs ?? 45_000,
    webDir: overrides.webDir !== undefined ? overrides.webDir : defaultWebDir(),
    relayUrl,
    publicUrl,
    // The relay's https origin identifies this daemon better than a generic
    // URL, and is the one address the operator already knows is real.
    pushSubject:
      overrides.pushSubject ??
      process.env.PIOS_PUSH_SUBJECT ??
      (relayUrl?.startsWith("https://") ? relayUrl : (publicUrl ?? DEFAULT_PUSH_SUBJECT)),
  };
}

/**
 * A crash in one session must not take the daemon and every other session
 * with it, so anything but an explicit opt-in runs pi as a child process.
 */
function sessionHostMode(requested: string | undefined): SessionHostMode {
  return requested === "in-process" ? "in-process" : "subprocess";
}

/** The workspace build output, when the daemon is running from the repo. */
function defaultWebDir(): string | null {
  if (process.env.PIOS_WEB_DIR) return process.env.PIOS_WEB_DIR;
  const candidate = fileURLToPath(new URL("../../../apps/web/dist", import.meta.url));
  return existsSync(join(candidate, "index.html")) ? candidate : null;
}

export function pushStorePath(config: ServerConfig): string {
  return join(config.dataDir, "push.json");
}

export function relayKeyPath(config: ServerConfig): string {
  return join(config.dataDir, "relay-key.json");
}

/**
 * The enrollment secret and every device token cross this link, so plain
 * http is refused anywhere but loopback, where a local `wrangler dev` lives.
 */
function checkRelayUrl(url: string | null): string | null {
  if (!url) return null;
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new Error(`PIOS_RELAY_URL is not a URL: ${url}`);
  }
  if (parsed.protocol === "https:") return url;
  const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(parsed.hostname);
  if (parsed.protocol === "http:" && loopback) return url;
  throw new Error(`PIOS_RELAY_URL must be https:// (got ${url})`);
}

// iOS only installs the app and delivers push from a secure origin.
function checkPublicUrl(url: string | null): string | null {
  if (!url) return null;
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new Error(`PIOS_PUBLIC_URL is not a URL: ${url}`);
  }
  if (parsed.protocol !== "https:") throw new Error(`PIOS_PUBLIC_URL must be https:// (got ${url})`);
  return url;
}

function normalizeUrl(url: string | null): string | null {
  const trimmed = url?.trim().replace(/\/+$/, "");
  return trimmed ? trimmed : null;
}

export function authStorePath(config: ServerConfig): string {
  return join(config.dataDir, "auth.json");
}
