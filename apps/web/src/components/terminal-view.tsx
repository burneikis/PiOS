import { useEffect, useRef, useState } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import type { TerminalExitInfo, TerminalHandle } from "@pios/client-core";
import { useClient, useSupervisorState } from "../client-provider.tsx";
import { readText } from "../clipboard.ts";
import { collapseHome, isolate } from "../format.ts";
import { useSettings } from "../settings.ts";
import { ConfirmBar } from "./git/parts.tsx";
import { ChevronLeftIcon, TrashIcon } from "./icons.tsx";
import { attachTouchScroll } from "./terminal-touch.ts";

/** "once" is spent by the next key; "locked" holds until tapped off. */
type CtrlState = "off" | "once" | "locked";

/** A second tap on ctrl within this window locks it, as with shift on iOS. */
const DOUBLE_TAP_MS = 400;

/** Matches the app's own surface, so the screen does not read as an embed. */
const THEME = {
  background: "#131313",
  foreground: "#eeeeec",
  cursor: "#e8e8e4",
  cursorAccent: "#131313",
  selectionBackground: "rgba(127, 166, 207, 0.35)",
};

/**
 * The keys a phone keyboard does not have. Arrows follow the cursor-key mode
 * the program asked for, or a full-screen editor would read them as text.
 */
const KEYS: { label: string; aria: string; send: (app: boolean) => string }[] = [
  { label: "esc", aria: "escape", send: () => "\x1b" },
  { label: "tab", aria: "tab", send: () => "\t" },
  { label: "←", aria: "left", send: (app) => (app ? "\x1bOD" : "\x1b[D") },
  { label: "↑", aria: "up", send: (app) => (app ? "\x1bOA" : "\x1b[A") },
  { label: "↓", aria: "down", send: (app) => (app ? "\x1bOB" : "\x1b[B") },
  { label: "→", aria: "right", send: (app) => (app ? "\x1bOC" : "\x1b[C") },
];

/**
 * A shell on the machine, in the session's directory.
 *
 * The shell belongs to the daemon: leaving this screen, losing the
 * connection, or reloading the app detaches from it and it keeps running,
 * so a build started here is still there on the way back.
 */
