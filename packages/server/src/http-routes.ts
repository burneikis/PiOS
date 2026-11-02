import { createReadStream, readFileSync, statSync, type Dirent } from "node:fs";
import { readdir, stat } from "node:fs/promises";
import type { IncomingMessage, ServerResponse } from "node:http";
import { homedir } from "node:os";
import { basename, dirname, extname, join, relative, sep } from "node:path";
import { sessionDirName, type SessionIndex, type SessionRegistry } from "@pios/pi-host";
import { WIRE_VERSION } from "@pios/protocol";
import { AuthStore, bearerToken } from "./auth.ts";
import { gitBranches, gitDiff, gitLog, gitStashes, gitStatus, GitError } from "./git.ts";
import { gitAction, parseGitAction } from "./git-actions.ts";
import { invalidateFileIndex, searchFiles } from "./file-index.ts";
import { MAX_EDIT_BYTES, readTextFile, writeTextFile } from "./file-edit.ts";
import { containedPath } from "./paths.ts";
import { prepareUploadDir, receiveUpload } from "./uploads.ts";
import { IMAGE_CONTENT_TYPES, type ImageStore } from "./image-store.ts";
import type { PushStore } from "./push.ts";
import { SERVER_VERSION, type ServerConfig } from "./config.ts";
import type { ClaudeUsage } from "./usage.ts";

const CONTENT_TYPES: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".svg": "image/svg+xml",
  ".pdf": "application/pdf",
  ".json": "application/json",
  ".md": "text/markdown; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".webmanifest": "application/manifest+json",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
};

/** Pairing and push bodies: a token or a subscription, never more. */
const SMALL_BODY_BYTES = 8 * 1024;
/** Path lists and commit messages: generous, but bounded. */
const GIT_ACTION_BYTES = 64 * 1024;

/** Everything the daemon answers itself; the rest may be the PWA. */
const API_PATHS = new Set([
  // A GET that never upgraded must not be answered with the app shell: a
  // client would parse HTML as a socket failure it cannot explain.
  "/ws",
  "/pair",
  "/health",
  "/sessions",
  "/dirs",
  "/file",
  "/files",
  "/image",
  "/upload",
  "/push/key",
  "/push/subscribe",
  "/push/unsubscribe",
  "/usage",
  "/git/status",
  "/git/diff",
  "/git/log",
  "/git/branches",
  "/git/stashes",
  "/git/action",
]);

export interface RouteContext {
  config: ServerConfig;
  auth: AuthStore;
  registry: SessionRegistry;
  /** Sessions on disk, so a session with no process still has a directory. */
  index: SessionIndex;
  push: PushStore;
  images: ImageStore;
  usage: ClaudeUsage;
}

/**
 * The project directory a request is about.
 *
 * A session's own, whether or not pi is running for it: the transcript can
 * show a cold session's images and its git state without waking anything.
 * A draft has no session yet, only the directory it was started in, so it
 * sends that instead, contained to home like the directory picker.
 */
async function projectRoot(ctx: RouteContext, url: URL): Promise<string | null> {
  const sessionId = url.searchParams.get("session");
  const cwd = url.searchParams.get("cwd");
  if (sessionId) {
    const known = ctx.registry.get(sessionId)?.info.cwd || ctx.index.recordFor(sessionId)?.cwd;
    if (known) return known;
    // A full scan is only worth it when there is nothing else to go on.
    if (!cwd) return (await ctx.index.find(sessionId))?.cwd || null;
  }
  return cwd ? containedPath(homedir(), cwd) : null;
}

/** Whether the request names a project at all, as opposed to the home picker. */
function namesProject(url: URL): boolean {
  return url.searchParams.has("session") || url.searchParams.has("cwd");
}

