import { summarise, type Git } from "../../git.ts";
import type { GitRun } from "../git-view.tsx";
import { MinusIcon, PlusIcon, TrashIcon } from "../icons.tsx";
import { Empty, FileRow, GitSection, IconButton } from "./parts.tsx";

/** A commit being written, held by the view so a diff or a tab switch keeps it. */
export interface CommitDraft {
  message: string;
  amend: boolean;
}

/**
 * The working tree: what is staged, what is not, and the commit that ends it.
 *
 * The message field sits above the file list because it is what the commit
 * button acts on, and a long list must not push the two apart.
 */
export function ChangesTab({ git, run, draft, onDraft, onOpenDiff }: {
  git: Git;
  run: GitRun;
  draft: CommitDraft;
  onDraft: (draft: CommitDraft) => void;
  onOpenDiff: (path: string, staged: boolean) => void;
}) {
  const status = git.status;
  const { message, amend } = draft;

  if (!status) return null;

  const staged = status.files.filter((f) => f.index !== "." && !f.unmerged);
  const changed = status.files.filter((f) => f.index === "." || f.unmerged);
  const canCommit = (status.staged > 0 || amend) && (message.trim().length > 0 || amend);

  // The message survives a failed commit: it is the only copy of it.
  async function commit() {
    if (!(await run({ type: "commit", message, amend }))) return;
    onDraft({ message: "", amend: false });
  }

  return (
    <>
      <div className="git-commit">
        <textarea
          className="git-message"
          rows={2}
          value={message}
          placeholder={amend ? "Amend message (blank keeps the old one)" : "Commit message"}
          onChange={(event) => onDraft({ message: event.target.value, amend })}
        />
        <div className="row spread git-commit-row">
          <label className="check">
            <input
              type="checkbox"
              checked={amend}
              onChange={(event) => onDraft({ message, amend: event.target.checked })}
            />
            Amend
          </label>
          <span className="row">
            <button
              type="button"
              disabled={git.busy || status.staged + status.unstaged + status.untracked === 0}
              onClick={() => void run({ type: "stage_all" })}
            >
              Stage all
            </button>
            <button
              type="button"
              className="primary"
              disabled={git.busy || !canCommit}
              onClick={() => void commit()}
            >
              {git.pending === "commit" ? "Committing…" : "Commit"}
            </button>
          </span>
        </div>
      </div>

      <div className="scroll-y">
        <p className="muted git-summary line">{summarise(status)}</p>

        <GitSection
          title={`Staged (${staged.length})`}
          action={
            staged.length > 0 ? (
              <button type="button" className="link" disabled={git.busy} onClick={() => void run({ type: "unstage_all" })}>
                Unstage all
              </button>
            ) : null
          }
        >
          {staged.length === 0 ? <Empty>Nothing staged.</Empty> : null}
          {staged.map((file) => (
            <FileRow
              key={`staged:${file.path}`}
              file={file}
              onSelect={() => onOpenDiff(file.path, true)}
              controls={
                <IconButton
                  label={`unstage ${file.path}`}
                  disabled={git.busy}
                  onClick={() => void run({ type: "unstage", paths: [file.path] })}
                >
                  <MinusIcon />
                </IconButton>
              }
            />
          ))}
        </GitSection>

        <GitSection
          title={`Changes (${changed.length})`}
          action={
            // Git refuses to stash mid-merge, and offering it during one would
            // only produce an error the user cannot act on.
            changed.length > 0 && !status.operation ? (
              <button type="button" className="link" disabled={git.busy} onClick={() => void run({ type: "stash" })}>
                Stash all
              </button>
            ) : null
          }
        >
          {changed.length === 0 ? <Empty>Working tree clean.</Empty> : null}
          {changed.map((file) => (
            <FileRow
              key={`changed:${file.path}`}
              file={file}
              onSelect={() => onOpenDiff(file.path, false)}
              controls={
                <>
                  {file.unmerged ? null : (
                    <IconButton
                      label={`discard ${file.path}`}
                      danger
                      disabled={git.busy}
                      onClick={() => void run({ type: "discard", paths: [file.path] })}
                    >
                      <TrashIcon />
                    </IconButton>
                  )}
                  <IconButton
                    label={`stage ${file.path}`}
                    disabled={git.busy}
                    onClick={() => void run({ type: "stage", paths: [file.path] })}
                  >
                    <PlusIcon />
                  </IconButton>
                </>
              }
            />
          ))}
        </GitSection>

        {status.truncated ? (
          <Empty>Too many changes to list; the counts above are exact.</Empty>
        ) : null}
      </div>
    </>
  );
}
