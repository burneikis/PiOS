import { useRef, type MouseEvent, type PointerEvent } from "react";

/** Long enough not to fire on a tap, short enough to feel deliberate. */
const HOLD_MS = 450;
/** A press that travels this far is a scroll, and scrolling must never fire. */
const SLOP_PX = 10;

/**
 * Handlers for a press-and-hold on one element.
 *
 * Pointer events rather than touch events, so a desktop right-click-free
 * long press works the same way; the context menu is suppressed because on
 * Android it lands in the middle of the hold.
 */
export interface LongPressHandlers {
  onPointerDown?: (event: PointerEvent) => void;
  onPointerMove?: (event: PointerEvent) => void;
  onPointerUp?: () => void;
  onPointerCancel?: () => void;
  onPointerLeave?: () => void;
  onContextMenu?: (event: MouseEvent) => void;
  onClick?: (event: MouseEvent) => void;
}

export function useLongPress(onFire: (() => void) | undefined): LongPressHandlers {
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const origin = useRef<{ x: number; y: number } | null>(null);
  const fired = useRef(false);

  function cancel() {
    if (timer.current !== null) clearTimeout(timer.current);
    timer.current = null;
    origin.current = null;
  }

  if (!onFire) return {};

  return {
    onPointerDown(event: PointerEvent) {
      // Secondary buttons are the platform's own menu gesture.
      if (event.button !== 0) return;
      fired.current = false;
      origin.current = { x: event.clientX, y: event.clientY };
      timer.current = setTimeout(() => {
        fired.current = true;
        cancel();
        haptic();
        onFire();
      }, HOLD_MS);
    },
    onPointerMove(event: PointerEvent) {
      const start = origin.current;
      if (!start) return;
      const travelled = Math.hypot(event.clientX - start.x, event.clientY - start.y);
      if (travelled > SLOP_PX) cancel();
    },
    onPointerUp: cancel,
    onPointerCancel: cancel,
    onPointerLeave: cancel,
    onContextMenu(event: MouseEvent) {
      event.preventDefault();
    },
    onClick(event: MouseEvent) {
      // The press already acted; the click that follows it must not.
      if (fired.current) event.preventDefault();
    },
  };
}

/**
 * Fires the platform's shortest haptic, where there is one.
 *
 * Android and desktop Chrome have the Vibration API. Safari has none, so iOS
 * gets the switch-control tick instead: toggling a `switch` checkbox is the
 * only haptic the browser exposes, and it needs a real element in the page.
 */
function haptic(): void {
  if (typeof navigator !== "undefined" && typeof navigator.vibrate === "function") {
    navigator.vibrate(10);
    return;
  }
  switchTick()?.click();
}

let tickElement: HTMLInputElement | null = null;

function switchTick(): HTMLInputElement | null {
  if (typeof document === "undefined") return null;
  if (tickElement) return tickElement;
  const input = document.createElement("input");
  input.type = "checkbox";
  input.setAttribute("switch", "");
  input.ariaHidden = "true";
  input.tabIndex = -1;
  input.style.cssText = "position:fixed;opacity:0;pointer-events:none;width:0;height:0";
  document.body.appendChild(input);
  tickElement = input;
  return input;
}
