import { randomUUID } from "node:crypto";
import { statSync } from "node:fs";
import { userInfo } from "node:os";
import { isAbsolute } from "node:path";
import { spawn, type IPty } from "node-pty";

export interface TerminalExit {
  exitCode: number;
  signal?: number;
}

/** One attached client. */
export interface TerminalListener {
  output(data: string, offset: number): void;
  exit(info: TerminalExit): void;
  /** True while this listener cannot take more output. */
  congested(): boolean;
}

export interface TerminalReplay {
  /** False only when `since` continued exactly where this shell is. */
  reset: boolean;
  offset: number;
  data: string;
}

export interface TerminalHostOptions {
  /** Defaults to the user's login shell. */
  shell?: string;
  args?: string[];
  /** Laid over the daemon's own environment. */
  env?: Record<string, string>;
  /** Live shells at once. Exited ones do not count. */
  maxTerminals?: number;
  /** Output kept for a client that attaches late, in UTF-16 units. */
  scrollback?: number;
}

const DEFAULT_MAX = 8;
const DEFAULT_SCROLLBACK = 512 * 1024;
/** A PTY read is often a few bytes; one frame per read floods the relay. */
const COALESCE_MS = 4;
const CONGESTION_POLL_MS = 50;
/** A SIGHUP that lands while the shell is still starting can be lost. */
const KILL_GRACE_MS = 1000;

/**
 * A shell on a PTY, owned by the daemon rather than by any socket.
 *
 * Its output is kept as a bounded scrollback with a running offset, so a
 * client that drops and reconnects asks for what came after its own copy and
 * a new client gets the recent screen instead of a blank one.
 */
export class Terminal {
  readonly id: string;
  readonly cwd: string;
  /** Distinguishes this shell from a later one under the same id. */
  readonly instance = randomUUID();

  private readonly pty: IPty;
  private readonly listeners = new Set<TerminalListener>();
  private readonly scrollback: number;
  private chunks: string[] = [];
  private held = 0;
  /** Offset of the first character still held. */
  private start = 0;
  private pending = "";
  private flushTimer: NodeJS.Timeout | null = null;
  private congestionTimer: NodeJS.Timeout | null = null;
  private killTimer: NodeJS.Timeout | null = null;
  private exitInfo: TerminalExit | null = null;
  private cols: number;
  private rows: number;

  constructor(
    id: string,
    options: { cwd: string; cols: number; rows: number; shell: string; args: string[]; env: Record<string, string>; scrollback: number },
  ) {
    this.id = id;
    this.cwd = options.cwd;
    this.cols = options.cols;
    this.rows = options.rows;
    this.scrollback = options.scrollback;
    this.pty = spawn(options.shell, options.args, {
      name: "xterm-256color",
      cols: options.cols,
      rows: options.rows,
      cwd: options.cwd,
      env: options.env,
    });
    this.pty.onData((data) => this.onData(data));
    this.pty.onExit(({ exitCode, signal }) => this.onExit({ exitCode, signal: signal || undefined }));
  }

  get exited(): TerminalExit | null {
    return this.exitInfo;
  }

  get attached(): number {
    return this.listeners.size;
  }

  /** Where the output ends, counting what was trimmed. */
  get end(): number {
    return this.start + this.held + this.pending.length;
  }

  /**
   * Adds a listener and returns what it missed.
   *
   * Pending output is flushed first, so the replay and the live stream meet
   * exactly at `end` with nothing sent twice.
   */
  attach(listener: TerminalListener, since?: { instance: string; offset: number }): TerminalReplay {
    this.flush();
    this.listeners.add(listener);
    const continuous =
      since !== undefined &&
      since.instance === this.instance &&
      since.offset >= this.start &&
      since.offset <= this.end;
    const from = continuous ? since.offset : this.start;
    return { reset: !continuous, offset: from, data: this.read(from) };
  }

  detach(listener: TerminalListener): void {
    this.listeners.delete(listener);
  }

  write(data: string): void {
    if (!this.exitInfo) this.pty.write(data);
  }

  resize(cols: number, rows: number): void {
    if (this.exitInfo || (cols === this.cols && rows === this.rows)) return;
    this.cols = cols;
    this.rows = rows;
    this.pty.resize(cols, rows);
  }

  /**
   * Makes a full-screen program paint itself again.
   *
   * A replay cut from the front of the scrollback can lose the escape that
   * entered the alternate screen, and a resize to the same size sends no
   * SIGWINCH, so the size is wobbled to force one.
   */
  redraw(): void {
    if (this.exitInfo || this.rows < 2) return;
    this.pty.resize(this.cols, this.rows - 1);
    this.pty.resize(this.cols, this.rows);
  }

  kill(): void {
    if (this.exitInfo || this.killTimer) return;
    this.signal();
    this.killTimer = setTimeout(() => this.signal("SIGKILL"), KILL_GRACE_MS);
    // The PTY holds the loop open on its own while the shell lives.
    this.killTimer.unref();
  }

  private signal(name?: string): void {
    try {
      this.pty.kill(name);
    } catch {
      // Already gone; the exit handler reports it.
    }
  }

  private read(from: number): string {
    this.flush();
    const text = this.chunks.join("");
    this.chunks = text ? [text] : [];
    return text.slice(from - this.start);
  }

