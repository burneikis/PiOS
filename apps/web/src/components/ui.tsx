import { useEffect, useRef, useState, type FormEvent, type MouseEventHandler, type ReactNode } from "react";
import { isolate } from "../format.ts";
import { useLongPress } from "../long-press.ts";
import { CloseIcon, MoreIcon, SearchIcon } from "./icons.tsx";

function withBase(base: string, className?: string): string {
  return className ? `${base} ${className}` : base;
}

/**
 * A full-screen step: one card, centered. Every pre-chat screen (pairing,
 * pickers) is one of these, so they stay visually identical by construction.
 */
export function ModalCard({ className, overlay, onSubmit, children }: {
  className?: string;
  /** Floats above the chat instead of replacing it, for in-session steps. */
  overlay?: boolean;
  onSubmit?: (event: FormEvent) => void;
  children: ReactNode;
}) {
  const cls = withBase("card", className);
  return (
    <div className={overlay ? "screen centered overlay" : "screen centered"}>
      {onSubmit ? (
        <form className={cls} onSubmit={onSubmit}>
          {children}
        </form>
      ) : (
        <section className={cls}>{children}</section>
      )}
    </div>
  );
}

/**
 * A full-width, left-aligned, stacked-content tap target: session rows,
 * endpoint rows, directory rows. One style so lists cannot drift apart.
 */
export function ListRowButton({ className, onClick, onLongPress, onMouseDown, icon, trailing, children }: {
  className?: string;
  onClick: () => void;
  onLongPress?: () => void;
  /** Escape hatch for rows that must not steal focus from a field. */
  onMouseDown?: MouseEventHandler<HTMLButtonElement>;
  /** Leading glyph. Turns the row into an icon + stacked-text layout. */
  icon?: ReactNode;
  trailing?: ReactNode;
  children: ReactNode;
}) {
  const press = useLongPress(onLongPress);
  const shape = icon || trailing ? "list-row iconic" : "list-row";
  const base = onLongPress ? `${shape} pressable` : shape;
  return (
    <button
      type="button"
      className={withBase(base, className)}
      {...press}
      onClick={(event) => {
        press.onClick?.(event);
        if (!event.defaultPrevented) onClick();
      }}
      onMouseDown={onMouseDown}
    >
      {icon ? <span className="row-icon">{icon}</span> : null}
      {icon || trailing ? <span className="row-main">{children}</span> : children}
      {trailing ? <span className="row-trail">{trailing}</span> : null}
    </button>
  );
}

/**
 * The top of every picker card: dismiss on the left, title centred, optional
 * confirm on the right. Identical geometry across pickers so the dismiss
 * control never moves between steps.
 */
export function PickerHeader({ title, onCancel, action }: {
  title: string;
  onCancel: () => void;
  action?: ReactNode;
}) {
  return (
    <header className="picker-head">
      <button type="button" className="ghost icon" aria-label="cancel" onClick={onCancel}>
        <CloseIcon />
      </button>
      <h2 className="line">{title}</h2>
      <span className="row">{action}</span>
    </header>
  );
}

export interface MenuItem {
  label: string;
  /** A muted second line, for the state the action would act on. */
  detail?: ReactNode;
  icon: ReactNode;
  onSelect: () => void;
}

/**
 * One overflow button standing in for a row of icon buttons, opening a list
 * under it. Closes on a choice, a tap elsewhere, or Escape, so it never
 * outlives the moment it was opened for.
 */
export function Menu({ label, items, disabled }: {
  label: string;
  items: MenuItem[];
  /** Forces it shut, for when its anchor is about to fold away. */
  disabled?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  const shown = open && !disabled;

  useEffect(() => {
    if (!shown) return;
    const away = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    const key = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };
    document.addEventListener("pointerdown", away);
    document.addEventListener("keydown", key);
    return () => {
      document.removeEventListener("pointerdown", away);
      document.removeEventListener("keydown", key);
    };
  }, [shown]);

  return (
    <div className="menu" ref={root}>
      <button
        type="button"
        className="icon ghost"
        aria-label={label}
        aria-expanded={shown}
        onClick={() => setOpen(!open)}
      >
        <MoreIcon />
      </button>
      {shown ? (
        <div className="menu-popover">
          {items.map((item) => (
            <ListRowButton
              key={item.label}
              icon={item.icon}
              onClick={() => {
                setOpen(false);
                item.onSelect();
              }}
            >
              <span className="line">{item.label}</span>
              {item.detail ? <span className="muted line tail">{item.detail}</span> : null}
            </ListRowButton>
          ))}
        </div>
      ) : null}
    </div>
  );
}

/** A text input with a leading search glyph and a trailing clear button. */
export function SearchField({ value, placeholder, onChange }: {
  value: string;
  placeholder: string;
  onChange: (value: string) => void;
}) {
  const input = useRef<HTMLInputElement>(null);
  return (
    <div className="field search">
      <SearchIcon />
      <input
        ref={input}
        value={value}
        placeholder={placeholder}
        onChange={(event) => onChange(event.target.value)}
      />
      {value ? (
        <button
          type="button"
          className="ghost icon sm clear"
          aria-label="clear search"
          // Keeps focus (and the on-screen keyboard) on the field.
          onMouseDown={(event) => event.preventDefault()}
          onClick={() => {
            onChange("");
            input.current?.focus();
          }}
        >
          <CloseIcon />
        </button>
      ) : null}
    </div>
  );
}

/** A labelled rule across a scroller: a boundary in the content, not a control. */
export function Divider({ children }: { children: ReactNode }) {
  return (
    <div className="divider muted" role="separator">
      <span className="line">{children}</span>
    </div>
  );
}

/** One labelled value in a list: read, not tapped. */
export function FactRow({ label, value, path }: {
  label: string;
  value: string;
  /** Clipped from the front, as paths are everywhere else. */
  path?: boolean;
}) {
  return (
    <div className="list-row static">
      <span className="muted line">{label}</span>
      <span className={path ? "line tail" : "line"}>{path ? isolate(value) : value}</span>
    </div>
  );
}
