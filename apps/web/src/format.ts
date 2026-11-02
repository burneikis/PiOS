/**
 * Keeps a string's own reading order inside a right-to-left box.
 *
 * Truncating a path from the front needs `direction: rtl`, which also moves a
 * trailing `/` to the head: "tmp/" renders as "/tmp". The isolate marks the
 * text as one left-to-right run without changing where the ellipsis lands.
 */
export function isolate(text: string): string {
  return `\u2066${text}\u2069`;
}

/** The directory name alone; callers show the full path elsewhere. */
export function basename(path: string): string {
  return path.split("/").filter(Boolean).at(-1) ?? path;
}

/** Home prefix as `~`: the leading `/home/<user>` is noise on a phone. */
export function collapseHome(path: string): string {
  return path.replace(/^\/(?:home|Users)\/[^/]+/, "~");
}

/**
 * What to call a session on screen.
 *
 * A name that is really an id says nothing a person picked, so the directory
 * wins: old sessions were already born with id-shaped names and the fallback
 * has to be defensive about them.
 */
export function sessionTitle(
  name: string | undefined,
  cwd: string | undefined,
): { text: string; path: boolean } {
  if (name && !looksGenerated(name)) return { text: name, path: false };
  if (cwd) return { text: collapseHome(cwd), path: true };
  return { text: "New session", path: false };
}

/** A uuid, or a bare run of hex long enough that nobody typed it. */
function looksGenerated(name: string): boolean {
  const text = name.trim();
  if (/\s/.test(text)) return false;
  return /^[0-9a-f-]{8,}$/i.test(text) && /[0-9]/.test(text);
}

export function shortenPath(path: string): string {
  const parts = path.split("/").filter(Boolean);
  return parts.length <= 2 ? path : `.../${parts.slice(-2).join("/")}`;
}

/** Today as a clock time, otherwise a day count: precision decays with age. */
export function relativeTime(at: number): string {
  const days = Math.floor((Date.now() - at) / 86_400_000);
  if (days === 0)
    return new Date(at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  if (days === 1) return "yesterday";
  return `${days}d ago`;
}

export function messageOf(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}

export function byteSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB"];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(value < 10 ? 1 : 0)} ${units[unit]}`;
}

/** 1234 as `1.2k`: token counts are read at a glance, not to the unit. */
export function compactCount(value: number): string {
  if (value < 1000) return String(value);
  if (value < 1_000_000) return `${(value / 1000).toFixed(value < 10_000 ? 1 : 0)}k`;
  return `${(value / 1_000_000).toFixed(1)}M`;
}