  private onData(data: string): void {
    this.pending += data;
    this.flushTimer ??= setTimeout(() => this.flush(), COALESCE_MS);
  }

  private flush(): void {
    if (this.flushTimer) clearTimeout(this.flushTimer);
    this.flushTimer = null;
    if (!this.pending) return;
    const data = this.pending;
    const offset = this.start + this.held;
    this.pending = "";
    this.keep(data);
    for (const listener of this.listeners) listener.output(data, offset);
    this.throttle();
  }

  private keep(data: string): void {
    this.chunks.push(data);
    this.held += data.length;
    while (this.held > this.scrollback) {
      const first = this.chunks[0] ?? "";
      const excess = this.held - this.scrollback;
      if (first.length <= excess) {
        this.chunks.shift();
        this.held -= first.length;
        this.start += first.length;
        continue;
      }
      // Cut at a line break where there is one, so the replay does not open
      // in the middle of an escape sequence.
      const newline = first.indexOf("\n", excess);
      const cut = newline === -1 ? excess : newline + 1;
      this.chunks[0] = first.slice(cut);
      this.held -= cut;
      this.start += cut;
    }
  }

  /**
   * Stops reading while any client is behind. The program blocks on a full
   * PTY instead of the daemon buffering a `yes` without limit.
   */
  private throttle(): void {
    if (this.congestionTimer || !this.isCongested()) return;
    this.pty.pause();
    this.congestionTimer = setInterval(() => {
      if (this.isCongested() && !this.exitInfo) return;
      if (this.congestionTimer) clearInterval(this.congestionTimer);
      this.congestionTimer = null;
      if (!this.exitInfo) this.pty.resume();
    }, CONGESTION_POLL_MS);
  }

  private isCongested(): boolean {
    for (const listener of this.listeners) if (listener.congested()) return true;
    return false;
  }

  private onExit(info: TerminalExit): void {
    this.flush();
    this.exitInfo = info;
    if (this.killTimer) clearTimeout(this.killTimer);
    this.killTimer = null;
    if (this.congestionTimer) clearInterval(this.congestionTimer);
    this.congestionTimer = null;
    for (const listener of this.listeners) listener.exit(info);
  }
}

/** Every shell the daemon holds, by client-chosen id. */
export class TerminalHost {
  private readonly terminals = new Map<string, Terminal>();
  private readonly options: Required<Omit<TerminalHostOptions, "env">> & { env: Record<string, string> };

  constructor(options: TerminalHostOptions = {}) {
    this.options = {
      shell: options.shell ?? defaultShell(),
      // Login, so a daemon started by systemd still gets the user's PATH.
      args: options.args ?? ["-l"],
      env: shellEnv(options.env),
      maxTerminals: options.maxTerminals ?? DEFAULT_MAX,
      scrollback: options.scrollback ?? DEFAULT_SCROLLBACK,
    };
  }

  get(id: string): Terminal | undefined {
    return this.terminals.get(id);
  }

  /**
   * The shell under this id, started if there is none.
   *
   * An exited shell is returned as it is unless `restart` asks for a new one,
   * so a reconnect shows how it ended rather than a fresh prompt.
   */
  open(id: string, args: { cwd: string; cols: number; rows: number; restart?: boolean }): Terminal {
    const existing = this.terminals.get(id);
    if (existing && !(args.restart && existing.exited)) return existing;
    if (existing) this.terminals.delete(id);

    checkDirectory(args.cwd);
    this.prune();
    const live = [...this.terminals.values()].filter((t) => !t.exited).length;
    if (live >= this.options.maxTerminals) {
      throw new Error(`${live} terminals are already open; close one first`);
    }
    const terminal = new Terminal(id, {
      cwd: args.cwd,
      cols: args.cols,
      rows: args.rows,
      shell: this.options.shell,
      args: this.options.args,
      env: this.options.env,
      scrollback: this.options.scrollback,
    });
    this.terminals.set(id, terminal);
    return terminal;
  }

  /** Hangs up and forgets. Attached clients are told it exited. */
  close(id: string): boolean {
    const terminal = this.terminals.get(id);
    if (!terminal) return false;
    this.terminals.delete(id);
    terminal.kill();
    return true;
  }

  closeAll(): void {
    for (const id of [...this.terminals.keys()]) this.close(id);
  }

  /** Exited shells nobody is looking at have said all they will. */
  private prune(): void {
    for (const [id, terminal] of this.terminals) {
      if (terminal.exited && terminal.attached === 0) this.terminals.delete(id);
    }
  }
}

function checkDirectory(cwd: string): void {
  if (!isAbsolute(cwd)) throw new Error(`not an absolute path: ${cwd}`);
  let isDir = false;
  try {
    isDir = statSync(cwd).isDirectory();
  } catch {
    // Reported below, the same way as a file.
  }
  if (!isDir) throw new Error(`not a directory: ${cwd}`);
}

function defaultShell(): string {
  if (process.env.SHELL) return process.env.SHELL;
  try {
    return userInfo().shell || "/bin/sh";
  } catch {
    return "/bin/sh";
  }
}

function shellEnv(overrides: Record<string, string> = {}): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined) env[key] = value;
  }
  return { ...env, ...overrides, TERM: "xterm-256color", COLORTERM: "truecolor" };
}
