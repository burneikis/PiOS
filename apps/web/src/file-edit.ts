import type { TextFile } from "@pios/protocol";
import { projectQuery, type FileAccess } from "./files.ts";
import { browserStorage } from "./storage.ts";

/** What the daemon says about a file the editor is about to show. */
export interface TreeEntry {
  name: string;
  path: string;
  dir: boolean;
}

export interface TreeListing {
  root: string;
  path: string;
  name: string;
  parent: string | null;
  entries: TreeEntry[];
}

export type SaveResult =
  | { ok: true; etag: string }
  | { ok: false; conflict: true; etag: string }
  | { ok: false; conflict: false; message: string };

function headers(access: FileAccess): Record<string, string> {
  return { authorization: `Bearer ${access.deviceToken}` };
}

function fileUrl(access: FileAccess, path: string, extra = ""): string {
  const base = `${access.baseUrl}/file?${projectQuery(access)}&path=${encodeURIComponent(path)}`;
  return extra ? `${base}&${extra}` : base;
}

export async function loadTextFile(access: FileAccess, path: string): Promise<TextFile> {
  const response = await fetch(fileUrl(access, path, "text=1"), { headers: headers(access) });
  if (!response.ok) throw new Error(response.status === 404 ? "File not found" : "Unavailable");
  return (await response.json()) as TextFile;
}

/**
 * Writes the buffer back, guarded by the etag it was loaded with.
 *
 * A conflict is not an error to retry: the agent rewrote the file, and only
 * the user can say whose version survives.
 */
export async function saveTextFile(
  access: FileAccess,
  path: string,
  text: string,
  file: TextFile,
): Promise<SaveResult> {
  const query = `eol=${file.eol}&nl=${file.trailingNewline ? "1" : "0"}`;
  const response = await fetch(fileUrl(access, path, query), {
    method: "PUT",
    headers: { ...headers(access), "if-match": file.etag, "content-type": "text/plain" },
    body: text,
  });
  const body = (await response.json().catch(() => null)) as
    | { etag?: string; error?: string }
    | null;

  if (response.ok && body?.etag) return { ok: true, etag: body.etag };
  if (response.status === 409 && body?.etag) {
    return { ok: false, conflict: true, etag: body.etag };
  }
  return { ok: false, conflict: false, message: body?.error ?? `save failed (${response.status})` };
}

export async function loadTree(access: FileAccess, path?: string): Promise<TreeListing> {
  const at = path ? `&path=${encodeURIComponent(path)}` : "";
  const response = await fetch(
    `${access.baseUrl}/dirs?${projectQuery(access)}&files=1${at}`,
    { headers: headers(access) },
  );
  if (!response.ok) throw new Error("Unavailable");
  return (await response.json()) as TreeListing;
}

export async function searchFiles(access: FileAccess, query: string): Promise<string[]> {
  const response = await fetch(
    `${access.baseUrl}/files?${projectQuery(access)}&q=${encodeURIComponent(query)}`,
    { headers: headers(access) },
  );
  if (!response.ok) throw new Error("Unavailable");
  return ((await response.json()) as { files: string[] }).files;
}

/** The file this session had open, so backgrounding the app does not lose it. */
export function rememberOpenFile(sessionId: string, path: string | null): void {
  try {
    const key = `pios.openFile.${sessionId}`;
    if (path) window.sessionStorage.setItem(key, path);
    else window.sessionStorage.removeItem(key);
  } catch {
    // Private mode. The editor still works, it just forgets.
  }
}

export function recallOpenFile(sessionId: string): string | null {
  try {
    return window.sessionStorage.getItem(`pios.openFile.${sessionId}`);
  } catch {
    return null;
  }
}

const WRAP_KEY = "pios.editor.wrap.v1";

/** Soft wrap by default: a phone is too narrow to scroll sideways through code. */
export function loadWrapLines(): boolean {
  return browserStorage.get(WRAP_KEY) !== "0";
}

export function saveWrapLines(wrap: boolean): void {
  browserStorage.set(WRAP_KEY, wrap ? "1" : "0");
}

const HIDE_DOTFILES_KEY = "pios.files.hideDotfiles.v1";

export function loadHideDotfiles(): boolean {
  return browserStorage.get(HIDE_DOTFILES_KEY) === "1";
}

export function saveHideDotfiles(hide: boolean): void {
  browserStorage.set(HIDE_DOTFILES_KEY, hide ? "1" : "0");
}

/**
 * Unsaved edits, kept on the device only.
 *
 * iOS evicts a backgrounded tab whenever it likes, and an unsaved buffer is
 * work the user typed; it outlives the tab. Nothing is ever sent to the
 * daemon until an explicit save, so a draft cannot surprise the agent.
 */
export interface DraftRecord {
  key: string;
  sessionId: string;
  path: string;
  text: string;
  /** Etag the draft was branched from, to keep the save precondition honest. */
  etag: string;
  at: number;
}

const DB_NAME = "pios-drafts";
const DB_VERSION = 1;
const STORE = "drafts";
/** Small on purpose: a draft is a rescue, not a filesystem. */
const MAX_DRAFTS = 10;

function open(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE, { keyPath: "key" });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function run<T>(mode: IDBTransactionMode, body: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  return open().then(
    (db) =>
      new Promise<T>((resolve, reject) => {
        const request = body(db.transaction(STORE, mode).objectStore(STORE));
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
      }),
  );
}

function draftKey(sessionId: string, path: string): string {
  return `${sessionId}\u0000${path}`;
}

export async function loadDraft(sessionId: string, path: string): Promise<DraftRecord | null> {
  try {
    return (await run<DraftRecord | undefined>("readonly", (s) =>
      s.get(draftKey(sessionId, path)),
    )) ?? null;
  } catch {
    return null;
  }
}

export async function saveDraft(record: Omit<DraftRecord, "key" | "at">): Promise<void> {
  try {
    const draft: DraftRecord = {
      ...record,
      key: draftKey(record.sessionId, record.path),
      at: Date.now(),
    };
    await run("readwrite", (s) => s.put(draft));
    await evict();
  } catch {
    // Quota or private mode: the buffer still lives in memory.
  }
}

export async function dropDraft(sessionId: string, path: string): Promise<void> {
  try {
    await run("readwrite", (s) => s.delete(draftKey(sessionId, path)));
  } catch {
    /* nothing to drop */
  }
}

async function evict(): Promise<void> {
  const all = await run<DraftRecord[]>("readonly", (s) => s.getAll());
  const stale = all.sort((a, b) => b.at - a.at).slice(MAX_DRAFTS);
  await Promise.all(stale.map((d) => dropDraft(d.sessionId, d.path)));
}
