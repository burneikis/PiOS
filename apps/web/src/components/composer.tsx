import type { ImageContent, ModelOption, StreamingBehavior } from "@pios/protocol";
import type { SessionCreate } from "@pios/client-core";
import { useEffect, useRef, useState } from "react";
import { useClient } from "../client-provider.tsx";
import { uploadFile, useFileAccess } from "../files.ts";
import { isolate, messageOf } from "../format.ts";
import { useSettings } from "../settings.ts";
import { browserStorage } from "../storage.ts";
import { CommandMenu, slashQuery, useSlashCommands, type MenuEntry } from "./command-menu.tsx";
import { applyMention, mentionAt, useFileMatches, type Mention } from "./file-mentions.ts";
import { PlusIcon, SendIcon, StopIcon } from "./icons.tsx";
import { nativeCommandFor, openSelect, type NativeCommand } from "./native-commands.ts";
import { ModelDialog } from "./model-dialog.tsx";
import { ModelPicker } from "./model-picker.tsx";
import { ThinkingPicker } from "./thinking-picker.tsx";

const DRAFT_PREFIX = "pios.draft.";

/** A non-image file, copied into the project as soon as it is picked. */
interface FileAttachment {
  id: number;
  name: string;
  /** Set once the daemon has it. */
  path?: string;
  error?: string;
}

let nextAttachmentId = 0;

/**
 * Composes a prompt and hands it to the outbox.
 *
 * The draft is saved per session on every keystroke, because the tab can be
 * evicted at any moment on a phone, and never touches the socket: sending
 * means queueing.
 */
