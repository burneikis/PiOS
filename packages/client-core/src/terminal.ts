import type { ClientFrame, LiveTerminal, ServerFrame, TerminalCursor } from "@pios/protocol";
import { Listeners } from "./listeners.ts";

type Command = ClientFrame extends infer Frame
  ? Frame extends { commandId: string; type: `terminal_${string}` }
    ? Omit<Frame, "v" | "commandId">
    : never
  : never;

export interface TerminalSize {
  cols: number;
  rows: number;
}

export interface TerminalExitInfo {
  exitCode: number;
  signal?: number;
}

/** Where a terminal's output goes: in the web app, an xterm.js instance. */
export interface TerminalSink {
  /** What follows does not continue what was written; clear first. */
  reset(): void;
  output(data: string): void;
  exit(info: TerminalExitInfo): void;
  /** The daemon refused to open the shell. */
  error(message: string): void;
}

/** One open terminal, as the UI holds it. Never touches a socket itself. */
export interface TerminalHandle {
  /** False when there is no connection; keystrokes are not queued. */
  write(data: string): boolean;
  resize(size: TerminalSize): void;
  /** Starts a new shell in place of one that has exited. */
  restart(): void;
  /** Stops streaming here and leaves the shell running. */
  detach(): void;
  /** Hangs up the shell for every device. */
  kill(): void;
}

/** Marks the commands this channel sent, so their errors come back here. */
const ID_PREFIX = "term:";

interface Attachment {
  cwd: string;
  size: TerminalSize;
  sink: TerminalSink;
  /** Absent until the daemon has said which shell this is. */
  cursor?: TerminalCursor;
  openCommandId?: string;
}

/**
 * Daemon-owned shells, streamed over the client's one socket.
 *
 * Output is tracked by offset, so a reconnect asks for exactly what was
 * missed and a duplicate or a gap in the live stream is visible rather than
 * silently corrupting the screen. Input is never queued: keystrokes replayed
 * after a reconnect would land in whatever the shell is doing by then.
 */
export class TerminalChannel {
  private readonly attachments = new Map<string, Attachment>();
  /** Shells running on the machine, whoever opened them, by id. */
  private running = new Map<string, LiveTerminal>();
  private readonly runningHandlers = new Listeners<[running: ReadonlyMap<string, LiveTerminal>]>();
  private readonly send: (command: Command, commandId: string) => boolean;
  private readonly generateId: () => string;

  constructor(send: (command: Command, commandId: string) => boolean, generateId: () => string) {
    this.send = send;
    this.generateId = generateId;
  }

  /**
   * Attaches to the shell under `terminalId`, starting it if it has none.
   *
   * Opening an id this client already holds hands the stream to the new sink
   * and replays from scratch, since the new sink starts empty.
   */
  open(terminalId: string, args: { cwd: string; size: TerminalSize }, sink: TerminalSink): TerminalHandle {
    const attachment: Attachment = { cwd: args.cwd, size: args.size, sink };
    this.attachments.set(terminalId, attachment);
    this.sendOpen(terminalId, attachment, false);

    const live = () => this.attachments.get(terminalId) === attachment;
    return {
      write: (data) => live() && this.command({ type: "terminal_input", terminalId, data }),
      resize: (size) => {
        if (!live() || (size.cols === attachment.size.cols && size.rows === attachment.size.rows)) return;
        attachment.size = size;
        this.command({ type: "terminal_resize", terminalId, ...size });
      },
      restart: () => {
        if (live()) this.sendOpen(terminalId, attachment, true);
      },
      detach: () => {
        if (!live()) return;
        this.attachments.delete(terminalId);
        this.command({ type: "terminal_detach", terminalId });
      },
      kill: () => {
        if (!live()) return;
        this.attachments.delete(terminalId);
        this.command({ type: "terminal_close", terminalId });
      },
    };
  }

  /** The shells running on the machine, as of the daemon's last word. */
  live(): ReadonlyMap<string, LiveTerminal> {
    return this.running;
  }

  /** Fires with the whole set whenever a shell starts or ends. */
  subscribeLive(handler: (running: ReadonlyMap<string, LiveTerminal>) => void): () => void {
    return this.runningHandlers.add(handler);
  }

  /** Re-attaches everything after a reconnect, each from its own cursor. */
  reconnected(): void {
    for (const [terminalId, attachment] of this.attachments) {
      this.sendOpen(terminalId, attachment, false);
    }
  }

  /** True when the frame was a terminal's, handled or not. */
  onFrame(frame: ServerFrame): boolean {
    switch (frame.type) {
      case "terminal_attached":
        this.onAttached(frame);
        return true;
      case "terminal_output":
        this.onOutput(frame);
        return true;
      case "terminals":
        this.running = new Map(frame.terminals.map((t) => [t.terminalId, t]));
        this.runningHandlers.emit(this.running);
        return true;
      case "terminal_exit":
        this.attachments.get(frame.terminalId)?.sink.exit({
          exitCode: frame.exitCode,
          signal: frame.signal,
        });
        return true;
      default:
        return false;
    }
  }

  /**
   * Claims a refusal of any terminal command. True when it was one.
   *
   * Only a refused open is reported, to its sink. A keystroke refused because
   * the shell is gone says nothing the exit has not, once per key.
   */
  onError(commandId: string, message: string): boolean {
    if (!commandId.startsWith(ID_PREFIX)) return false;
    for (const attachment of this.attachments.values()) {
      if (attachment.openCommandId !== commandId) continue;
      attachment.openCommandId = undefined;
      attachment.sink.error(message);
    }
    return true;
  }

  private sendOpen(terminalId: string, attachment: Attachment, restart: boolean): void {
    const commandId = this.nextId();
    attachment.openCommandId = commandId;
    this.send(
      {
        type: "terminal_open",
        terminalId,
        cwd: attachment.cwd,
        cols: attachment.size.cols,
        rows: attachment.size.rows,
        since: restart ? undefined : attachment.cursor,
        restart,
      },
      commandId,
    );
  }

  private onAttached(frame: Extract<ServerFrame, { type: "terminal_attached" }>): void {
    const attachment = this.attachments.get(frame.terminalId);
    // A reply to an open this sink has since replaced is not its to apply.
    if (!attachment || frame.commandId !== attachment.openCommandId) return;
    attachment.openCommandId = undefined;
    if (frame.reset) attachment.sink.reset();
    attachment.cursor = { instance: frame.instance, offset: frame.offset };
  }

  private onOutput(frame: Extract<ServerFrame, { type: "terminal_output" }>): void {
    const attachment = this.attachments.get(frame.terminalId);
    // Before the attach reply there is no offset to place output against,
    // and the replay that follows the reply covers it.
    const cursor = attachment?.openCommandId ? undefined : attachment?.cursor;
    if (!attachment || !cursor) return;
    const end = frame.offset + frame.data.length;
    if (end <= cursor.offset) return;
    if (frame.offset > cursor.offset) {
      // Output went missing in between. Ask again from what is held.
      this.sendOpen(frame.terminalId, attachment, false);
      return;
    }
    attachment.sink.output(frame.data.slice(cursor.offset - frame.offset));
    cursor.offset = end;
  }

  private command(command: Command): boolean {
    return this.send(command, this.nextId());
  }

  private nextId(): string {
    return `${ID_PREFIX}${this.generateId()}`;
  }
}
