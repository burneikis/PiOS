import Foundation

public enum AppState: String, Sendable {
    case active, inactive, background
}

/// Translates lifecycle into supervisor commands. Under ten seconds away the
/// socket probably survived and a probe is enough; over it the OS may have
/// killed it under an attempt that still looks in flight.
@MainActor
public final class AppStatePolicy {
    public static let reconnectAfterMs: Double = 10_000

    public private(set) var appState: AppState = .active
    private let supervisor: ConnectionSupervisor
    private let scheduler: Scheduler
    private var backgroundedAt: Double?

    init(supervisor: ConnectionSupervisor, scheduler: Scheduler) {
        self.supervisor = supervisor
        self.scheduler = scheduler
    }

    public func set(_ next: AppState) {
        let previous = appState
        appState = next
        if next == .background {
            backgroundedAt = scheduler.now()
            return
        }
        guard next == .active, previous != .active else { return }
        let away = backgroundedAt.map { scheduler.now() - $0 } ?? 0
        backgroundedAt = nil
        if away >= Self.reconnectAfterMs {
            supervisor.wake("application-active-reconnect")
        } else {
            supervisor.probe()
        }
    }
}

public struct ModelListing: Sendable {
    public var models: [ModelOption]
    /// The full catalogue rather than the session's scope.
    public var all: Bool
}

public struct ListQuery: Equatable, Sendable {
    public var cwd: String?
    public var query: String?
    public var limit: Int?
    public var offset: Int?

    public init(cwd: String? = nil, query: String? = nil, limit: Int? = nil, offset: Int? = nil) {
        self.cwd = cwd
        self.query = query
        self.limit = limit
        self.offset = offset
    }
}

/// Things the UI is told about once, not state it reads.
public enum ClientNotice: Sendable {
    case commandError(String)
    case rewound(branchSessionId: String, text: String)
    case exported(sessionId: String, path: String)
    case sessionsChanged
}

/// Everything above the socket, wired together.
///
/// The UI talks to this and nothing else. It cannot open a transport, write
/// to one, or schedule a retry: prompts go into the outbox, and the supervisor
/// decides when anything reaches the wire.
@MainActor
public final class PiosClient {
    /// Entries fetched at a time. A chat is read from the bottom.
    static let entryPage = 200
    private static let sessionsKey = "pios.sessions"
    private static let sessionsVersion = 1

    public let supervisor: ConnectionSupervisor
    public let sessions: SessionStore
    public let outbox: ThreadOutbox
    public let appState: AppStatePolicy
    /// Interactive shells on the machine, over the same socket.
    public private(set) var terminals: TerminalChannel!
    public let notices = Listeners<ClientNotice>()
    /// Models, commands or stats changed for a session.
    public let metadataChanged = Listeners<String>()

    private let storage: StorageAdapter
    private let generateId: () -> String
    /// Sessions the UI wants live, re-subscribed on every reconnect.
    private var subscribed: Set<String> = []
    private var lastListing = ListQuery()
    /// Commands whose failure means the transcript is stale. Only these turn
    /// into a sync error; a rejected one-off says nothing about the cache.
    private var syncCommands: Set<String> = []
    private var olderRequests: Set<String> = []
    private var models: [String: ModelListing] = [:]
    private var modelsWanted: [String: (all: Bool, create: SessionCreate?)] = [:]
    private var commandsWanted: Set<String> = []
    private var commands: [String: [CommandOption]] = [:]
    private var stats: [String: SessionStats] = [:]
    private var statsWanted: Set<String> = []
    private var rewoundText: [String: String] = [:]
    private var lastTransport: TransportHealth = .idle

    public init(
        createTransport: @escaping TransportFactory,
        storage: StorageAdapter,
        scheduler: Scheduler? = nil,
        clientVersion: String,
        generateId: @escaping () -> String = defaultId
    ) {
        let scheduler = scheduler ?? SystemScheduler()
        self.storage = storage
        self.generateId = generateId
        let supervisor = ConnectionSupervisor(
            createTransport: createTransport, scheduler: scheduler, clientVersion: clientVersion, generateId: generateId
        )
        self.supervisor = supervisor
        // Last run's list, so a cold launch shows conversations, not a blank.
        supervisor.seedSessions(
            readVersioned(storage, Self.sessionsKey, version: Self.sessionsVersion, fallback: [SessionSummary]())
        )
        sessions = SessionStore(storage: storage)
        outbox = ThreadOutbox(storage: storage, scheduler: scheduler) { [weak supervisor] entry in
            supervisor?.send(entry.command.frame(commandId: entry.commandId)) ?? false
        }
        appState = AppStatePolicy(supervisor: supervisor, scheduler: scheduler)
        terminals = TerminalChannel(
            send: { [weak supervisor] command, commandId in supervisor?.send(command.frame(commandId: commandId)) ?? false },
            generateId: generateId
        )

        supervisor.stateChanged.add { [weak self] state in self?.onSupervisorState(state) }
        supervisor.frames.add { [weak self] frame in self?.onFrame(frame) }
    }