export async function handleRequest(
  ctx: RouteContext,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const url = new URL(req.url ?? "/", "http://localhost");
  cors(req, res);

  try {
    // The preflight carries no credentials, so it cannot be authenticated and
    // must be answered before the auth check.
    if (req.method === "OPTIONS") {
      res.writeHead(204).end();
      return;
    }
    // Unauthenticated by necessity: this is how a device gets its first token.
    if (req.method === "POST" && url.pathname === "/pair") return await pair(ctx, req, res);
    // Deliberately says nothing about sessions, paths, or devices.
    if (req.method === "GET" && url.pathname === "/health") {
      return json(res, 200, { ok: true, serverVersion: SERVER_VERSION, wireVersion: WIRE_VERSION });
    }

    // The app shell itself is public: a browser cannot put a bearer token on
    // the document request that bootstraps it, and the bundle holds no
    // secrets. Everything it then asks for is authenticated.
    if (req.method === "GET" && !API_PATHS.has(url.pathname) && ctx.config.webDir) {
      return serveApp(ctx.config.webDir, url, res);
    }

    const device = ctx.auth.verify(bearerToken(req.headers.authorization));
    if (!device) return json(res, 401, { error: "unauthorized" });

    if (req.method === "GET" && url.pathname === "/sessions") {
      return json(res, 200, { sessions: ctx.registry.list() });
    }
    // The VAPID public key is a public value by design: it identifies the
    // sender to the push service and authorises nothing on its own.
    if (req.method === "GET" && url.pathname === "/push/key") {
      return json(res, 200, { publicKey: ctx.push.publicKey });
    }
    if (req.method === "POST" && url.pathname === "/push/subscribe") {
      return await pushSubscribe(ctx, device.id, req, res);
    }
    if (req.method === "POST" && url.pathname === "/push/unsubscribe") {
      const body = await readJson(req, SMALL_BODY_BYTES);
      const endpoint = typeof body?.endpoint === "string" ? body.endpoint : undefined;
      if (!endpoint) return json(res, 400, { error: "bad_request" });
      return json(res, 200, { removed: ctx.push.unsubscribe(endpoint) });
    }
    if (req.method === "GET" && url.pathname === "/usage") {
      const usage = await ctx.usage.get();
      return json(res, 200, { usage });
    }
    if (req.method === "GET" && url.pathname === "/dirs") return await listDirs(ctx, url, res);
    if (req.method === "GET" && url.pathname === "/file") {
      if (url.searchParams.get("text") === "1") return await serveFileText(ctx, url, res);
      return await serveFile(ctx, url, res);
    }
    if (req.method === "PUT" && url.pathname === "/file") return await saveFile(ctx, url, req, res);
    if (req.method === "GET" && url.pathname === "/files") return await findFiles(ctx, url, res);
    if (req.method === "GET" && url.pathname === "/image") return serveImage(ctx, url, res);
    if (req.method === "POST" && url.pathname === "/upload") {
      return await upload(ctx, url, req, res);
    }
    if (url.pathname.startsWith("/git/")) return await gitRoute(ctx, url, req, res);
    return json(res, 404, { error: "not_found" });
  } catch (error) {
    console.error("[pios] request failed", error);
    json(res, 500, { error: "internal" });
  }
}

/**
 * Static file serving for the built PWA.
 *
 * Unknown paths fall back to `index.html` so a deep link like
 * `/?session=...` from a notification survives a cold launch. Content-hashed
 * assets are immutable; the document and the service worker never are, or a
 * new build would never reach an installed app.
 */
function serveApp(webDir: string, url: URL, res: ServerResponse): void {
  const requested = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
  const candidate = containedPath(webDir, requested);
  const path =
    candidate && statSync(candidate, { throwIfNoEntry: false })?.isFile()
      ? candidate
      : join(webDir, "index.html");

  let stat;
  try {
    stat = statSync(path);
  } catch {
    return json(res, 404, { error: "not_found" });
  }

  const immutable = path.includes(`${sep}assets${sep}`);
  res.writeHead(200, {
    "content-type": CONTENT_TYPES[extname(path).toLowerCase()] ?? "application/octet-stream",
    "content-length": stat.size,
    "cache-control": immutable ? "public, max-age=31536000, immutable" : "no-cache",
  });
  createReadStream(path).pipe(res);
}

