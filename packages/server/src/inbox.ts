import { randomBytes } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import type { PushMessage } from "./push.ts";
import { writePrivateJson } from "./private-file.ts";

/**
 * Settle notifications for devices that cannot receive a real push.
 *
 * The native app is sideloaded, and a free signature cannot carry the APNs
 * entitlement, so nothing can wake it. Instead it opts in here and collects
 * what it missed whenever it next reaches the daemon: live while its socket
 * is open, on reconnect, or from a background refresh the OS grants it.
 *
 * An item stays until the device acknowledges it, so a socket that dies
 * between send and display loses nothing; the device dedupes on the id.
 * The file is 0600: the bodies are the agent's own words.
 */

const STORE_VERSION = 1;
/** Older than this, a turn's outcome is history, not news. */
const MAX_AGE_MS = 24 * 60 * 60 * 1000;
/** Per device. One per session already, so this is many sessions' worth. */
const MAX_PENDING = 30;

export interface InboxItem {
  id: string;
  sessionId: string;
  title: string;
  body: string;
  /** One per session: a later settle replaces an unread earlier one. */
  tag: string;
  at: number;
}

interface DeviceInbox {
  pending: InboxItem[];
}

interface StoreFile {
  version: number;
  devices: Record<string, DeviceInbox>;
}

export class NotificationInbox {
  private readonly path: string;
  private data: StoreFile;
  private mtimeMs = 0;

  constructor(path: string) {
    this.path = path;
    this.data = load(path);
    this.mtimeMs = mtimeOf(path);
  }

  enabled(deviceId: string): boolean {
    this.refresh();
    return deviceId in this.data.devices;
  }

  /** Turning it off drops what was waiting: nobody asked for it any more. */
  setEnabled(deviceId: string, enabled: boolean): void {
    this.refresh();
    if (enabled === deviceId in this.data.devices) return;
    if (enabled) this.data.devices[deviceId] = { pending: [] };
    else delete this.data.devices[deviceId];
    this.persist();
  }

  /** Devices that opted in, minus the ones given. */
  recipients(skip: ReadonlySet<string> = new Set()): string[] {
    this.refresh();
    return Object.keys(this.data.devices).filter((id) => !skip.has(id));
  }

  /** Queues one notification per recipient and returns them, for live delivery. */
  add(
    sessionId: string,
    message: PushMessage,
    deviceIds: readonly string[],
    now = Date.now(),
  ): Map<string, InboxItem> {
    this.refresh();
    const added = new Map<string, InboxItem>();
    for (const deviceId of deviceIds) {
      const inbox = this.data.devices[deviceId];
      if (!inbox) continue;
      const item: InboxItem = {
        id: randomBytes(8).toString("hex"),
        sessionId,
        title: message.title,
        body: message.body,
        tag: message.tag,
        at: now,
      };
      inbox.pending = fresh(inbox.pending, now)
        .filter((p) => p.tag !== item.tag)
        .concat(item)
        .slice(-MAX_PENDING);
      added.set(deviceId, item);
    }
    if (added.size > 0) this.persist();
    return added;
  }

  pending(deviceId: string, now = Date.now()): InboxItem[] {
    this.refresh();
    const inbox = this.data.devices[deviceId];
    return inbox ? fresh(inbox.pending, now) : [];
  }

  acknowledge(deviceId: string, ids: readonly string[]): void {
    this.refresh();
    const inbox = this.data.devices[deviceId];
    if (!inbox) return;
    const gone = new Set(ids);
    const kept = inbox.pending.filter((p) => !gone.has(p.id));
    if (kept.length === inbox.pending.length) return;
    inbox.pending = kept;
    this.persist();
  }

  /** Called when the device is revoked. */
  removeDevice(deviceId: string): void {
    this.setEnabled(deviceId, false);
  }

  /** `pios-server revoke` runs as its own process while the daemon holds this. */
  private refresh(): void {
    const mtime = mtimeOf(this.path);
    if (mtime === this.mtimeMs) return;
    this.data = load(this.path);
    this.mtimeMs = mtime;
  }

  private persist(): void {
    writePrivateJson(this.path, this.data);
    this.mtimeMs = mtimeOf(this.path);
  }
}

function fresh(items: InboxItem[], now: number): InboxItem[] {
  return items.filter((item) => now - item.at < MAX_AGE_MS);
}

function mtimeOf(path: string): number {
  try {
    return statSync(path).mtimeMs;
  } catch {
    return 0;
  }
}

function load(path: string): StoreFile {
  const empty: StoreFile = { version: STORE_VERSION, devices: {} };
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as StoreFile;
    if (parsed.version !== STORE_VERSION) {
      throw new Error(`unsupported notification inbox version ${parsed.version}`);
    }
    return { version: STORE_VERSION, devices: parsed.devices ?? {} };
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ENOENT" || error instanceof SyntaxError) return empty;
    throw error;
  }
}
