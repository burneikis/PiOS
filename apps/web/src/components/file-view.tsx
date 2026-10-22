import { lazy, Suspense, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import type { TextFile } from "@pios/protocol";
import { fetchFile, saveToDevice, uploadFile, type FileAccess } from "../files.ts";
import {
  dropDraft,
  loadDraft,
  loadHideDotfiles,
  loadTextFile,
  loadTree,
  loadWrapLines,
  saveDraft,
  saveHideDotfiles,
  saveWrapLines,
  saveTextFile,
  searchFiles,
  type TreeListing,
} from "../file-edit.ts";
import { basename, byteSize, isolate, messageOf } from "../format.ts";
import type { EditorHandle } from "./code-editor.tsx";
import {
  ChevronLeftIcon,
  CloseIcon,
  FileIcon,
  FolderIcon,
  RedoIcon,
  UndoIcon,
  UploadIcon,
  WrapIcon,
} from "./icons.tsx";
import { ListRowButton, ModalCard, PickerHeader, SearchField } from "./ui.tsx";

/**
 * Identity of an access, for effect dependencies.
 *
 * The chat re-renders on every streamed entry, and an effect keyed on the
 * access object would refetch the file each time one arrives.
 */
function accessKey(access: FileAccess): string {
  return `${access.baseUrl}\u0000${access.deviceToken}\u0000${access.sessionId}\u0000${access.cwd ?? ""}`;
}

const CodeEditor = lazy(() =>
  import("./code-editor.tsx").then((module) => ({ default: module.CodeEditor })),
);

const REFUSALS: Record<NonNullable<TextFile["reason"]>, string> = {
  too_large: "Too large to edit. Showing the start of the file.",
  binary: "Not a text file. Showing the start of it as text.",
  long_lines: "Lines are too long to edit. Showing the start of the file.",
};

/**
 * Reading and editing a file in the session's directory.
 *
 * Full screen rather than a sheet: the software keyboard takes most of a
 * phone, and an editor squeezed into what is left is not one.
 */
export function FileView({ access, cwd, path, onOpen, onClose }: {
  access: FileAccess;
  /** Session directory, so paths are shown and stored relative to it. */
  cwd: string;
  /** Null shows the picker. */
  path: string | null;
  onOpen: (path: string | null) => void;
  onClose: () => void;
}) {
  if (!path) {
    return (
      <FilePicker
        access={access}
        onPick={(picked) => onOpen(relativeTo(cwd, picked))}
        onClose={onClose}
      />
    );
  }
  return (
    <FileEditor
      access={access}
      path={path}
      onBrowse={() => onOpen(null)}
      onClose={onClose}
    />
  );
}

/** Fuzzy search when there is a query, the directory tree when there is not. */
function FilePicker({ access, onPick, onClose }: {
  access: FileAccess;
  onPick: (path: string) => void;
  onClose: () => void;
}) {
  const [query, setQuery] = useState("");
  const [matches, setMatches] = useState<string[]>([]);
  const [listing, setListing] = useState<TreeListing | null>(null);
  const [dir, setDir] = useState<string | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);
  const [hideDotfiles, setHideDotfiles] = useState(loadHideDotfiles);
  const [saving, setSaving] = useState<string | null>(null);
  const [uploadNote, setUploadNote] = useState<string | null>(null);
  const [reloads, setReloads] = useState(0);
  const at = useRef(access);
  at.current = access;
  const key = accessKey(access);

  async function upload(picked: FileList | null) {
    const target = listing?.path;
    const chosen = Array.from(picked ?? []);
    if (!target || chosen.length === 0) return;
    setError(null);
    const landed: string[] = [];
    for (const [index, file] of chosen.entries()) {
      setUploadNote(`Uploading ${index + 1} of ${chosen.length}\u2026`);
      try {
        landed.push(basename((await uploadFile(at.current, file, target)).path));
      } catch (cause) {
        setError(`${file.name} was not uploaded: ${messageOf(cause)}`);
      }
    }
    // A renamed file is only noticed if it is named.
    setUploadNote(landed.length > 0 ? `Uploaded ${landed.join(", ")}` : null);
    setReloads((n) => n + 1);
  }

  function toggleDotfiles(hide: boolean) {
    saveHideDotfiles(hide);
    setHideDotfiles(hide);
  }

  useEffect(() => {
    if (!query.trim()) return;
    let live = true;
    // The daemon caches its index, so a keystroke is cheap; a debounce would
    // cost more in perceived lag than it saves in requests.
    void searchFiles(at.current, query)
      .then((files) => live && setMatches(files))
      .catch(() => live && setError("Search unavailable."));
    return () => {
      live = false;
    };
  }, [key, query]);

  useEffect(() => {
    let live = true;
    void loadTree(at.current, dir)
      .then((next) => live && setListing(next))
      .catch(() => live && setError("This directory could not be read."));
    return () => {
      live = false;
    };
  }, [key, dir, reloads]);

  const browsing = !query.trim();
  // At the top it is the project; below it, the path inside the project.
  const here = listing ? (listing.parent ? relativeTo(listing.root, listing.path) : listing.name) : null;
  return (
    <section className="subview file-view">
      <header className="subview-head">
        <button type="button" className="ghost icon" aria-label="back to chat" onClick={onClose}>
          <ChevronLeftIcon />
        </button>
        <h2 className="line tail">{here ? isolate(here) : "Files"}</h2>
        <label className="check">
          <input
            type="checkbox"
            checked={hideDotfiles}
            onChange={(event) => toggleDotfiles(event.target.checked)}
          />
          Hide hidden
        </label>
        {browsing && listing ? (
          <label className="attach ghost icon" title="Upload to this folder" aria-label="upload to this folder">
            <input
              type="file"
              multiple
              onChange={(event) => {
                void upload(event.target.files);
                event.target.value = "";
              }}
            />
            <UploadIcon />
          </label>
        ) : null}
      </header>

      <SearchField value={query} placeholder="Search files" onChange={setQuery} />
      {error ? <p className="banner error">{error}</p> : null}
      {uploadNote ? <p className="banner">{uploadNote}</p> : null}

      <div className="scroll-y file-list">
        {browsing ? (
          <>
            {listing?.parent ? (
              <ListRowButton icon={<FolderIcon />} onClick={() => setDir(listing.parent!)}>
                ..
              </ListRowButton>
            ) : null}
            {listing?.entries
              .filter((entry) => !(hideDotfiles && entry.name.startsWith(".")))
              .map((entry) => (
                <ListRowButton
                  key={entry.path}
                  icon={entry.dir ? <FolderIcon /> : <FileIcon />}
                  onClick={() => (entry.dir ? setDir(entry.path) : onPick(entry.path))}
                  onLongPress={entry.dir ? undefined : () => setSaving(entry.path)}
                >
                  {isolate(entry.name)}
                </ListRowButton>
              ))}
          </>
        ) : (
          matches.map((match) => (
            <ListRowButton
              key={match}
              icon={<FileIcon />}
              onClick={() => onPick(match)}
              onLongPress={() => setSaving(match)}
            >
              {isolate(match)}
            </ListRowButton>
          ))
        )}
      </div>

      {saving ? (
        <SaveSheet access={access} path={saving} onClose={() => setSaving(null)} />
      ) : null}
    </section>
  );
}

