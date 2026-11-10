import { createServer, type Server } from "node:http";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { WebSocketServer } from "ws";
import { SessionIndex, SessionRegistry, type SessionHost } from "@pios/pi-host";
import { AuthStore } from "./auth.ts";
import { CommandLedger } from "./dedupe.ts";
import { Connection } from "./connection.ts";
import { handleRequest } from "./http-routes.ts";
import { ImageStore } from "./image-store.ts";
import { advertisedEndpoint, type Endpoint } from "./endpoints.ts";
import { RelayConnector } from "./relay-connector.ts";
import { RelayKey } from "./relay-key.ts";
import { createSessionHost } from "./session-host.ts";
import { SettleNotifier, type Notification } from "./notifier.ts";
import { ExternalTurnNotifier } from "./external-turns.ts";
import { PushStore } from "./push.ts";
import { SessionStoreWatcher } from "./store-watcher.ts";
import { TerminalHost, type TerminalHostOptions } from "./terminals.ts";
import { TrustStore } from "./trust.ts";
import { ClaudeUsage } from "./usage.ts";
import {
  authStorePath,
  defaultConfig,
  pushStorePath,
  relayKeyPath,
  type ServerConfig,
} from "./config.ts";

export interface PiosServerOptions extends Partial<ServerConfig> {
  /** Overridable so tests can run without spawning real pi. */
  sessionHost?: SessionHost;
  /** pi's version, reported in `welcome` so a client can spot a mismatch. */
  piVersion?: string;
  /** Overridable so tests do not touch the real session directory. */
  index?: SessionIndex;
  /** Overridable so tests and the sandbox get a predictable shell. */
  terminals?: TerminalHostOptions;
}

export class PiosServer {
  readonly config: ServerConfig;
  readonly auth: AuthStore;
  readonly registry: SessionRegistry;
  readonly push: PushStore;
  readonly images: ImageStore;
  readonly usage: ClaudeUsage;
  readonly terminals: TerminalHost;

  private readonly http: Server;
  private readonly wss: WebSocketServer;
  private readonly ledger = new CommandLedger();
  private readonly connections = new Set<Connection>();
  private readonly index: SessionIndex;
  private readonly trust: TrustStore;
  private readonly watcher: SessionStoreWatcher;
  private readonly notifier: SettleNotifier;
  private readonly externalTurns: ExternalTurnNotifier;
  private relayConnector: RelayConnector | null = null;

  constructor(options: PiosServerOptions = {}) {
    this.config = defaultConfig(options);
    mkdirSync(this.config.dataDir, { recursive: true, mode: 0o700 });
    mkdirSync(this.config.sessionDir, { recursive: true });

    this.auth = new AuthStore(authStorePath(this.config));
    this.index =
      options.index ??
      new SessionIndex({
        sessionDir: this.config.sessionDir,
        cacheFile: join(this.config.dataDir, "session-index.json"),
      });
    this.trust = new TrustStore(this.config.agentDir);
    // A change on disk invalidates what was skimmed for it and nudges every
    // client; the TUI writes to the same store this daemon reads.
    // Records are checked against mtime and size on every read, so a change
    // only needs the nudge; a turn that ended in the TUI needs a push.
    this.watcher = new SessionStoreWatcher(this.config.sessionDir, (files) => {
      this.announceSessions();
      this.externalTurns.changed(files);
    });
    this.push = new PushStore(pushStorePath(this.config), this.config.pushSubject);
    this.images = new ImageStore(join(this.config.dataDir, "images"));
    this.terminals = new TerminalHost(options.terminals);
    this.usage = new ClaudeUsage({
      authPath: join(this.config.agentDir, "auth.json"),
      cachePath: this.config.usageCachePath,
    });
    this.notifier = new SettleNotifier({
      send: (notification) => this.sendPush(notification),
      watchers: (sessionId) => this.watchers(sessionId),
    });
    this.externalTurns = new ExternalTurnNotifier({
      index: this.index,
      isLive: (sessionId) => {
        const status = this.registry.get(sessionId)?.info.status;
        return status !== undefined && status !== "cold";
      },
      watchers: (sessionId) => this.watchers(sessionId),
      send: (notification) => this.sendPush(notification),
    });
    this.registry = new SessionRegistry(
      options.sessionHost ?? createSessionHost(this.config),
      {
        idleMs: this.config.sessionIdleMs,
        onCreate: (session) => {
          this.notifier.attach(session);
          for (const connection of this.connections) connection.attachPending(session);
        },
        onDispose: (id) => this.notifier.release(id),
      },
    );

    this.http = createServer((req, res) =>
      void handleRequest(
        {
          config: this.config,
          auth: this.auth,
          registry: this.registry,
          index: this.index,
          push: this.push,
          images: this.images,
          usage: this.usage,
        },
        req,
        res,
      ),
    );

    // No automatic upgrade handling: every socket must reach `hello` before
    // it can do anything, and that check lives in Connection.
    this.wss = new WebSocketServer({ server: this.http, path: "/ws" });
    this.wss.on("connection", (socket) => {
      const connection = new Connection(socket, {
        auth: this.auth,
        registry: this.registry,
        ledger: this.ledger,
        piVersion: options.piVersion ?? "unknown",
        helloTimeoutMs: this.config.helloTimeoutMs,
        index: this.index,
        trust: this.trust,
        announceSessions: () => this.announceSessions(),
        images: this.images,
        terminals: this.terminals,
      });
      this.connections.add(connection);
      socket.on("close", () => this.connections.delete(connection));
    });
  }

