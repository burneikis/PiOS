import type { SessionSummary } from "@pios/protocol";
import { useEffect, useRef } from "react";
import { relativeTime, shortenPath } from "../format.ts";
import { isUnseen } from "../seen.ts";
import { sessionState } from "../session-status.ts";
import type { Draft } from "../drafts.ts";
import { PlusIcon, TerminalIcon } from "./icons.tsx";
import { ListRowButton, SearchField } from "./ui.tsx";

/**
 * Every session on the machine, running or not.
 *
 * One list, because a conversation is a conversation: whether the daemon
 * happens to have pi up for it is a detail the user cannot see and should not
 * have to look in a second place for.
 */
export function SessionList({
  sessions,
  drafts,
  activeId,
  seen,
  shells,
  query,
  loading,
  hasMore,
  onQuery,
  onSelect,
  onCreate,
  onLoadMore,
}: {
  sessions: SessionSummary[];
  /** Composers with no session behind them yet, newest first. */
  drafts: Draft[];
  activeId: string | null;
  /** Last `updatedAt` the user saw, by session id. */
  seen: Record<string, number>;
  /** Sessions with a shell running, which keeps going until it is closed. */
  shells: ReadonlySet<string>;
  query: string;
  loading: boolean;
  hasMore: boolean;
  onQuery: (query: string) => void;
  onSelect: (sessionId: string) => void;
  onCreate: () => void;
  onLoadMore: () => void;
}) {
  // The daemon's order: by the last thing the user did, so an agent left
  // running does not bury the conversation that was just open.
  const ordered = [...sessions].sort((a, b) => activeAt(b) - activeAt(a));

  return (
    <nav className="sessions">
      <div className="row spread section-head">
        <h2>Sessions</h2>
        <button type="button" className="ghost icon" aria-label="new session" onClick={onCreate}>
          <PlusIcon />
        </button>
      </div>

      {/* The list is the whole history on disk, so it is searched rather than
          scrolled: filtering happens on the daemon, across every page. */}
      <SearchField value={query} placeholder="Search sessions" onChange={onQuery} />

      {ordered.length === 0 && drafts.length === 0 ? (
        <p className="muted">{loading ? "Loading sessions…" : "No sessions yet."}</p>
      ) : (
        <ul className="scroll-y">
          {drafts.map((draft) => (
            <li key={draft.id} className={draft.id === activeId ? "active" : ""}>
              <ListRowButton className="session" onClick={() => onSelect(draft.id)}>
                <span className="name line">New session</span>
                <span className="muted line">{shortenPath(draft.cwd)}</span>
                <span className="badge cold">draft</span>
                {shells.has(draft.id) ? <ShellMark /> : null}
              </ListRowButton>
            </li>
          ))}
          {ordered.map((session) => (
            <li key={session.sessionId} className={session.sessionId === activeId ? "active" : ""}>
              <ListRowButton className="session" onClick={() => onSelect(session.sessionId)}>
                {/* The opening message identifies a session far better than its
                    directory, which every session in a project shares. */}
                <span className="name line">
                  {session.name ?? session.preview ?? shortenPath(session.cwd)}
                </span>
                <span className="muted line">
                  {shortenPath(session.cwd)} · {relativeTime(activeAt(session))}
                </span>
                <SessionBadge
                  session={session}
                  unseen={isUnseen(seen, session.sessionId, session.updatedAt)}
                />
                {shells.has(session.sessionId) ? <ShellMark /> : null}
              </ListRowButton>
            </li>
          ))}
          {hasMore ? <MoreRow onVisible={onLoadMore} /> : null}
        </ul>
      )}
    </nav>
  );
}

/**
 * The row's state, worded and coloured exactly as the open session's header
 * does it: a session waiting on a dialog has to be findable from the list.
 */
function SessionBadge({ session, unseen }: { session: SessionSummary; unseen: boolean }) {
  const state = sessionState(session, { unseen });
  return <span className={`badge ${state.tone}`}>{state.label}</span>;
}

/** A shell is still running here, whether or not anyone is looking at it. */
function ShellMark() {
  return (
    <span className="shell-mark" role="img" aria-label="shell running" title="Shell running">
      <TerminalIcon width={14} height={14} />
    </span>
  );
}

/** Asks for the next page once the end of the list is actually reached. */
function MoreRow({ onVisible }: { onVisible: () => void }) {
  const marker = useRef<HTMLLIElement>(null);

  useEffect(() => {
    const node = marker.current;
    if (!node) return;
    const observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) onVisible();
    });
    observer.observe(node);
    return () => observer.disconnect();
  }, [onVisible]);

  return (
    <li ref={marker} className="muted more">
      Loading more…
    </li>
  );
}

function activeAt(session: SessionSummary): number {
  return session.activeAt ?? session.updatedAt;
}