/**
 * Copying a file from the machine to this device.
 *
 * The bytes are fetched as soon as the sheet opens and handed over on a tap:
 * the share sheet only opens from a tap, and one that waited on the network
 * first no longer counts as one.
 */
function SaveSheet({ access, path, onClose }: {
  access: FileAccess;
  path: string;
  onClose: () => void;
}) {
  const [file, setFile] = useState<File | null>(null);
  const [error, setError] = useState<string | null>(null);
  const at = useRef(access);
  at.current = access;
  const key = accessKey(access);

  useEffect(() => {
    let live = true;
    void fetchFile(at.current, path)
      .then((fetched) => live && setFile(fetched))
      .catch((cause: unknown) => live && setError(`Could not read it: ${messageOf(cause)}`));
    return () => {
      live = false;
    };
  }, [key, path]);

  function save(ready: File) {
    saveToDevice(ready)
      .then(onClose)
      .catch((cause: unknown) => setError(`Could not save it: ${messageOf(cause)}`));
  }

  return createPortal(
    <ModalCard className="picker save-file" overlay>
      <PickerHeader title="Save to device" onCancel={onClose} />
      <div className="save-file-name">
        <p className="line tail">{isolate(basename(path))}</p>
        {error ? null : <p className="muted">{file ? byteSize(file.size) : "Fetching…"}</p>}
      </div>
      {error ? <p className="banner error">{error}</p> : null}
      <div className="row">
        <button type="button" onClick={onClose}>
          Cancel
        </button>
        <button
          type="button"
          className="primary"
          disabled={!file}
          onClick={() => file && save(file)}
        >
          Save
        </button>
      </div>
    </ModalCard>,
    document.body,
  );
}

type Conflict = { etag: string };