async function pair(ctx: RouteContext, req: IncomingMessage, res: ServerResponse): Promise<void> {
  const body = await readJson(req, SMALL_BODY_BYTES);
  const token = typeof body?.pairingToken === "string" ? body.pairingToken : undefined;
  const label = typeof body?.label === "string" ? body.label.slice(0, 64) : "unnamed device";
  if (!token) return json(res, 400, { error: "bad_request" });

  const result = ctx.auth.redeemPairing(token, label);
  // One response for a bad token and an expired one: an attacker learns
  // nothing about which pairing codes ever existed.
  if (!result) return json(res, 401, { error: "invalid_pairing_token" });

  json(res, 200, {
    deviceToken: result.deviceToken,
    deviceId: result.device.id,
    serverVersion: SERVER_VERSION,
    wireVersion: WIRE_VERSION,
  });
}

/**
 * Registers a Web Push subscription against the calling device.
 *
 * Only the endpoint and the two client keys are stored: the daemon is the
 * sender, so it needs nothing else, and holding less means a leaked file wakes
 * fewer phones.
 */
async function pushSubscribe(
  ctx: RouteContext,
  deviceId: string,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const body = await readJson(req, SMALL_BODY_BYTES);
  const endpoint = typeof body?.endpoint === "string" ? body.endpoint : undefined;
  const keys = body?.keys as { p256dh?: unknown; auth?: unknown } | undefined;
  const p256dh = typeof keys?.p256dh === "string" ? keys.p256dh : undefined;
  const auth = typeof keys?.auth === "string" ? keys.auth : undefined;
  if (!endpoint || !p256dh || !auth || !/^https:\/\//.test(endpoint)) {
    return json(res, 400, { error: "bad_request" });
  }

  const record = ctx.push.subscribe(deviceId, { endpoint, keys: { p256dh, auth } });
  json(res, 200, { id: record.id });
}

/**
 * Directory listing for the session-creation picker.
 *
 * Rooted at the home directory: the daemon already runs arbitrary code as the
 * user, but browsing the whole filesystem from a phone is a bigger surface
 * than the feature needs, and `/` is never where a project lives.
 *
 * Ordered by the most recent pi session at or below each entry, then by name:
 * the directory someone wants next is nearly always one they worked in.
 */
async function listDirs(ctx: RouteContext, url: URL, res: ServerResponse): Promise<void> {
  // Project mode roots the browse at the project and includes files: it
  // answers "what is in this project", not "where do I start a session".
  const project = namesProject(url);
  const root = project ? await projectRoot(ctx, url) : homedir();
  if (!root) return json(res, 404, { error: "unknown_session" });
  const withFiles = project && url.searchParams.get("files") === "1";

  const requested = url.searchParams.get("path") ?? root;
  const path = containedPath(root, requested);
  if (!path) return json(res, 404, { error: "not_found" });

  let dirents;
  try {
    dirents = await readdir(path, { withFileTypes: true });
  } catch {
    return json(res, 404, { error: "not_found" });
  }

  if (withFiles) return json(res, 200, treeListing(root, path, dirents));

  const recency = await sessionRecency(ctx.config.sessionDir);
  const entries = dirents
    .filter((d) => d.isDirectory() && !d.name.startsWith("."))
    .map((d) => {
      const child = join(path, d.name);
      return { name: d.name, path: child, lastSessionAt: lastSessionAt(recency, child) };
    })
    .sort((a, b) => (b.lastSessionAt ?? 0) - (a.lastSessionAt ?? 0) || a.name.localeCompare(b.name));

  json(res, 200, directoryListing(root, path, entries));
}

/** Session directory name -> last write, for every project pi knows about. */
async function sessionRecency(sessionDir: string): Promise<Map<string, number>> {
  const found = new Map<string, number>();
  let dirents;
  try {
    dirents = await readdir(sessionDir, { withFileTypes: true });
  } catch {
    return found;
  }
  await Promise.all(
    dirents
      .filter((d) => d.isDirectory())
      .map(async (d) => {
        try {
          found.set(d.name, (await stat(join(sessionDir, d.name))).mtimeMs);
        } catch {
          // A directory that vanished mid-listing simply has no recency.
        }
      }),
  );
  return found;
}