export function Composer({
  sessionId,
  create,
  model,
  thinkingLevel,
  thinkingLevels,
  running,
  interrupting,
  editorText,
  editorTextKey,
  nativeCommands = [],
  onSend,
  onBash,
  onInterrupt,
  onComposingChange,
}: {
  sessionId: string;
  /** Set while this is a draft: what it takes to start the session behind it. */
  create?: SessionCreate;
  /** An extension asked to replace what is typed, e.g. a prompt template. */
  editorText?: string;
  /** Changes when the same text is handed over again, e.g. a second rewind. */
  editorTextKey?: number;
  /** Active model, for the picker's label. */
  model?: ModelOption;
  thinkingLevel?: string;
  /** Levels the active model accepts; empty hides the picker. */
  thinkingLevels?: string[];
  running: boolean;
  /** Stop was sent and the agent has not stopped yet. */
  interrupting: boolean;
  /** App-level commands, e.g. `/new`. The dock's own are added here. */
  nativeCommands?: NativeCommand[];
  onSend: (text: string, images: ImageContent[], behavior?: StreamingBehavior) => void;
  /** A `!` line: one shell command in the session cwd, not a prompt. */
  onBash: (command: string, excludeFromContext: boolean) => void;
  onInterrupt: () => void;
  /** Focus of the field, so the pane can give the keyboard more room. */
  onComposingChange?: (composing: boolean) => void;
}) {
  const client = useClient();
  const steeringMode = useSettings().steeringMode;
  const [text, setText] = useState("");
  const [images, setImages] = useState<ImageContent[]>([]);
  const [files, setFiles] = useState<FileAttachment[]>([]);
  const access = useFileAccess();
  const [active, setActive] = useState(0);
  const field = useRef<HTMLTextAreaElement>(null);
  const thinkingSelect = useRef<HTMLSelectElement>(null);
  const [modelDialog, setModelDialog] = useState(false);
  // Tracked separately from the text: the same text has a different `@` token
  // under it depending on where the caret is.
  const [mention, setMention] = useState<Mention | null>(null);

  // The dock's own controls, named as pi names them, so `/model` does here
  // what it does in the terminal instead of reaching the model as text.
  // `/model` is the whole catalogue, which needs a search field, so it opens
  // a dialog rather than the dock's scoped select.
  const dockCommands: NativeCommand[] = [
    { name: "model", description: "Switch models", run: () => setModelDialog(true) },
  ];
  if (thinkingLevels && thinkingLevels.length > 1) {
    dockCommands.push({
      name: "thinking",
      description: "Set the thinking level",
      // A level it does not offer opens the picker: that is the list of the
      // ones it does.
      run: (args) => {
        const level = args.toLowerCase();
        if (thinkingLevels.includes(level)) client.setThinkingLevel(sessionId, level);
        else openSelect(thinkingSelect.current);
      },
    });
  }

  // A pi command is an ordinary prompt; the menu only helps write one. A
  // native command never becomes text at all.
  const localCommands = [...nativeCommands, ...dockCommands];
  const query = slashQuery(text);
  const commandMatches = useSlashCommands(sessionId, query, localCommands);
  const fileMatches = useFileMatches(mention);
  // A line can only be completing one thing at a time, and a slash command is
  // always at the very start, so it wins when both somehow match.
  const matches: MenuEntry[] =
    commandMatches.length > 0
      ? commandMatches
      : fileMatches.map((path) => ({ name: path, label: path, badge: "file" }));
  // The list shrinks under the cursor when pi's answer arrives, so the
  // highlight is clamped where it is read rather than where it is set.
  const highlighted = Math.min(active, Math.max(matches.length - 1, 0));

  // One line until there is more to show: a tall empty box eats transcript on
  // a phone. The height has to be reset before it is read, or it only grows.
  function resize() {
    const box = field.current;
    if (!box) return;
    box.style.height = "auto";
    box.style.height = `${box.scrollHeight}px`;
  }

  useEffect(resize, [text]);

  useEffect(() => {
    setText(browserStorage.get(DRAFT_PREFIX + sessionId) ?? "");
    setImages([]);
    setFiles([]);
  }, [sessionId]);

  // Keyed on the value, not on arrival: the daemon resends the same text on
  // every reconnect, and reapplying it would wipe what was typed since.
  useEffect(() => {
    if (editorText === undefined) return;
    setText(editorText);
    browserStorage.set(DRAFT_PREFIX + sessionId, editorText);
  }, [editorText, editorTextKey, sessionId]);

  function edit(value: string, caret?: number) {
    setText(value);
    setActive(0);
    setMention(caret === undefined ? null : mentionAt(value, caret));
    const key = DRAFT_PREFIX + sessionId;
    if (value) browserStorage.set(key, value);
    else browserStorage.remove(key);
  }

  /** Runs a native command, or completes a pi one: most take arguments. */
  function choose(entry: MenuEntry) {
    if (entry.badge === "file") {
      if (!mention) return;
      const next = applyMention(text, mention, entry.name);
      edit(next);
      const caret = mention.start + entry.name.length + 2;
      field.current?.focus();
      // After React has written the new value, or the caret snaps to the end.
      requestAnimationFrame(() => field.current?.setSelectionRange(caret, caret));
      return;
    }
    if (!entry.run) {
      edit(`/${entry.name} `);
      field.current?.focus();
      return;
    }
    edit("");
    entry.run("");
  }

  const uploaded = files.flatMap((file) => (file.path ? [file.path] : []));
  const uploading = files.some((file) => !file.path && !file.error);
  const sendable = !uploading && (text.trim() !== "" || images.length > 0 || uploaded.length > 0);

  function send() {
    const trimmed = text.trim();
    if (!sendable) return;
    // `/settings` is an app screen, not something the model should be told
    // about, however the line was finished.
    const native = nativeCommandFor(trimmed, localCommands);
    if (native) {
      edit("");
      native.command.run(native.args);
      return;
    }
    // pi's own shell prefixes: `!` runs a command and keeps the output in the
    // conversation, `!!` runs it for the reader alone. Images are ignored
    // rather than silently dropped into a shell that has no use for them.
    const bash = bashCommand(trimmed);
    if (bash) {
      onBash(bash.command, bash.excludeFromContext);
      edit("");
      return;
    }
    // Mandatory while the agent streams, ignored otherwise; sending it always
    // is simpler than tracking who won the race with `agent_settled`.
    // The model only sees text and images, so a file is handed over as a
    // path it can read with its own tools.
    const listed = uploaded.map((path) => `- ${path}`).join("\n");
    const message = listed ? `${trimmed}${trimmed ? "\n\n" : ""}Attached files:\n${listed}` : trimmed;
    onSend(message, images, running ? steeringMode : undefined);
    edit("");
    setImages([]);
    setFiles([]);
  }

  async function attach(picked: Iterable<File> | null) {
    for (const file of Array.from(picked ?? [])) {
      // An image the model can look at directly; one it cannot decode here
      // still reaches it as a file.
      const image = file.type.startsWith("image/") ? await readImage(file) : null;
      if (image) setImages((current) => [...current, image]);
      else upload(file);
    }
  }

  function upload(file: File) {
    const id = nextAttachmentId++;
    const update = (patch: Partial<FileAttachment>) =>
      setFiles((current) => current.map((f) => (f.id === id ? { ...f, ...patch } : f)));
    setFiles((current) => [...current, { id, name: file.name }]);
    if (!access?.baseUrl) return update({ error: "not connected" });
    uploadFile(access, file)
      .then((done) => update({ path: done.relativePath }))
      .catch((cause: unknown) => update({ error: messageOf(cause) }));
  }

  return (
    <div className="composer">
      {modelDialog ? (
        <ModelDialog
          sessionId={sessionId}
          create={create}
          current={model}
          onClose={() => setModelDialog(false)}
        />
      ) : null}

      <CommandMenu entries={matches} active={highlighted} onPick={choose} />

      {images.length > 0 ? (
        <div className="attachments">
          {images.map((image, index) => (
            <img
              key={index}
              alt="attachment"
              title="Remove"
              src={`data:${image.mimeType};base64,${image.data}`}
              onClick={() => setImages(images.filter((_, i) => i !== index))}
            />
          ))}
        </div>
      ) : null}

      {files.length > 0 ? (
        <div className="attachments files">
          {files.map((file) => (
            <button
              key={file.id}
              type="button"
              className={`file-chip${file.error ? " failed" : ""}`}
              title={file.error ? `Upload failed: ${file.error}. Tap to remove.` : "Remove"}
              onClick={() => setFiles(files.filter((f) => f.id !== file.id))}
            >
              <span className="line">{isolate(file.name)}</span>
              <span className="muted">
                {file.error ? "failed" : file.path ? "" : "uploading…"}
              </span>
            </button>
          ))}
        </div>
      ) : null}

      <textarea
        ref={field}
        value={text}
        rows={1}
        placeholder="Message pi"
        onChange={(e) => edit(e.target.value, e.target.selectionStart ?? undefined)}
        // The caret can move without the text changing, which opens or closes
        // the picker just as much as typing does.
        onSelect={(e) => setMention(mentionAt(text, e.currentTarget.selectionStart ?? 0))}
        onFocus={() => onComposingChange?.(true)}
        onBlur={() => onComposingChange?.(false)}
        // A screenshot is the fastest way to show the agent something, and on
        // a phone the clipboard is often the only path to one.
        onPaste={(e) => {
          const pasted = Array.from(e.clipboardData.files);
          if (pasted.length > 0) {
            e.preventDefault();
            void attach(pasted);
          }
        }}
        onKeyDown={(e) => {
          // Checked before the menu: an explicit send is never a completion.
          if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
            e.preventDefault();
            send();
            return;
          }
          if (matches.length > 0) {
            // Dismiss without losing what was typed: the token may be meant
            // literally, or the file may simply not be indexed.
            if (e.key === "Escape" && mention) {
              e.preventDefault();
              setMention(null);
              return;
            }
            if (e.key === "ArrowDown" || e.key === "ArrowUp") {
              e.preventDefault();
              const step = e.key === "ArrowDown" ? 1 : matches.length - 1;
              setActive((index) => (index + step) % matches.length);
              return;
            }
            // Tab and Enter complete rather than send: a bare `/name` is
            // rarely what was meant, and sending an unknown one just errors.
            if (e.key === "Tab" || e.key === "Enter") {
              e.preventDefault();
              choose(matches[highlighted]!);
              return;
            }
          }
        }}
      />

      <div className="composer-actions">
        {/* Collapsed while typing: the pickers are one `/model` or `/thinking`
            away, and the room they take is transcript on a phone. */}
        <div className="composer-options">
        <label className="attach ghost icon" title="Attach images or files">
          <input
            type="file"
            multiple
            onChange={(e) => {
              void attach(e.target.files);
              // Same file twice in a row is a real case; without this the
              // second pick fires no change event.
              e.target.value = "";
            }}
          />
          <PlusIcon />
        </label>

        <ModelPicker sessionId={sessionId} create={create} current={model} />

        <ThinkingPicker
          sessionId={sessionId}
          current={thinkingLevel}
          levels={thinkingLevels ?? []}
          selectRef={thinkingSelect}
        />
        </div>

        <span className="spacer" />

        {/* Stop sits beside Send, not instead of it: the next turn can be
            queued while the agent still runs. */}
        {running ? (
          <button
            type="button"
            className="icon ghost stop"
            disabled={interrupting}
            aria-label={interrupting ? "stopping" : "stop"}
            onClick={onInterrupt}
          >
            <StopIcon />
          </button>
        ) : null}
        <button
          type="button"
          className="icon send"
          aria-label="send"
          disabled={!sendable}
          onClick={send}
        >
          <SendIcon />
        </button>
      </div>
    </div>
  );
}