  async listen(): Promise<number> {
    await new Promise<void>((resolve) => this.http.listen(this.config.port, this.config.host, resolve));
    // Warmed before anyone asks, so the first session list is instant rather
    // than a scan of every project the user has ever worked in.
    void this.index.warm();
    await this.watcher.start();
    this.startRelay();
    return this.port;
  }

  get relay(): RelayConnector | null {
    return this.relayConnector;
  }

  private startRelay(): void {
    const relayUrl = this.config.relayUrl;
    if (!relayUrl) return;
    const wildcard = this.config.host === "0.0.0.0" || this.config.host === "::";
    this.relayConnector = new RelayConnector({
      relayUrl,
      key: RelayKey.loadOrCreate(relayKeyPath(this.config)),
      local: { host: wildcard ? "127.0.0.1" : this.config.host, port: this.port },
      onKeyReplaced: () =>
        void this.push
          .send({
            title: "PiOS relay key replaced",
            body: "Another host enrolled at your relay. If that was not you, rotate ENROLL_SECRET.",
            url: "/",
            tag: "pios-relay-key",
          })
          .catch((error: unknown) => console.error("[pios] push failed", error)),
    });
    this.relayConnector.start();
  }

  get port(): number {
    const address = this.http.address();
    return typeof address === "object" && address ? address.port : this.config.port;
  }

  /** Devices whose client is watching the session right now. */
  private watchers(sessionId: string): Set<string> {
    const found = new Set<string>();
    for (const connection of this.connections) {
      const deviceId = connection.deviceId;
      if (deviceId && connection.watching(sessionId, this.config.activityTtlMs)) found.add(deviceId);
    }
    return found;
  }

  private async sendPush(notification: Notification): Promise<void> {
    try {
      await this.push.send(notification.message, notification.skipDeviceIds);
    } catch (error) {
      console.error("[pios] push failed", error);
    }
  }

  private announceSessions(): void {
    for (const connection of this.connections) connection.sendSessions();
  }

  endpoint(): Endpoint {
    return advertisedEndpoint(this.port, this.config.relayUrl, this.config.publicUrl);
  }

  async close(): Promise<void> {
    await this.relayConnector?.stop();
    this.watcher.stop();
    this.externalTurns.stop();
    this.notifier.releaseAll();
    this.terminals.closeAll();
    await this.registry.disposeAll();
    for (const client of this.wss.clients) client.terminate();
    await new Promise<void>((resolve) => this.wss.close(() => resolve()));
    await new Promise<void>((resolve) => this.http.close(() => resolve()));
  }
}