/**
 * Newest session in the subtree, so a parent like `~/Code` sorts by the work
 * inside it. pi's name encoding is lossy, so a sibling whose name starts with
 * this one plus `-` can bleed in; that only ever perturbs the ordering.
 */
function lastSessionAt(recency: Map<string, number>, cwd: string): number | null {
  const key = sessionDirName(cwd);
  const subtree = key.slice(0, -2) + "-";
  let newest = 0;
  for (const [name, mtime] of recency) {
    if (name === key || name.startsWith(subtree)) newest = Math.max(newest, mtime);
  }
  return newest || null;
}

/**
 * Git state for a session's working directory.
 *
 * Ambient state of the cwd, not conversation state, so it is served here
 * rather than injected into the entry stream, where non-entry data would break
 * the cursor. Remote operations run non-interactively, so a missing credential
 * fails with a message instead of blocking on a prompt no one can answer.
 */
async function gitRoute(
  ctx: RouteContext,
  url: URL,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const cwd = await projectRoot(ctx, url);
  if (!cwd) return json(res, 404, { error: "not_found" });

  try {
    if (req.method === "GET" && url.pathname === "/git/status") {
      const status = await gitStatus(cwd, { fresh: url.searchParams.get("fresh") === "1" });
      // A cwd that is not a repository is a normal answer, not an error: the
      // client says so rather than hiding, because `init` is the fix.
      return json(res, 200, { status });
    }
    if (req.method === "GET" && url.pathname === "/git/diff") {
      const result = await gitDiff(cwd, {
        path: url.searchParams.get("path") ?? undefined,
        staged: url.searchParams.get("staged") === "1",
        commit: url.searchParams.get("commit") ?? undefined,
        stash: url.searchParams.get("stash") ?? undefined,
      });
      return json(res, 200, result ?? { diff: null });
    }
    if (req.method === "GET" && url.pathname === "/git/log") {
      const limit = Number(url.searchParams.get("limit") ?? 30);
      const skip = Number(url.searchParams.get("skip") ?? 0);
      const commits = await gitLog(cwd, {
        limit: Number.isFinite(limit) ? limit : 30,
        skip: Number.isFinite(skip) ? skip : 0,
        ref: url.searchParams.get("ref") ?? undefined,
      });
      return json(res, 200, { commits });
    }
    if (req.method === "GET" && url.pathname === "/git/branches") {
      return json(res, 200, { branches: await gitBranches(cwd) });
    }
    if (req.method === "GET" && url.pathname === "/git/stashes") {
      return json(res, 200, { stashes: await gitStashes(cwd) });
    }
    if (req.method === "POST" && url.pathname === "/git/action") {
      const action = parseGitAction(await readJson(req, GIT_ACTION_BYTES));
      if (!action) return json(res, 400, { error: "bad_request" });
      // The recomputed status rides back on the response so the client never
      // needs a follow-up round trip to redraw.
      const result = await gitAction(cwd, action);
      return json(res, 200, { status: result?.status ?? null, output: result?.output ?? "" });
    }
  } catch (error) {
    if (error instanceof GitError) return json(res, 422, { error: "git_failed", message: error.message });
    throw error;
  }
  return json(res, 404, { error: "not_found" });
}

/**
 * Fuzzy file search inside a session's cwd, for the composer's `@` picker.
 *
 * Scoped to the session rather than to home: what is being completed is an
 * argument the agent will read, and the agent works in one directory.
 */
async function findFiles(ctx: RouteContext, url: URL, res: ServerResponse): Promise<void> {
  const root = await projectRoot(ctx, url);
  if (!root) return json(res, 404, { error: "unknown_session" });

  const limit = Number(url.searchParams.get("limit") ?? 30);
  const files = await searchFiles(
    root,
    url.searchParams.get("q") ?? "",
    Number.isFinite(limit) ? Math.min(Math.max(limit, 1), 100) : 30,
  );
  json(res, 200, { cwd: root, files: files.map((match) => match.path) });
}

