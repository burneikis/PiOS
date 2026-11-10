import Foundation

/// How the socket is doing. Never inferred from cached data.
public enum TransportHealth: String, Sendable {
    case idle, offline, connecting, connected, waiting, blocked
}

/// Whether the data is current. Separate from transport health: a healthy
/// socket whose subscription failed is "connected, sync error".
public enum SyncStatus: String, Sendable {
    case idle, syncing, synced, error
}

public struct SupervisorState: Sendable {
    public var transport: TransportHealth = .idle
    public var sync: SyncStatus = .idle
    /// Why it is blocked or waiting, so the UI can say rather than spin.
    public var reason: String?
    public var sessions: [SessionSummary] = []
    public var sessionsTotal = 0
    public var hasMoreSessions = false
    public var attempts = 0
    /// The relay is up but the machine behind it is not.
    public var hostOffline = false
    public var serverVersion: String?
    public var piVersion: String?
}

public struct Credentials: Equatable, Sendable {
    public var url: URL
    public var deviceToken: String

    public init(url: URL, deviceToken: String) {
        self.url = url
        self.deviceToken = deviceToken
    }
}

/// The single retry owner.
///
/// Nothing else opens a socket, schedules a reconnect, or decides that a
/// connection is healthy. Two ladders racing is how reconnect storms happen.
@MainActor
public final class ConnectionSupervisor {
    public static let stableAfterMs: Double = 30_000

    public private(set) var state = SupervisorState()
    public let stateChanged = Listeners<SupervisorState>()
    public let frames = Listeners<ServerFrame>()

    private let createTransport: TransportFactory
    private let scheduler: Scheduler
    private let clientVersion: String
    private let generateId: () -> String
    private var backoff: Backoff
    private var credentials: Credentials?
    private var transport: Transport?
    private var retryTimer: TimerHandle?
    private var stableTimer: TimerHandle?
    private var online = true
    private var started = false
    /// Guards against an in-flight attempt being duplicated by a wakeup.
    private var connecting = false
    private var generation = 0

    public init(
        createTransport: @escaping TransportFactory,
        scheduler: Scheduler,
        backoff: Backoff = Backoff(),
        clientVersion: String,
        generateId: @escaping () -> String = defaultId
    ) {
        self.createTransport = createTransport
        self.scheduler = scheduler
        self.backoff = backoff
        self.clientVersion = clientVersion
        self.generateId = generateId
    }

    public func setCredentials(_ next: Credentials?) {
        let changed = next != credentials
        credentials = next
        guard changed else { return }
        // New inputs are the only thing that clears a block: retrying a
        // rejected token forever is a busy loop with extra steps.
        if state.transport == .blocked {
            patch { $0.transport = .idle; $0.reason = nil }
            backoff.reset()
            if started { connect() }
        } else if started {
            reconnect("credentials changed")
        }
    }

    public func start() {
        guard !started else { return }
        started = true
        connect()
    }

    public func stop() {
        started = false
        clearTimers()
        dropTransport()
        patch { $0.transport = .idle; $0.sync = .idle }
    }

    /// Offline releases the connection and arms nothing: burning the ladder
    /// against a radio known to be off leaves it at 16s when signal returns.
    public func setOnline(_ value: Bool) {
        guard online != value else { return }
        online = value
        if !value {
            clearTimers()
            dropTransport()
            patch { $0.transport = .offline; $0.sync = .idle }
            return
        }
        backoff.reset()
        if started { connect() }
    }

    /// Foreground after a long background: the OS may have killed the socket
    /// under an attempt that still looks in flight, so start clean.
    public func wake(_ reason: String) {
        guard started, online, state.transport != .blocked else { return }
        backoff.reset()
        reconnect(reason)
    }

    /// A cheap check after a short background.
    public func probe() {
        guard state.transport != .connected, started, online, state.transport != .connecting else { return }
        wake("probe")
    }

    @discardableResult
    public func send(_ frame: JSON) -> Bool {
        guard let transport, state.transport == .connected else { return false }
        transport.send(frame.encodedString())
        return true
    }

    public func setSyncStatus(_ sync: SyncStatus) {
        guard state.sync != sync else { return }
        patch { $0.sync = sync }
    }

    /// The list from a previous run, shown before the socket is up. Rendering
    /// only: the daemon's first page replaces it wholesale.
    public func seedSessions(_ sessions: [SessionSummary]) {
        guard state.sessions.isEmpty, !sessions.isEmpty else { return }
        patch { $0.sessions = sessions }
    }