function FileEditor({ access, path, onBrowse, onClose }: {
  access: FileAccess;
  path: string;
  onBrowse: () => void;
  onClose: () => void;
}) {
  const [file, setFile] = useState<TextFile | null>(null);
  const [text, setText] = useState("");
  const [dirty, setDirty] = useState(false);
  const [editing, setEditing] = useState(false);
  const [restored, setRestored] = useState(false);
  const [conflict, setConflict] = useState<Conflict | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [wrap, setWrap] = useState(loadWrapLines);
  const handle = useRef<EditorHandle | null>(null);
  const at = useRef(access);
  at.current = access;
  const key = accessKey(access);

  useEffect(() => {
    let live = true;
    setFile(null);
    setError(null);
    setConflict(null);
    setRestored(false);
    setDirty(false);
    setEditing(false);

    void (async () => {
      try {
        const loaded = await loadTextFile(at.current, path);
        const draft = await loadDraft(at.current.sessionId, path);
        if (!live) return;
        setFile(loaded);
        // A draft from an older version of the file is still the user's work:
        // it is shown, and the stale etag surfaces as a conflict on save.
        setText(draft ? draft.text : loaded.text);
        setDirty(Boolean(draft));
        setRestored(Boolean(draft));
        if (draft) setEditing(true);
      } catch (cause) {
        if (live) setError(cause instanceof Error ? cause.message : "Unavailable");
      }
    })();
    return () => {
      live = false;
    };
  }, [key, path]);

  function edited(next: string) {
    setText(next);
    setDirty(true);
    if (file) {
      void saveDraft({ sessionId: access.sessionId, path, text: next, etag: file.etag });
    }
  }

  async function save(force = false): Promise<void> {
    if (!file) return;
    setSaving(true);
    setError(null);
    const result = await saveTextFile(access, path, text, {
      ...file,
      etag: force ? "*" : file.etag,
    });
    setSaving(false);

    if (result.ok) {
      setFile({ ...file, etag: result.etag });
      setDirty(false);
      setRestored(false);
      setConflict(null);
      void dropDraft(access.sessionId, path);
      return;
    }
    if (result.conflict) setConflict({ etag: result.etag });
    else setError(result.message);
  }

  async function reload(): Promise<void> {
    const loaded = await loadTextFile(access, path);
    setFile(loaded);
    setText(loaded.text);
    setDirty(false);
    setRestored(false);
    setConflict(null);
    void dropDraft(access.sessionId, path);
  }

  function leave(go: () => void) {
    // The draft is already on disk, so this asks about attention, not data.
    if (dirty && !window.confirm("Leave with unsaved changes? They are kept as a draft.")) return;
    go();
  }

  function toggleWrap() {
    saveWrapLines(!wrap);
    setWrap(!wrap);
  }

  const readOnly = !editing || !file?.editable;
  return (
    <section className="subview file-view">
      <header className="subview-head">
        <button
          type="button"
          className="ghost icon"
          aria-label="back to chat"
          onClick={() => leave(onClose)}
        >
          <ChevronLeftIcon />
        </button>
        {/* The dot sits outside the clipped path: inside, the reversed
            direction would put it ahead of the name. */}
        <h2 className="file-title" onClick={() => leave(onBrowse)}>
          <span className="line tail">{isolate(path)}</span>
          {dirty ? <span className="dirty-dot" aria-label="unsaved changes" /> : null}
        </h2>
        <button
          type="button"
          className="ghost icon"
          aria-label="wrap lines"
          aria-pressed={wrap}
          onClick={toggleWrap}
        >
          <WrapIcon />
        </button>
        {file?.editable ? (
          editing ? (
            <button
              type="button"
              className="primary"
              disabled={!dirty || saving}
              onClick={() => void save()}
            >
              {saving ? "Saving…" : "Save"}
            </button>
          ) : (
            <button type="button" onClick={() => setEditing(true)}>
              Edit
            </button>
          )
        ) : null}
      </header>

      {error ? <p className="banner error">{error}</p> : null}
      {file && !file.editable ? <p className="banner warn">{REFUSALS[file.reason!]}</p> : null}
      {restored ? <p className="banner">Restored unsaved edits from this device.</p> : null}

      {conflict ? (
        <div className="banner warn file-conflict">
          <span>This file changed on disk since you opened it.</span>
          <span className="row">
            <button type="button" onClick={() => void reload()}>
              Reload
            </button>
            <button type="button" className="danger" onClick={() => void save(true)}>
              Overwrite
            </button>
          </span>
        </div>
      ) : null}

      {file ? (
        <Suspense fallback={<p className="muted">Loading editor…</p>}>
          <CodeEditor
            text={text}
            path={path}
            readOnly={readOnly}
            wrap={wrap}
            handle={handle}
            onChange={edited}
          />
        </Suspense>
      ) : error ? null : (
        <p className="muted">Reading…</p>
      )}

      {editing && file?.editable ? (
        // Above the keyboard: the keys a code editor needs that a phone
        // keyboard does not have.
        <div className="file-keys row">
          <button type="button" onClick={() => handle.current?.outdent()} aria-label="outdent">
            ⇤
          </button>
          <button type="button" onClick={() => handle.current?.indent()} aria-label="indent">
            ⇥
          </button>
          <button type="button" onClick={() => handle.current?.undo()} aria-label="undo">
            <UndoIcon />
          </button>
          <button type="button" onClick={() => handle.current?.redo()} aria-label="redo">
            <RedoIcon />
          </button>
          <button
            type="button"
            className="ghost icon"
            aria-label="stop editing"
            onClick={() => setEditing(false)}
          >
            <CloseIcon />
          </button>
        </div>
      ) : null}
    </section>
  );
}

/** Paths are shown, stored and sent relative to the session directory. */
function relativeTo(root: string, path: string): string {
  if (path === root) return ".";
  return path.startsWith(`${root}/`) ? path.slice(root.length + 1) : path;
}
