/**
 * Copies text, falling back to a selection copy where the async API is
 * missing: a daemon reached over plain HTTP on the LAN is not a secure
 * context, and there `navigator.clipboard` does not exist at all.
 */
export async function copyText(text: string): Promise<boolean> {
  if (navigator.clipboard && window.isSecureContext) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {
      // Denied, e.g. outside a gesture; the selection copy may still work.
    }
  }
  return selectionCopy(text);
}

/**
 * Reads clipboard text, or null where it cannot be read: outside a secure
 * context there is no API, and the user may decline the system prompt.
 */
export async function readText(): Promise<string | null> {
  if (!navigator.clipboard?.readText || !window.isSecureContext) return null;
  try {
    return await navigator.clipboard.readText();
  } catch {
    return null;
  }
}

function selectionCopy(text: string): boolean {
  const previous = document.activeElement as HTMLElement | null;
  const box = document.createElement("textarea");
  box.value = text;
  // Read-only and off screen, so a phone neither raises its keyboard nor
  // scrolls to the field.
  box.readOnly = true;
  box.style.position = "fixed";
  box.style.top = "-1000px";
  document.body.append(box);
  box.select();
  box.setSelectionRange(0, text.length);
  let copied = false;
  try {
    copied = document.execCommand("copy");
  } catch {
    copied = false;
  }
  box.remove();
  previous?.focus?.();
  return copied;
}