    public func start(_ credentials: Credentials) {
        supervisor.setCredentials(credentials)
        supervisor.start()
    }

    public func stop() {
        supervisor.stop()
    }

    /// Queues a prompt; never touches the socket. The entry renders as
    /// pending at once, connection or not.
    @discardableResult
    public func prompt(
        sessionId: String, text: String, images: [ImageContent] = [], streamingBehavior: StreamingBehavior? = nil,
        create: SessionCreate? = nil
    ) -> OutboxEntry {
        outbox.enqueue(
            messageId: generateId(), commandId: generateId(), sessionId: sessionId, text: text, images: images,
            streamingBehavior: streamingBehavior, create: create
        )
    }

    /// A session id to compose against before the session exists.
    public func newSessionId() -> String { generateId() }

    @discardableResult
    public func listSessions(_ query: ListQuery = ListQuery()) -> Bool {
        lastListing = query
        return send(.listSessions(cwd: query.cwd, query: query.query, limit: query.limit, offset: query.offset))
    }

    @discardableResult
    public func refreshSessions() -> Bool { listSessions(lastListing) }

    /// Not queued: the answer depends on which providers are authenticated
    /// now, so it is re-asked after a reconnect rather than replayed.
    @discardableResult
    public func listModels(_ sessionId: String, all: Bool = false, create: SessionCreate? = nil) -> Bool {
        modelsWanted[sessionId] = (all, create)
        return send(.listModels(sessionId: sessionId, all: all, create: create))
    }

    public func models(_ sessionId: String) -> ModelListing { models[sessionId] ?? ModelListing(models: [], all: false) }

    @discardableResult
    public func listCommands(_ sessionId: String) -> Bool {
        commandsWanted.insert(sessionId)
        return send(.listCommands(sessionId: sessionId))
    }

    public func commands(_ sessionId: String) -> [CommandOption] { commands[sessionId] ?? [] }

    @discardableResult
    public func requestStats(_ sessionId: String) -> Bool {
        statsWanted.insert(sessionId)
        return send(.getStats(sessionId: sessionId))
    }

    public func stats(_ sessionId: String) -> SessionStats? { stats[sessionId] }

    @discardableResult
    public func setModel(_ sessionId: String, provider: String, modelId: String) -> Bool {
        send(.setModel(sessionId: sessionId, provider: provider, modelId: modelId))
    }

    @discardableResult
    public func setThinkingLevel(_ sessionId: String, _ level: String) -> Bool {
        send(.setThinkingLevel(sessionId: sessionId, level: level))
    }

    @discardableResult
    public func setSessionName(_ sessionId: String, _ name: String) -> Bool {
        send(.setSessionName(sessionId: sessionId, name: name))
    }

    @discardableResult
    public func compact(_ sessionId: String, instructions: String? = nil) -> Bool {
        send(.compact(sessionId: sessionId, customInstructions: instructions?.isEmpty == false ? instructions : nil))
    }

    @discardableResult
    public func setAutoCompaction(_ sessionId: String, _ enabled: Bool) -> Bool {
        send(.setAutoCompaction(sessionId: sessionId, enabled: enabled))
    }

    @discardableResult
    public func reload(_ sessionId: String) -> Bool { send(.reloadSession(sessionId: sessionId)) }

    @discardableResult
    public func exportSession(_ sessionId: String, path: String? = nil) -> Bool {
        send(.exportSession(sessionId: sessionId, outputPath: path?.isEmpty == false ? path : nil))
    }

    @discardableResult
    public func setSessionTrust(_ sessionId: String, _ trust: Bool) -> Bool {
        send(.setSessionTrust(sessionId: sessionId, trustProject: trust))
    }

    /// Advisory: decides whether a settled session needs a push. Never queued.
    @discardableResult
    public func reportActivity(visible: Bool, focused: Bool, appState: AppState, sessionIds: [String]? = nil) -> Bool {
        send(.activity(visible: visible, focused: focused, appState: appState.rawValue, sessionIds: sessionIds ?? Array(subscribed)))
    }

    @discardableResult
    public func rewind(_ sessionId: String, entryId: String) -> Bool {
        send(.rewind(sessionId: sessionId, entryId: entryId))
    }

    /// Claims the text a rewind left for a session, once only.
    public func takeRewoundText(_ sessionId: String) -> String? {
        rewoundText.removeValue(forKey: sessionId)
    }