export function TerminalView({ terminalId, cwd, onClose }: {
  terminalId: string;
  cwd: string;
  onClose: () => void;
}) {
  const client = useClient();
  const { transport } = useSupervisorState();
  const screen = useRef<HTMLDivElement>(null);
  const term = useRef<Terminal | null>(null);
  const fitter = useRef<FitAddon | null>(null);
  const { terminalFontSize } = useSettings();
  // Read once at creation; later changes go through the effect below.
  const initialFontSize = useRef(terminalFontSize);
  const handle = useRef<TerminalHandle | null>(null);
  // Sticky, as on a hardware keyboard: armed by the key bar, spent by the next key.
  const [ctrl, setCtrlState] = useState<CtrlState>("off");
  const ctrlRef = useRef<CtrlState>("off");
  const ctrlArmedAt = useRef(0);
  const [exit, setExit] = useState<TerminalExitInfo | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [confirmKill, setConfirmKill] = useState(false);
  const [pasteFailed, setPasteFailed] = useState(false);

  function setCtrl(next: CtrlState) {
    ctrlRef.current = next;
    setCtrlState(next);
  }

  function tapCtrl(now: number) {
    const current = ctrlRef.current;
    if (current === "off") {
      ctrlArmedAt.current = now;
      setCtrl("once");
    } else if (current === "once" && now - ctrlArmedAt.current < DOUBLE_TAP_MS) {
      setCtrl("locked");
    } else {
      setCtrl("off");
    }
  }

  useEffect(() => {
    const host = screen.current;
    if (!host) return;
    const xterm = new Terminal({
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
      fontSize: initialFontSize.current,
      scrollback: 5000,
      cursorBlink: true,
      theme: THEME,
    });
    const fit = new FitAddon();
    xterm.loadAddon(fit);
    xterm.open(host);
    fit.fit();
    term.current = xterm;
    fitter.current = fit;

    const opened = client.terminals.open(
      terminalId,
      { cwd, size: { cols: xterm.cols, rows: xterm.rows } },
      {
        reset: () => {
          xterm.reset();
          setExit(null);
          setError(null);
        },
        output: (data) => xterm.write(data),
        exit: setExit,
        error: setError,
      },
    );
    handle.current = opened;

    const send = (data: string) => {
      if (ctrlRef.current === "off") return opened.write(data);
      if (ctrlRef.current === "once") setCtrl("off");
      opened.write(withCtrl(data));
    };
    const typed = xterm.onData(send);
    const binary = xterm.onBinary((data) => opened.write(data));
    const resized = xterm.onResize(({ cols, rows }) => opened.resize({ cols, rows }));
    // The keyboard coming up shrinks the box, and the shell has to know.
    const observer = new ResizeObserver(() => {
      if (host.clientWidth > 0 && host.clientHeight > 0) fit.fit();
    });
    observer.observe(host);
    const detachTouch = attachTouchScroll(xterm, host);
    xterm.focus();

    return () => {
      detachTouch();
      observer.disconnect();
      typed.dispose();
      binary.dispose();
      resized.dispose();
      opened.detach();
      handle.current = null;
      term.current = null;
      fitter.current = null;
      xterm.dispose();
    };
  }, [client, terminalId, cwd]);

  // Changing the size in place refits, so the shell learns its new geometry.
  useEffect(() => {
    const xterm = term.current;
    if (!xterm || xterm.options.fontSize === terminalFontSize) return;
    xterm.options.fontSize = terminalFontSize;
    fitter.current?.fit();
  }, [terminalFontSize]);

  function key(send: (app: boolean) => string) {
    const xterm = term.current;
    if (!xterm) return;
    handle.current?.write(send(xterm.modes.applicationCursorKeysMode));
    xterm.focus();
  }

  async function paste() {
    const text = await readText();
    const xterm = term.current;
    if (!xterm) return;
    setPasteFailed(text === null);
    // Through xterm, so bracketed paste mode and newline handling apply.
    if (text) xterm.paste(text);
    xterm.focus();
  }

  return (
    <section className="subview terminal-view">
      <header className="subview-head">
        <button type="button" className="ghost icon" aria-label="back to chat" onClick={onClose}>
          <ChevronLeftIcon />
        </button>
        <h2 className="line tail">{isolate(collapseHome(cwd))}</h2>
        <button
          type="button"
          className="ghost icon"
          aria-label="close the shell"
          disabled={Boolean(exit)}
          onClick={() => setConfirmKill(true)}
        >
          <TrashIcon />
        </button>
      </header>

      {confirmKill ? (
        <ConfirmBar
          text="Close the shell? Anything running in it is stopped."
          confirmLabel="Close shell"
          onCancel={() => setConfirmKill(false)}
          onConfirm={() => {
            setConfirmKill(false);
            handle.current?.kill();
            onClose();
          }}
        />
      ) : null}
      {error ? <p className="banner error">{error}</p> : null}
      {pasteFailed ? (
        <p className="banner warn">Could not read the clipboard.</p>
      ) : null}
      {transport !== "connected" && !error ? (
        <p className="banner warn">Not connected. Keys typed now are not sent.</p>
      ) : null}

      {/* Tapping anywhere on the screen is how the keyboard comes up. */}
      <div className="terminal-screen" ref={screen} />

      {exit ? (
        <div className="banner terminal-exit">
          <span className="line">
            {exit.signal ? `Shell ended by signal ${exit.signal}` : `Shell exited with code ${exit.exitCode}`}
          </span>
          <button type="button" className="primary" onClick={() => handle.current?.restart()}>
            Restart
          </button>
        </div>
      ) : (
        <div className="term-keys row">
          <button
            type="button"
            className={ctrl === "off" ? undefined : ctrl === "locked" ? "active locked" : "active"}
            aria-pressed={ctrl !== "off"}
            aria-label={ctrl === "locked" ? "control, locked" : "control"}
            // Keeps focus, and so the keyboard, on the terminal.
            onMouseDown={(event) => event.preventDefault()}
            onClick={(event) => {
              tapCtrl(event.timeStamp);
              term.current?.focus();
            }}
          >
            ctrl
          </button>
          {KEYS.map((k) => (
            <button
              type="button"
              key={k.aria}
              aria-label={k.aria}
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => key(k.send)}
            >
              {k.label}
            </button>
          ))}
          <button
            type="button"
            aria-label="paste"
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => void paste()}
          >
            paste
          </button>
        </div>
      )}
    </section>
  );
}

/** What a key reads as with Control held, for the keys that have one. */
function withCtrl(data: string): string {
  if (data.length !== 1) return data;
  const code = data.toUpperCase().charCodeAt(0);
  if (code >= 64 && code <= 95) return String.fromCharCode(code - 64);
  if (data === " ") return "\x00";
  if (data === "?") return "\x7f";
  return data;
}
