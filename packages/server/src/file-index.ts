import { execFile } from "node:child_process";
import { readdir } from "node:fs/promises";
import { join, relative, sep } from "node:path";

/**
 * Fuzzy file lookup for the composer's `@` picker.
 *
 * The index is a flat list of paths relative to the session cwd. `git
 * ls-files` is preferred because it is the only cheap way to honour
 * `.gitignore`; a directory walk is the fallback, with a hardcoded skip list
 * so a stray `node_modules` cannot turn one keystroke into a minute of IO.
 */

export interface FileMatch {
  /** Relative to the session cwd, forward-slashed, ready to paste. */
  path: string;
  score: number;
}

/** Enough to cover a large repo without holding a pathological tree in memory. */
const MAX_INDEXED = 20_000;
const WALK_TIMEOUT_MS = 5_000;
const GIT_TIMEOUT_MS = 5_000;
const MAX_OUTPUT = 8 * 1024 * 1024;

/**
 * Typing `@src/co` is one request per keystroke, and the tree barely changes
 * between them; rebuilding per keystroke would be the whole cost of the
 * feature. Short enough that a file the agent just wrote shows up.
 */
const CACHE_TTL_MS = 5_000;
const cache = new Map<string, { at: number; files: Promise<string[]> }>();

/** Directories nobody searches in. */
const SKIP_DIRS = new Set([
  ".git",
  "node_modules",
  ".venv",
  "venv",
  "__pycache__",
  "dist",
  "build",
  "target",
  ".next",
  ".cache",
  ".turbo",
  "vendor",
]);

export function invalidateFileIndex(cwd?: string): void {
  if (cwd) cache.delete(cwd);
  else cache.clear();
}

/** Ranked matches for a query; an empty query returns the head of the index. */
export async function searchFiles(cwd: string, query: string, limit = 30): Promise<FileMatch[]> {
  const files = await indexFiles(cwd);
  const needle = query.trim();
  if (!needle) return files.slice(0, limit).map((path) => ({ path, score: 0 }));

  const matches: FileMatch[] = [];
  for (const path of files) {
    const score = fuzzyScore(path, needle);
    if (score !== null) matches.push({ path, score });
  }
  // Score first, then shorter path, then alphabetical: a stable order matters
  // because the list is keyboard-navigable while it refreshes underneath.
  matches.sort(
    (a, b) => b.score - a.score || a.path.length - b.path.length || a.path.localeCompare(b.path),
  );
  return matches.slice(0, limit);
}

function indexFiles(cwd: string): Promise<string[]> {
  const hit = cache.get(cwd);
  if (hit && Date.now() - hit.at < CACHE_TTL_MS) return hit.files;
  // The promise is cached, not its result, so concurrent keystrokes during a
  // cold build share one walk instead of racing several.
  const files = buildIndex(cwd);
  cache.set(cwd, { at: Date.now(), files });
  files.catch(() => cache.delete(cwd));
  return files;
}

async function buildIndex(cwd: string): Promise<string[]> {
  const tracked = await gitFiles(cwd);
  if (tracked) return tracked;
  return await walk(cwd);
}

/** Null when the directory is not a repository, or git is unavailable. */
function gitFiles(cwd: string): Promise<string[] | null> {
  return new Promise((resolve) => {
    execFile(
      "git",
      ["-c", "core.quotepath=false", "ls-files", "--cached", "--others", "--exclude-standard"],
      { cwd, timeout: GIT_TIMEOUT_MS, maxBuffer: MAX_OUTPUT, encoding: "utf8" },
      (error, stdout) => {
        if (error) {
          resolve(null);
          return;
        }
        const files = stdout.split("\n").filter(Boolean).slice(0, MAX_INDEXED);
        resolve(files);
      },
    );
  });
}

async function walk(root: string): Promise<string[]> {
  const deadline = Date.now() + WALK_TIMEOUT_MS;
  const found: string[] = [];
  const queue = [root];

  while (queue.length > 0 && found.length < MAX_INDEXED && Date.now() < deadline) {
    const dir = queue.shift()!;
    let dirents;
    try {
      dirents = await readdir(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of dirents) {
      if (entry.name.startsWith(".") || SKIP_DIRS.has(entry.name)) continue;
      const child = join(dir, entry.name);
      // Symlinks are not followed: a link back up the tree would make the
      // walk unbounded, and the target is reachable by its real path anyway.
      if (entry.isDirectory()) queue.push(child);
      else if (entry.isFile()) found.push(relative(root, child).split(sep).join("/"));
      if (found.length >= MAX_INDEXED) break;
    }
  }
  return found;
}

/**
 * Subsequence match, scored by how contiguous and how word-aligned it is.
 *
 * Null means no match at all. Matching runs over the whole relative path, so
 * `webcomp` finds `apps/web/src/components/...`, but the basename is weighted
 * because that is what someone is usually typing.
 */
export function fuzzyScore(path: string, query: string): number | null {
  const haystack = path.toLowerCase();
  const needle = query.toLowerCase();

  let score = 0;
  let at = 0;
  let previous = -1;
  for (const char of needle) {
    const found = haystack.indexOf(char, at);
    if (found === -1) return null;
    if (found === previous + 1) score += 6;
    // Start of a path segment or a word: the boundary someone aims at.
    const before = found > 0 ? haystack[found - 1]! : "/";
    if (/[/\-_. ]/.test(before)) score += 8;
    else if (found === 0) score += 8;
    score += 1;
    previous = found;
    at = found + 1;
  }

  const slash = haystack.lastIndexOf("/");
  // A run inside the basename is the strongest signal there is: it dominates
  // the per-character bonuses, which a long directory prefix can otherwise
  // accumulate more of than the file actually being looked for.
  if (haystack.indexOf(needle, slash + 1) !== -1) score += 60;
  else if (haystack.includes(needle)) score += 10;
  // Shallow, short paths win ties; deep ones are rarely what a short query meant.
  score -= Math.min(haystack.length, 120) / 12;
  return score;
}
