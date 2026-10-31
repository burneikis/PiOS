import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";

type Entry = "chat" | "drawer";

function currentEntry(): Entry | null {
  const tag = (window.history.state as { pios?: string } | null)?.pios;
  return tag === "chat" || tag === "drawer" ? tag : null;
}

function push(entry: Entry): void {
  window.history.pushState({ pios: entry }, "");
}

// Chrome's back gesture skips every entry of a page that pushed one before
// the user touched it, which sends back straight out of the app. So entries
// are only ever pushed with a fresh activation in hand.
function activated(): boolean {
  return navigator.userActivation?.isActive ?? true;
}

// WebKit turns the left-edge swipe into its own history back as soon as there
// is an entry to return to, swallowing the touches the in-app edge swipe needs
// to open the drawer. iOS has no system back button, so it gets no entries.
// iPadOS reports itself as a Mac, so touch support is the tell.
const usesHistory = !(
  /iPhone|iPad|iPod/.test(navigator.userAgent) ||
  (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
);

/**
 * Back walks drawer -> chat -> list -> out of the app. An open chat is one
 * history entry above the list, so system back from it reveals the list rather
 * than leaving; a drawer opened from the chat is one more above that, so back
 * closes it and leaves the chat, its scroll and its draft in place.
 */
export function useDrawer(chatting: boolean): [boolean, (open: boolean) => void] {
  // A reload keeps the history state, so the entry says whether it was open.
  const [open, setOpenState] = useState(() => currentEntry() === "drawer");
  const chattingNow = useRef(chatting);
  chattingNow.current = chatting;

  useEffect(() => {
    if (!usesHistory) return;
    const onPop = () => setOpenState(currentEntry() !== "chat");
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);

  // A launch straight into a session has no entry to go back to, and may not
  // push one until the first tap; capture runs before the tap's own handler.
  useLayoutEffect(() => {
    if (!usesHistory || !chatting || currentEntry() !== null) return;
    const ensure = () => {
      if (!chattingNow.current || currentEntry() !== null || !activated()) return false;
      push("chat");
      return true;
    };
    if (ensure()) return;
    const onInput = () => {
      if (ensure()) disarm();
    };
    const disarm = () => {
      window.removeEventListener("pointerup", onInput, true);
      window.removeEventListener("keydown", onInput, true);
    };
    window.addEventListener("pointerup", onInput, true);
    window.addEventListener("keydown", onInput, true);
    return disarm;
  }, [chatting]);

  const setOpen = useCallback((next: boolean) => {
    if (!usesHistory) {
      if (next) (document.activeElement as HTMLElement | null)?.blur();
      setOpenState(next);
      return;
    }
    const at = currentEntry();
    if (next) {
      // Otherwise the keyboard stays up over the list.
      (document.activeElement as HTMLElement | null)?.blur();
      if (at === "chat" && activated()) push("drawer");
      setOpenState(true);
      return;
    }
    if (at === "drawer") {
      window.history.back();
      return;
    }
    if (at === null && activated()) push("chat");
    setOpenState(false);
  }, []);

  return [chatting && open, setOpen];
}