/** Splits pi's `!` / `!!` prefix off a line, if it has one. */
function bashCommand(text: string): { command: string; excludeFromContext: boolean } | null {
  if (!text.startsWith("!")) return null;
  const excludeFromContext = text.startsWith("!!");
  const command = text.slice(excludeFromContext ? 2 : 1).trim();
  return command ? { command, excludeFromContext } : null;
}

// A phone photo is ~4000px and several megabytes; the model gains nothing
// from that and the outbox has to persist every byte of it as base64.
const MAX_EDGE = 1568;

async function readImage(file: File): Promise<ImageContent | null> {
  try {
    const shrunk = await downscale(file);
    if (shrunk) return shrunk;
    return { type: "image", data: await readBase64(file), mimeType: file.type };
  } catch {
    return null;
  }
}

/** Null when the image is already small enough, or cannot be decoded here. */
async function downscale(file: File): Promise<ImageContent | null> {
  if (typeof createImageBitmap !== "function") return null;
  let bitmap: ImageBitmap;
  try {
    bitmap = await createImageBitmap(file);
  } catch {
    return null;
  }
  const scale = Math.min(1, MAX_EDGE / Math.max(bitmap.width, bitmap.height));
  if (scale === 1) {
    bitmap.close();
    return null;
  }

  const canvas = document.createElement("canvas");
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  const context = canvas.getContext("2d");
  if (!context) {
    bitmap.close();
    return null;
  }
  context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();

  // JPEG regardless of the source: a screenshot re-encoded as PNG at this size
  // is still large, and none of this is archival.
  const data = canvas.toDataURL("image/jpeg", 0.85).split(",")[1] ?? "";
  return { type: "image", data, mimeType: "image/jpeg" };
}

function readBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error);
    reader.onload = () => resolve(String(reader.result).split(",")[1] ?? "");
    reader.readAsDataURL(file);
  });
}