async function serveFile(ctx: RouteContext, url: URL, res: ServerResponse): Promise<void> {
  if (!namesProject(url) || !url.searchParams.get("path")) {
    return json(res, 400, { error: "bad_request" });
  }
  // A path outside the project is reported as missing, not as forbidden:
  // the difference would confirm what exists on the machine.
  const path = await projectPath(ctx, url);
  if (!path) return json(res, 404, { error: "not_found" });

  let stat;
  try {
    stat = statSync(path);
  } catch {
    return json(res, 404, { error: "not_found" });
  }
  if (!stat.isFile()) return json(res, 404, { error: "not_found" });

  // Streamed: this is also the download route, and a download can be larger
  // than the daemon should hold in memory.
  res.writeHead(200, {
    "content-type": CONTENT_TYPES[extname(path).toLowerCase()] ?? "application/octet-stream",
    "content-length": stat.size,
    // The agent rewrites files under the same path constantly.
    "cache-control": "no-store",
  });
  const stream = createReadStream(path);
  stream.on("error", () => res.destroy());
  stream.pipe(res);
}

/**
 * An image the transcript referred to by name.
 *
 * Named by content hash, so the bytes behind a name never change and the
 * device may keep them for good. Only names the store itself mints resolve,
 * which is the whole of the path containment here.
 */
function serveImage(ctx: RouteContext, url: URL, res: ServerResponse): void {
  const name = url.searchParams.get("name") ?? "";
  const path = ctx.images.path(name);
  if (!path) return json(res, 404, { error: "not_found" });
  const bytes = readFileSync(path);
  res.writeHead(200, {
    "content-type": IMAGE_CONTENT_TYPES[name.split(".").at(-1)!] ?? "application/octet-stream",
    "content-length": bytes.length,
    "cache-control": "private, max-age=31536000, immutable",
  });
  res.end(bytes);
}

/**
 * The editor's view of a file: text plus everything needed to save it back.
 *
 * The etag is the save precondition, and the eol/trailing-newline flags are
 * restored on write so opening a CRLF file and changing one line does not
 * rewrite every line of it.
 */
async function serveFileText(ctx: RouteContext, url: URL, res: ServerResponse): Promise<void> {
  const path = await projectPath(ctx, url);
  if (!path) return json(res, 404, { error: "not_found" });

  const file = await readTextFile(path);
  if (!file) return json(res, 404, { error: "not_found" });
  res.setHeader("cache-control", "no-store");
  json(res, 200, file);
}

async function saveFile(
  ctx: RouteContext,
  url: URL,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  const path = await projectPath(ctx, url);
  if (!path) return json(res, 404, { error: "not_found" });

  const body = await readBody(req, MAX_EDIT_BYTES);
  if (!body) return json(res, 413, { error: "too_large" });

  const ifMatch = req.headers["if-match"];
  const outcome = await writeTextFile(path, body.toString("utf8"), {
    ifMatch: typeof ifMatch === "string" ? ifMatch : undefined,
    eol: url.searchParams.get("eol") === "crlf" ? "crlf" : "lf",
    trailingNewline: url.searchParams.get("nl") !== "0",
  });

  if (outcome.ok) {
    // Only a new path changes what the fuzzy index should return.
    if (outcome.created) invalidateFileIndex();
    res.setHeader("etag", outcome.etag);
    return json(res, 200, { etag: outcome.etag, bytes: outcome.bytes });
  }
  if (outcome.error === "conflict") {
    return json(res, 409, { error: "conflict", etag: outcome.etag });
  }
  if (outcome.error === "exists") return json(res, 409, { error: "exists" });
  return json(res, 413, { error: "too_large" });
}

/** The contained absolute path a project + `path` pair names, if any. */
async function projectPath(ctx: RouteContext, url: URL): Promise<string | null> {
  const requested = url.searchParams.get("path");
  if (!requested || !namesProject(url)) return null;
  const root = await projectRoot(ctx, url);
  return root ? containedPath(root, requested) : null;
}