    /// Marked locally as well as sent: a stop is not instant, and a button
    /// that looks idle again reads as "nothing happened".
    @discardableResult
    public func interrupt(_ sessionId: String) -> Bool {
        let sent = send(.interrupt(sessionId: sessionId))
        if sent { sessions.setInterrupting(sessionId, true) }
        return sent
    }

    /// Not queued: a command replayed later runs against a tree that moved on.
    @discardableResult
    public func runBash(_ sessionId: String, _ command: String, excludeFromContext: Bool = false) -> Bool {
        send(.runBash(sessionId: sessionId, command: command, excludeFromContext: excludeFromContext))
    }

    @discardableResult
    public func abortBash(_ sessionId: String) -> Bool { send(.abortBash(sessionId: sessionId)) }

    /// Closed locally on send: the agent is blocked meanwhile, and a sheet
    /// that lingers invites a second answer.
    @discardableResult
    public func answerDialog(_ sessionId: String, requestId: String, value: String? = nil, confirmed: Bool? = nil, cancelled: Bool? = nil) -> Bool {
        let sent = send(.extensionUiResponse(sessionId: sessionId, requestId: requestId, value: value, confirmed: confirmed, cancelled: cancelled))
        if sent { sessions.closeDialog(sessionId, requestId) }
        return sent
    }

    /// Marks a session live: subscribed now and after every reconnect.
    public func watch(_ sessionId: String) {
        subscribed.insert(sessionId)
        if supervisor.state.transport == .connected { resync(sessionId) }
    }

    public func unwatch(_ sessionId: String) {
        subscribed.remove(sessionId)
        // Re-asking these wakes the agent, which only a session on screen earns.
        modelsWanted[sessionId] = nil
        commandsWanted.remove(sessionId)
        send(.unsubscribe(sessionId: sessionId))
    }

    public func view(_ sessionId: String) -> SessionView {
        sessionView(store: sessions, outbox: outbox.entries, sessionId: sessionId)
    }

    /// Fetches the page of history above what is held.
    @discardableResult
    public func loadOlderEntries(_ sessionId: String) -> Bool {
        guard sessions.hasOlder(sessionId) else { return false }
        let commandId = generateId()
        olderRequests.insert(commandId)
        return send(
            .getEntries(sessionId: sessionId, since: nil, limit: Self.entryPage, before: sessions.firstHeldIndex(sessionId)),
            commandId: commandId
        )
    }

    @discardableResult
    private func send(_ command: ClientCommand, commandId: String? = nil) -> Bool {
        supervisor.send(command.frame(commandId: commandId ?? generateId()))
    }

    private func onSupervisorState(_ state: SupervisorState) {
        let previous = lastTransport
        lastTransport = state.transport
        // Only the transition into `connected`: reacting to every emission
        // would resync on the sync-status change that resyncing produces.
        guard state.transport == .connected, previous != .connected else { return }
        for sessionId in subscribed {
            resync(sessionId)
            if statsWanted.contains(sessionId) { send(.getStats(sessionId: sessionId)) }
            if commandsWanted.contains(sessionId) { send(.listCommands(sessionId: sessionId)) }
        }
        // Not scoped to subscriptions: a draft asks for models before it exists.
        for (sessionId, wanted) in modelsWanted {
            send(.listModels(sessionId: sessionId, all: wanted.all, create: wanted.create))
        }
        terminals.reconnected()
        outbox.drain()
    }

    /// Brings one session back in step. The daemon's `leafId` decides: if the
    /// branch moved, the transcript is refetched rather than patched.
    private func resync(_ sessionId: String) {
        let summary = supervisor.state.sessions.first { $0.sessionId == sessionId }
        let diverged = summary.map { sessions.needsFullRefetch(sessionId, leafId: $0.leafId) } ?? false
        if diverged { sessions.clear(sessionId) }
        let cursor = diverged ? nil : sessions.cursor(sessionId)

        supervisor.setSyncStatus(.syncing)
        let subscribeId = generateId()
        syncCommands.insert(subscribeId)
        fetchEntries(sessionId, cursor: cursor)
        send(.subscribe(sessionId: sessionId, sinceSeq: sessions.lastSeq(sessionId)), commandId: subscribeId)
    }

    /// With no cursor this is a first load, which takes the tail rather than
    /// the whole transcript.
    private func fetchEntries(_ sessionId: String, cursor: String?) {
        let commandId = generateId()
        syncCommands.insert(commandId)
        send(
            .getEntries(sessionId: sessionId, since: cursor, limit: cursor == nil ? Self.entryPage : nil, before: nil),
            commandId: commandId
        )
    }

    private func fetchNewEntries(_ sessionId: String) {
        if subscribed.contains(sessionId) { fetchEntries(sessionId, cursor: sessions.cursor(sessionId)) }
    }

