import { browserStorage } from "./storage.ts";

/**
 * A composer with no session behind it yet.
 *
 * A session with no first prompt is not a session, so picking a directory
 * costs nothing on the daemon: the id is minted here and the first prompt is
 * what brings the session into being under that exact id.
 */
export interface Draft {
  id: string;
  cwd: string;
  trustProject: boolean;
  createdAt: number;
}

/** Where the composer keeps unsent text, per session id. */
export const COMPOSER_TEXT_PREFIX = "pios.draft.";

/** Nothing typed and nothing queued: leaving it loses no work. */
export function isEmptyDraft(id: string, queued: number): boolean {
  return queued === 0 && !(browserStorage.get(COMPOSER_TEXT_PREFIX + id) ?? "").trim();
}

const key = (machineId: string) => `pios.drafts.${machineId}`;

export function loadDrafts(machineId: string): Draft[] {
  const raw = browserStorage.get(key(machineId));
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as Draft[];
    return Array.isArray(parsed) ? parsed.filter((draft) => draft?.id && draft?.cwd) : [];
  } catch {
    return [];
  }
}

export function saveDrafts(machineId: string, drafts: Draft[]): void {
  if (drafts.length) browserStorage.set(key(machineId), JSON.stringify(drafts));
  else browserStorage.remove(key(machineId));
}
