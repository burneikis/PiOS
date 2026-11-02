import { randomUUID } from "node:crypto";
import { constants, createWriteStream } from "node:fs";
import { appendFile, copyFile, link, mkdir, readdir, readFile, stat, unlink } from "node:fs/promises";
import type { IncomingMessage } from "node:http";
import { basename, dirname, extname, join, resolve } from "node:path";
import { Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { git, invalidateGitCache } from "./git.ts";
import { containedPath } from "./paths.ts";

export const UPLOADS_DIR = ".pios-uploads";
/** Attachments are for the turn they were sent with; a month is generous. */
export const UPLOAD_KEEP_MS = 30 * 24 * 60 * 60 * 1000;
const EXCLUDE_LINE = `${UPLOADS_DIR}/`;

/**
 * The project's attachment folder, ready to write into.
 *
 * Kept out of git through `.git/info/exclude` rather than `.gitignore`: it is
 * local to this machine, and editing a tracked file would itself be a change
 * the user never asked for. Old attachments are dropped here too, since an
 * upload is the only moment the daemon knows which projects have the folder.
 */
export async function prepareUploadDir(root: string, now = Date.now()): Promise<string> {
  const dir = join(root, UPLOADS_DIR);
  await mkdir(dir, { recursive: true });
  await Promise.all([excludeFromGit(root), pruneUploads(dir, now)]);
  return dir;
}

async function excludeFromGit(root: string): Promise<void> {
  let exclude: string;
  try {
    // Asked of git rather than assumed: a worktree or submodule keeps its
    // git directory somewhere other than `.git/`.
    exclude = resolve(root, (await git(root, ["rev-parse", "--git-path", "info/exclude"])).trim());
  } catch {
    return;
  }
  try {
    const current = await readFile(exclude, "utf8").catch(() => "");
    if (current.split(/\r?\n/).some((line) => line.trim() === EXCLUDE_LINE)) return;
    await mkdir(dirname(exclude), { recursive: true });
    const separator = current && !current.endsWith("\n") ? "\n" : "";
    await appendFile(exclude, `${separator}${EXCLUDE_LINE}\n`);
    invalidateGitCache(root);
  } catch (error) {
    // Not worth failing an upload over; the folder just shows as untracked.
    console.warn("[pios] could not exclude uploads from git", error);
  }
}

export type UploadOutcome =
  | { ok: true; path: string; bytes: number }
  | { ok: false; error: "too_large" | "exists" | "aborted" };

class TooLarge extends Error {}

/**
 * Streams a request body into `dir` under a free version of `rawName`.
 *
 * Written to a temp file first and only then given its name, so a dropped
 * connection never leaves a truncated file that looks complete, and memory
 * stays flat whatever the size.
 */
export async function receiveUpload(
  req: IncomingMessage,
  dir: string,
  rawName: string | null,
  limit: number,
): Promise<UploadOutcome> {
  const temp = join(dir, `.pios-upload-${randomUUID()}.part`);
  let bytes = 0;
  const counter = new Transform({
    transform(chunk: Buffer, _encoding, done) {
      bytes += chunk.length;
      // Content-Length can be absent or wrong; this is the limit that holds.
      done(bytes > limit ? new TooLarge() : null, chunk);
    },
  });

  try {
    await pipeline(req, counter, createWriteStream(temp, { flags: "wx" }));
  } catch (error) {
    await unlink(temp).catch(() => {});
    if (error instanceof TooLarge) return { ok: false, error: "too_large" };
    // A full disk is the daemon's problem and should be logged as one; only
    // a vanished client is nobody's.
    if ((error as NodeJS.ErrnoException).path === temp) throw error;
    return { ok: false, error: "aborted" };
  }

  try {
    const path = await claimName(temp, dir, uploadName(rawName));
    return path ? { ok: true, path, bytes } : { ok: false, error: "exists" };
  } finally {
    await unlink(temp).catch(() => {});
  }
}

/** A bare file name from whatever the client sent; never a path. */
export function uploadName(raw: string | null): string {
  const name = basename((raw ?? "").replace(/\\/g, "/"))
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .trim();
  if (!name || name === "." || name === "..") return "upload.bin";
  if (name.length <= 128) return name;
  const ext = extname(name).slice(0, 16);
  return name.slice(0, 128 - ext.length) + ext;
}

/**
 * Gives the finished temp file a name beside, never over, an existing file:
 * the target may be something the agent or the user cares about, and a phone
 * is a bad place to notice. A hard link fails atomically when the name is
 * taken, so even a file the agent creates mid-upload is safe.
 */
async function claimName(temp: string, dir: string, name: string): Promise<string | null> {
  const ext = extname(name);
  const stem = name.slice(0, name.length - ext.length) || name;
  for (let n = 1; n <= 100; n++) {
    const target = containedPath(dir, n === 1 ? name : `${stem} (${n})${ext}`);
    if (!target) return null;
    try {
      await placeExclusive(temp, target);
      return target;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    }
  }
  return null;
}

async function placeExclusive(temp: string, target: string): Promise<void> {
  try {
    await link(temp, target);
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    // Some filesystems (FAT, a few FUSE mounts) have no hard links.
    if (code !== "EPERM" && code !== "ENOTSUP" && code !== "EOPNOTSUPP") throw error;
    await copyFile(temp, target, constants.COPYFILE_EXCL);
  }
}

/** Only plain files at the top: anything else in there was put there by someone else. */
export async function pruneUploads(dir: string, now = Date.now()): Promise<void> {
  const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
  await Promise.all(
    entries
      .filter((entry) => entry.isFile())
      .map(async (entry) => {
        const path = join(dir, entry.name);
        const info = await stat(path).catch(() => null);
        if (info && now - info.mtimeMs > UPLOAD_KEEP_MS) await unlink(path).catch(() => {});
      }),
  );
}