    private func persistSessions() {
        writeVersioned(storage, Self.sessionsKey, version: Self.sessionsVersion, supervisor.state.sessions)
    }

    private func onFrame(_ frame: ServerFrame) {
        if terminals.onFrame(frame) { return }
        switch frame.body {
        case let .ack(commandId, _):
            outbox.acknowledge(commandId)
        case let .error(code, message):
            onError(frame.commandId, code: code, message: message)
        case let .entries(sessionId, entries, leafId, reset, offset, total):
            if let id = frame.commandId, olderRequests.remove(id) != nil {
                sessions.applyOlderEntries(sessionId, entries: entries, offset: offset, total: total)
                return
            }
            if let id = frame.commandId { syncCommands.remove(id) }
            sessions.applyEntries(sessionId, entries: entries, leafId: leafId, reset: reset, offset: offset, total: total)
            supervisor.setSyncStatus(.synced)
        case let .subscribed(sessionId, seq, gap):
            if let id = frame.commandId { syncCommands.remove(id) }
            // Evicted events leave the live transcript missing a middle.
            if gap { sessions.resetLiveTranscript(sessionId) } else { sessions.setLastSeq(sessionId, seq) }
        case let .agentEvent(sessionId, seq, at, event):
            sessions.applyEvent(sessionId, seq: seq, event: event, at: at)
            // A settled turn is on disk, so its entry ids exist; a manual
            // compaction ends without a turn and its entry is the marker.
            switch event {
            case .agentSettled, .compactionEnd: fetchNewEntries(sessionId)
            default: break
            }
        case let .sessionState(summary):
            sessions.setDaemonStatus(summary.sessionId, summary.status)
        case let .welcome(_, _, summaries):
            for summary in summaries { sessions.setDaemonStatus(summary.sessionId, summary.status) }
            // The list is a disk read the daemon does not do unasked.
            listSessions(lastListing)
        case let .sessions(summaries, _, _, _):
            for summary in summaries { sessions.setDaemonStatus(summary.sessionId, summary.status) }
            persistSessions()
        case .sessionsChanged:
            notices.emit(.sessionsChanged)
        case let .commands(sessionId, list):
            commands[sessionId] = list
            metadataChanged.emit(sessionId)
        case let .sessionStats(sessionId, value):
            stats[sessionId] = value
            metadataChanged.emit(sessionId)
        case let .models(sessionId, list, all):
            models[sessionId] = ModelListing(models: list, all: all)
            metadataChanged.emit(sessionId)
        case let .extensionUiRequest(sessionId, request):
            // Only a dialog blocks the agent, and only a dialog gets a sheet.
            if request.isDialog {
                sessions.openDialog(sessionId, request)
            } else {
                sessions.applyPresentationRequest(sessionId, request)
            }
        case let .extensionUiState(sessionId, presentation):
            sessions.setPresentation(sessionId, presentation)
        case let .extensionUiClosed(sessionId, requestId):
            sessions.closeDialog(sessionId, requestId)
        case let .bashState(sessionId, command, exclude, running, result):
            if running {
                sessions.startBash(sessionId, command: command, excludeFromContext: exclude)
            } else {
                sessions.finishBash(sessionId, result: result ?? BashResult())
                // pi persists the run as an entry and no `agent_settled`
                // follows a bare command, so nothing else would fetch it.
                fetchNewEntries(sessionId)
            }
        case let .rewound(_, branch, text):
            rewoundText[branch] = text ?? ""
            notices.emit(.rewound(branchSessionId: branch, text: text ?? ""))
        case let .exported(sessionId, path):
            notices.emit(.exported(sessionId: sessionId, path: path))
        case let .sessionRecovered(sessionId, leafId, _):
            // The process was replaced. Whether the transcript moved is decided
            // by the leaf it came back with.
            if sessions.needsFullRefetch(sessionId, leafId: leafId) { sessions.clear(sessionId) }
            if subscribed.contains(sessionId) { resync(sessionId) }
            if commandsWanted.contains(sessionId) { send(.listCommands(sessionId: sessionId)) }
        case .unhandled, .terminalAttached, .terminalOutput, .terminalExit:
            break
        }
    }

    private func onError(_ commandId: String?, code: ErrorCode, message: String) {
        if let commandId, terminals.onError(commandId, message: message) { return }
        let queued = commandId.map { outbox.reject($0, error: message) } ?? false
        let isSync = commandId.map { syncCommands.remove($0) != nil } ?? false
        guard code != .unauthorized else { return }
        // A failed resync on a healthy socket is a sync problem, not a
        // transport one, and must not trigger a reconnect.
        if isSync {
            supervisor.setSyncStatus(.error)
        } else if !queued {
            notices.emit(.commandError(message))
        }
    }
}
