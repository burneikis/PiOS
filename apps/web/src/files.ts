import { createContext, useContext, useEffect, useState } from "react";

export interface FileAccess {
  /** HTTP origin of the daemon, or null while no endpoint is chosen. */
  baseUrl: string | null;
  deviceToken: string;
  /** Session whose cwd a relative path is resolved against. */
  sessionId: string;
  /** Set for a draft, which has a directory before it has a session. */
  cwd?: string;
}

/** Query naming the project a file request is about. */
export function projectQuery(access: FileAccess): string {
  const session = `session=${encodeURIComponent(access.sessionId)}`;
  return access.cwd ? `${session}&cwd=${encodeURIComponent(access.cwd)}` : session;
}

export const FileAccessContext = createContext<FileAccess | null>(null);

export function useFileAccess(): FileAccess | null {
  return useContext(FileAccessContext);
}

/** Paths the browser can load on its own; everything else goes through /file. */
export function isDirectSrc(src: string): boolean {
  return /^(https?:|data:|blob:)/i.test(src);
}

/** Prefix of an image the daemon holds by name rather than by path. */
export const IMAGE_REF = "pios-image:";

const cache = new Map<string, string>();

/**
 * Object URL for a file served by the daemon.
 *
 * `/file` needs a bearer token, and an `<img src>` cannot carry one, so the
 * bytes are fetched and handed to the DOM as a blob. Object URLs are cached
 * per request URL and never revoked: the same image reappears on every
 * re-render of the transcript, and a revoked URL renders as a broken image.
 */
export function useFileObjectUrl(path: string | null): {
  url: string | null;
  error: string | null;
} {
  const access = useFileAccess();
  const key =
    access?.baseUrl && path
      ? path.startsWith(IMAGE_REF)
        ? `${access.baseUrl}/image?name=${encodeURIComponent(path.slice(IMAGE_REF.length))}`
        : `${access.baseUrl}/file?${projectQuery(access)}&path=${encodeURIComponent(path)}`
      : null;
  const [url, setUrl] = useState<string | null>(() => (key ? (cache.get(key) ?? null) : null));
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!key || !access) {
      setUrl(null);
      return;
    }
    const hit = cache.get(key);
    if (hit) {
      setUrl(hit);
      setError(null);
      return;
    }

    let live = true;
    setUrl(null);
    setError(null);
    void (async () => {
      try {
        const response = await fetch(key, {
          headers: { authorization: `Bearer ${access.deviceToken}` },
        });
        if (!response.ok) throw new Error(response.status === 404 ? "not found" : "unavailable");
        const objectUrl = URL.createObjectURL(await response.blob());
        cache.set(key, objectUrl);
        if (live) setUrl(objectUrl);
      } catch (cause) {
        if (live) setError(cause instanceof Error ? cause.message : "unavailable");
      }
    })();
    return () => {
      live = false;
    };
  }, [key, access?.deviceToken]);

  return { url, error };
}

/** Saves a file from the project to this device. */
export async function downloadFile(access: FileAccess, path: string): Promise<void> {
  await saveToDevice(await fetchFile(access, path));
}

export async function fetchFile(access: FileAccess, path: string): Promise<File> {
  if (!access.baseUrl) throw new Error("not connected");
  const url = `${access.baseUrl}/file?${projectQuery(access)}&path=${encodeURIComponent(path)}`;
  const response = await fetch(url, {
    headers: { authorization: `Bearer ${access.deviceToken}` },
  });
  if (!response.ok) throw new Error(response.status === 404 ? "not found" : "unavailable");
  const type = response.headers.get("content-type") ?? "application/octet-stream";
  return new File([await response.arrayBuffer()], path.split("/").at(-1) || "download", { type });
}

/**
 * Hands a file to the platform: the share sheet on a phone, a download
 * elsewhere.
 *
 * An installed iOS app has no usable download for a blob, so "Save to Files"
 * in the share sheet is the way out. Sharing needs a fresh tap, so call this
 * synchronously from one; without it the share is refused and this falls back
 * to a download.
 */
export async function saveToDevice(file: File): Promise<void> {
  const touch = typeof matchMedia === "function" && matchMedia("(pointer: coarse)").matches;
  if (touch && navigator.canShare?.({ files: [file] })) {
    try {
      await navigator.share({ files: [file] });
      return;
    } catch (cause) {
      if (cause instanceof DOMException && cause.name === "AbortError") return;
    }
  }
  triggerDownload(file);
}

/**
 * Typed as opaque bytes rather than the file's own type: a blob URL shares
 * the app's origin, and an HTML file rendered there could run as the app.
 */
function triggerDownload(file: File): void {
  const objectUrl = URL.createObjectURL(new Blob([file], { type: "application/octet-stream" }));
  const link = document.createElement("a");
  link.href = objectUrl;
  link.download = file.name;
  document.body.append(link);
  link.click();
  link.remove();
  // Long enough for the browser to have started reading it.
  setTimeout(() => URL.revokeObjectURL(objectUrl), 60_000);
}