    private func connect() {
        guard started, !connecting else { return }
        guard online else { return patch { $0.transport = .offline } }
        guard state.transport != .blocked else { return }
        // A missing token is configuration, not network: block, never retry.
        guard let credentials else { return block("not paired") }

        connecting = true
        clearRetryTimer()
        patch { $0.transport = .connecting; $0.attempts = self.backoff.attempts }

        generation += 1
        let generation = generation
        let createTransport = createTransport
        Task { @MainActor [weak self] in
            do {
                let transport = try await createTransport(credentials.url)
                guard let self, generation == self.generation else { return transport.close() }
                self.transport = transport
                transport.onMessage = { [weak self] text in self?.receive(generation, text) }
                transport.onClose = { [weak self] code, reason in self?.closed(generation, code, reason) }
                // Open is not connected: the hello round trip must succeed.
                transport.send(
                    ClientCommand.hello(deviceToken: credentials.deviceToken, clientVersion: self.clientVersion)
                        .frame(commandId: self.generateId()).encodedString()
                )
            } catch {
                guard let self, generation == self.generation else { return }
                self.connecting = false
                if let refused = error as? TransportRefused {
                    if authCloseCodes.contains(refused.code) { return self.block(refused.reason) }
                    self.patch { $0.hostOffline = refused.code == hostOfflineCloseCode }
                    return self.scheduleRetry(refused.reason)
                }
                self.scheduleRetry(error.localizedDescription)
            }
        }
    }

    private func receive(_ generation: Int, _ text: String) {
        guard generation == self.generation else { return }
        let frame: ServerFrame
        do {
            frame = try ServerFrame(text: text)
        } catch ServerFrame.ParseError.versionMismatch(let version) {
            return block("daemon speaks wire v\(version.map(String.init) ?? "?"), this app v\(wireVersion)")
        } catch {
            // A frame this build cannot parse is dropped, not fatal.
            return
        }

        switch frame.body {
        case let .welcome(serverVersion, piVersion, sessions):
            connecting = false
            patch {
                $0.transport = .connected
                $0.reason = nil
                $0.hostOffline = false
                $0.serverVersion = serverVersion
                $0.piVersion = piVersion
                $0.attempts = self.backoff.attempts
                // The welcome lists live processes only; keep a seeded list
                // until the first page arrives rather than flashing it empty.
                if !sessions.isEmpty { $0.sessions = merge($0.sessions, sessions) }
            }
            // The ladder resets only once the connection proves it can hold.
            stableTimer = scheduler.after(Self.stableAfterMs) { [weak self] in
                guard let self else { return }
                self.stableTimer = nil
                self.backoff.reset()
                self.patch { $0.attempts = 0 }
            }
        case let .sessions(page, offset, total, hasMore):
            patch {
                $0.sessions = offset == 0 ? page : merge($0.sessions, page)
                $0.sessionsTotal = total
                $0.hasMoreSessions = hasMore
            }
        case let .sessionState(summary):
            patch { $0.sessions = merge($0.sessions, [summary]) }
        case .error(.unauthorized, _):
            return block("unauthorized")
        default:
            break
        }
        frames.emit(frame)
    }

    private func closed(_ generation: Int, _ code: Int, _ reason: String) {
        guard generation == self.generation else { return }
        connecting = false
        transport = nil
        clearStableTimer()
        if authCloseCodes.contains(code) { return block(reason.isEmpty ? "unauthorized" : reason) }
        guard online else { return patch { $0.transport = .offline; $0.sync = .idle } }
        patch {
            $0.sync = .idle
            $0.hostOffline = code == hostOfflineCloseCode
        }
        scheduleRetry(reason.isEmpty ? "closed \(code)" : reason)
    }

    private func scheduleRetry(_ reason: String) {
        guard started, online else { return }
        let delay = backoff.next()
        patch { $0.transport = .waiting; $0.attempts = self.backoff.attempts; $0.reason = reason }
        retryTimer = scheduler.after(delay) { [weak self] in
            self?.retryTimer = nil
            self?.connect()
        }
    }

    private func block(_ reason: String) {
        clearTimers()
        dropTransport()
        patch { $0.transport = .blocked; $0.sync = .idle; $0.reason = reason }
    }

    private func reconnect(_ reason: String) {
        clearTimers()
        dropTransport()
        patch { $0.reason = reason }
        connect()
    }

    private func dropTransport() {
        generation += 1
        connecting = false
        transport?.close()
        transport = nil
    }

    private func clearTimers() {
        clearRetryTimer()
        clearStableTimer()
    }

    private func clearRetryTimer() {
        if let retryTimer { scheduler.cancel(retryTimer) }
        retryTimer = nil
    }

    private func clearStableTimer() {
        if let stableTimer { scheduler.cancel(stableTimer) }
        stableTimer = nil
    }

    private func patch(_ update: (inout SupervisorState) -> Void) {
        update(&state)
        stateChanged.emit(state)
    }
}

/// Replaces by id, keeps everything else.
private func merge(_ existing: [SessionSummary], _ updates: [SessionSummary]) -> [SessionSummary] {
    var result = existing
    for summary in updates {
        if let index = result.firstIndex(where: { $0.sessionId == summary.sessionId }) {
            result[index] = summary
        } else {
            result.append(summary)
        }
    }
    return result
}
