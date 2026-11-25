import {
  PiosClient,
  sessionView,
  webSocketTransport,
  type OutboxEntry,
  type SessionView,
  type SupervisorState,
} from "@pios/client-core";
import { createContext, useContext, useEffect, useMemo, useReducer, useState } from "react";
import type { ReactNode } from "react";
import { browserStorage } from "./storage.ts";

const ClientContext = createContext<PiosClient | null>(null);

/**
 * One client for the whole app.
 *
 * Created once and kept across machine switches, because it owns the only
 * retry ladder and the outbox: rebuilding it on every credential change would
 * drop queued prompts on the floor.
 */
export function ClientProvider({ url, token, children }: {
  url: string | null;
  token: string | null;
  children: ReactNode;
}) {
  const [client] = useState(
    () =>
      new PiosClient({
        createTransport: webSocketTransport(WebSocket),
        storage: browserStorage,
        clientVersion: "web-0.0.0",
      }),
  );

  useEffect(() => {
    if (!url || !token) {
      client.supervisor.setCredentials(null);
      return;
    }
    client.start({ url, deviceToken: token });
  }, [client, url, token]);

  useEffect(() => {
    const online = () => client.supervisor.setOnline(true);
    const offline = () => client.supervisor.setOnline(false);
    const visibility = () =>
      client.appState.set(document.visibilityState === "visible" ? "active" : "background");

    client.supervisor.setOnline(navigator.onLine);
    window.addEventListener("online", online);
    window.addEventListener("offline", offline);
    document.addEventListener("visibilitychange", visibility);
    return () => {
      window.removeEventListener("online", online);
      window.removeEventListener("offline", offline);
      document.removeEventListener("visibilitychange", visibility);
    };
  }, [client]);

  return <ClientContext.Provider value={client}>{children}</ClientContext.Provider>;
}

export function useClient(): PiosClient {
  const client = useContext(ClientContext);
  if (!client) throw new Error("useClient outside ClientProvider");
  return client;
}

export function useSupervisorState(): SupervisorState {
  const client = useClient();
  const [state, setState] = useState<SupervisorState>(() => client.supervisor.getState());
  useEffect(() => client.supervisor.subscribe(setState), [client]);
  return state;
}

/** Ids of the shells running on the machine, from any device. */
export function useLiveTerminals(): ReadonlySet<string> {
  const client = useClient();
  const [ids, setIds] = useState<ReadonlySet<string>>(() => new Set(client.terminals.live().keys()));
  useEffect(() => {
    setIds(new Set(client.terminals.live().keys()));
    return client.terminals.subscribeLive((running) => setIds(new Set(running.keys())));
  }, [client]);
  return ids;
}

function useOutbox(): OutboxEntry[] {
  const client = useClient();
  const [entries, setEntries] = useState<OutboxEntry[]>(() => client.outbox.list());
  useEffect(() => client.outbox.subscribe(setEntries), [client]);
  return entries;
}

/**
 * The rendered transcript for one session.
 *
 * Recomputed on a bumped counter rather than handed out by an external store:
 * the view is rebuilt on every read, so identity-based subscriptions would
 * re-render forever.
 */
export function useSessionView(sessionId: string | null): SessionView | null {
  const client = useClient();
  const outbox = useOutbox();
  const [version, bump] = useReducer((n: number) => n + 1, 0);

  // At most one rebuild per frame. Opening a running session replays its
  // whole turn as hundreds of deltas, and a render per delta keeps the main
  // thread busy long enough that scrolling stalls.
  useEffect(() => {
    if (!sessionId) return;
    let frame: number | null = null;
    const off = client.sessions.subscribe((changed) => {
      if (changed !== sessionId || frame !== null) return;
      frame = requestAnimationFrame(() => {
        frame = null;
        bump();
      });
    });
    return () => {
      off();
      if (frame !== null) cancelAnimationFrame(frame);
    };
  }, [client, sessionId]);

  useEffect(() => {
    if (!sessionId) return;
    client.watch(sessionId);
    return () => client.unwatch(sessionId);
  }, [client, sessionId]);

  return useMemo(
    () => (sessionId ? sessionView(client.sessions, outbox, sessionId) : null),
    // `version` is the whole point: it is what marks the view stale.
    [client, sessionId, outbox, version],
  );
}