/**
 * Directories first, then files, both alphabetical: a file tree, not a picker.
 * Nothing is hidden: build output and dependencies are exactly what someone
 * opens the tree to inspect, and listing one level at a time keeps it cheap.
 */
function treeListing(root: string, path: string, dirents: Dirent[]) {
  const entries = dirents
    .filter((d) => d.isDirectory() || d.isFile())
    .map((d) => ({ name: d.name, path: join(path, d.name), dir: d.isDirectory() }))
    .sort((a, b) => Number(b.dir) - Number(a.dir) || a.name.localeCompare(b.name));

  return directoryListing(root, path, entries);
}

function directoryListing<T>(root: string, path: string, entries: T[]) {
  return {
    root,
    path,
    name: basename(path) || path,
    parent: path === root ? null : dirname(path),
    entries,
  };
}

async function upload(
  ctx: RouteContext,
  url: URL,
  req: IncomingMessage,
  res: ServerResponse,
): Promise<void> {
  if (!namesProject(url)) return json(res, 400, { error: "bad_request" });

  const root = await projectRoot(ctx, url);
  if (!root) return json(res, 404, { error: "unknown_session" });

  // Without a `dir` it is a chat attachment, kept out of the way of the
  // project's own files. With one, the folder must already exist: an upload
  // is not a way to create directory trees.
  const requestedDir = url.searchParams.get("dir");
  let dir = requestedDir ? containedPath(root, requestedDir) : null;
  if (requestedDir) {
    const info = dir ? await stat(dir).catch(() => null) : null;
    if (!info?.isDirectory()) return json(res, 404, { error: "not_found" });
  }

  // Refused before a byte is read: the phone learns now, not after sending
  // the whole thing over a mobile link.
  const declared = Number(req.headers["content-length"] ?? 0);
  if (declared > ctx.config.maxUploadBytes) return refuseBody(res, 413, { error: "too_large" });

  dir ??= await prepareUploadDir(root);
  const outcome = await receiveUpload(req, dir, url.searchParams.get("name"), ctx.config.maxUploadBytes);
  if (!outcome.ok) {
    if (outcome.error === "aborted") return;
    return refuseBody(res, outcome.error === "too_large" ? 413 : 409, { error: outcome.error });
  }
  invalidateFileIndex(root);
  json(res, 200, {
    path: outcome.path,
    relativePath: relative(root, outcome.path),
    bytes: outcome.bytes,
  });
}

/**
 * Answers without reading the rest of the body.
 *
 * Closing the connection is what stops the client sending; destroying the
 * socket instead would lose the answer and leave the phone with a bare
 * network error.
 */
function refuseBody(res: ServerResponse, status: number, body: unknown): void {
  res.setHeader("connection", "close");
  json(res, status, body);
}

/**
 * Cross-origin access for the PWA.
 *
 * The app is served from a different port (a dev server now, a static host
 * later), so every call here is cross-origin. Authorisation is a bearer token
 * the browser never sends on its own, and credentials are never allowed, so a
 * hostile page gains nothing from being able to make the request.
 */
function cors(req: IncomingMessage, res: ServerResponse): void {
  const origin = req.headers.origin;
  if (!origin) return;
  res.setHeader("access-control-allow-origin", origin);
  res.setHeader("vary", "origin");
  res.setHeader("access-control-allow-methods", "GET, POST, PUT, OPTIONS");
  res.setHeader("access-control-allow-headers", "authorization, content-type, if-match");
  res.setHeader("access-control-expose-headers", "etag");
  res.setHeader("access-control-max-age", "600");
}

function json(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

async function readBody(req: IncomingMessage, limit: number): Promise<Buffer | null> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    // Stop reading rather than buffering the whole oversized body first.
    if (size > limit) {
      req.destroy();
      return null;
    }
    chunks.push(chunk as Buffer);
  }
  return Buffer.concat(chunks);
}

async function readJson(
  req: IncomingMessage,
  limit: number,
): Promise<Record<string, unknown> | null> {
  const body = await readBody(req, limit);
  if (!body) return null;
  try {
    return JSON.parse(body.toString("utf8"));
  } catch {
    return null;
  }
}
