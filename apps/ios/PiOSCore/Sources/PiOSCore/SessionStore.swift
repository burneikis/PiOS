import Foundation

public let sessionCacheVersion = 2
private let storagePrefix = "pios.session."
/// A chatty extension must not be able to bury the transcript.
private let maxNotices = 3

public struct Notice: Hashable, Sendable, Identifiable {
    public var id: String
    public var message: String
    public var type: String
}

/// A `!` command in flight, or the one that just finished.
public struct BashRun: Hashable, Sendable {
    public var command: String
    /// Ran with `!!`: shown here, never sent to the model.
    public var excludeFromContext: Bool
    public var output: String
    public var running: Bool
    public var result: BashResult?
}

public struct SessionCache: Codable, Sendable {
    public var sessionId: String
    /// Durable resume cursor.
    public var cursor: String?
    /// Live tail cursor into the daemon's ring buffer.
    public var lastSeq: Int
    public var entries: [SessionEntry]
    /// Index of the first held entry within the whole transcript.
    public var offset: Int
    public var total: Int

    init(sessionId: String) {
        self.sessionId = sessionId
        cursor = nil
        lastSeq = 0
        entries = []
        offset = 0
        total = 0
    }
}

/// Per-session transcript cache and cursor.
///
/// Cached entries are for rendering while offline, never for deciding whether
/// the client is current. That is always `leafId` from the daemon.
@MainActor
public final class SessionStore {
    public let changed = Listeners<String>()

    private var caches: [String: SessionCache] = [:]
    private var assemblers: [String: TranscriptAssembler] = [:]
    /// Last status the daemon reported. Live state, never persisted.
    private var daemonStatus: [String: SessionSummary.Status] = [:]
    private var interrupting: Set<String> = []
    /// Open dialogs by request id, so a resend collapses onto the one shown.
    private var dialogs: [String: [ExtensionUiRequest]] = [:]
    private var blockedSince: [String: Double] = [:]
    private var presentations: [String: SessionPresentation] = [:]
    private var notices: [String: [Notice]] = [:]
    private var bashRuns: [String: BashRun] = [:]
    private var noticeCounter = 0
    private let storage: StorageAdapter?

    public init(storage: StorageAdapter? = nil) {
        self.storage = storage
    }

    public func cache(_ sessionId: String) -> SessionCache {
        if let existing = caches[sessionId] { return existing }
        let loaded = storage.flatMap {
            readVersioned($0, storagePrefix + sessionId, version: sessionCacheVersion, fallback: SessionCache?.none)
        }
        let cache = loaded ?? SessionCache(sessionId: sessionId)
        caches[sessionId] = cache
        return cache
    }

    /// Cursor for `get_entries`. Nil means "send the tail".
    public func cursor(_ sessionId: String) -> String? { cache(sessionId).cursor }
    public func lastSeq(_ sessionId: String) -> Int { cache(sessionId).lastSeq }
    public func firstHeldIndex(_ sessionId: String) -> Int { cache(sessionId).offset }
    public func hasOlder(_ sessionId: String) -> Bool { cache(sessionId).offset > 0 }

    /// Prepends a page of history, fetched when someone scrolls up for it.
    public func applyOlderEntries(_ sessionId: String, entries: [SessionEntry], offset: Int, total: Int) {
        var cache = cache(sessionId)
        let known = Set(cache.entries.map(\.id))
        cache.entries = entries.filter { !known.contains($0.id) } + cache.entries
        cache.offset = offset
        cache.total = max(total, cache.total)
        save(cache)
    }

    /// Applies an `entries` response. `reset` means the cursor was not
    /// recognised and the payload is a fresh transcript, so it replaces.
    public func applyEntries(_ sessionId: String, entries: [SessionEntry], leafId: String?, reset: Bool, offset: Int, total: Int) {
        var cache = cache(sessionId)
        cache.total = max(total, cache.total)
        if reset || cache.entries.isEmpty { cache.offset = offset }
        if reset {
            cache.entries = entries
        } else {
            var known = Set(cache.entries.map(\.id))
            for entry in entries where !known.contains(entry.id) {
                cache.entries.append(entry)
                known.insert(entry.id)
            }
        }
        cache.cursor = leafId ?? cache.entries.last?.id
        // A finished command stays on screen until pi's own entry lands.
        if let bash = bashRuns[sessionId], !bash.running,
           entries.contains(where: { $0.message?.role == .bashExecution && $0.message?.command == bash.command })
        {
            bashRuns[sessionId] = nil
        }
        save(cache)
    }

    /// A leaf the cache has never seen means the branch moved. There is no
    /// safe incremental fix for that, so the answer is a full refetch.
    public func needsFullRefetch(_ sessionId: String, leafId: String?) -> Bool {
        // Nil is "not known from here": a cold session's cursor is in its file.
        guard let leafId else { return false }
        let cache = cache(sessionId)
        if cache.cursor == leafId { return false }
        return !cache.entries.contains { $0.id == leafId }
    }

    /// Live events, in memory only. `at` is the daemon clock at publish, used
    /// to move a tool's start time into the local clock.
    public func applyEvent(_ sessionId: String, seq: Int, event: AgentEvent, at: Double?) {
        var cache = cache(sessionId)
        cache.lastSeq = seq
        caches[sessionId] = cache
        var localised = event
        if case let .toolExecutionStart(id, name, args, startedAt?) = event {
            let skew = at.map { nowMs() - $0 } ?? 0
            localised = .toolExecutionStart(toolCallId: id, toolName: name, args: args, startedAt: startedAt + skew)
        }
        assembler(sessionId).apply(localised)
        if case let .bashExecutionUpdate(_, delta) = event, var run = bashRuns[sessionId], run.running {
            run.output += delta
            bashRuns[sessionId] = run
        }
        if case .agentSettled = event { interrupting.remove(sessionId) }
        changed.emit(sessionId)
    }

    public func transcript(_ sessionId: String) -> Transcript {
        assembler(sessionId).snapshot()
    }

    /// The daemon's view of whether the agent works. An aborted turn does not
    /// always produce `agent_settled`, so without this a stop spins forever.
    public func setDaemonStatus(_ sessionId: String, _ status: SessionSummary.Status) {
        guard daemonStatus[sessionId] != status else { return }
        daemonStatus[sessionId] = status
        if status != .running { interrupting.remove(sessionId) }
        // No process means no turn: whatever was in flight died with it.
        if status == .cold || status == .crashed { assemblers[sessionId]?.abandon() }
        changed.emit(sessionId)
    }

    public func status(_ sessionId: String) -> SessionSummary.Status? { daemonStatus[sessionId] }

    public func setInterrupting(_ sessionId: String, _ value: Bool) {
        if value { interrupting.insert(sessionId) } else { interrupting.remove(sessionId) }
        changed.emit(sessionId)
    }

    public func isInterrupting(_ sessionId: String) -> Bool { interrupting.contains(sessionId) }

    public func startBash(_ sessionId: String, command: String, excludeFromContext: Bool) {
        bashRuns[sessionId] = BashRun(command: command, excludeFromContext: excludeFromContext, output: "", running: true)
        changed.emit(sessionId)
    }

    public func finishBash(_ sessionId: String, result: BashResult) {
        guard var run = bashRuns[sessionId] else { return }
        run.running = false
        run.result = result
        // pi's result carries the whole output; the deltas were a preview.
        if !result.output.isEmpty { run.output = result.output }
        bashRuns[sessionId] = run
        changed.emit(sessionId)
    }

    public func bash(_ sessionId: String) -> BashRun? { bashRuns[sessionId] }

    public func openDialog(_ sessionId: String, _ request: ExtensionUiRequest) {
        var open = dialogs[sessionId] ?? []
        guard !open.contains(where: { $0.id == request.id }) else { return }
        open.append(request)
        dialogs[sessionId] = open
        if open.count == 1 { blockedSince[sessionId] = nowMs() }
        changed.emit(sessionId)
    }

    public func closeDialog(_ sessionId: String, _ requestId: String) {
        guard var open = dialogs[sessionId], open.contains(where: { $0.id == requestId }) else { return }
        open.removeAll { $0.id == requestId }
        dialogs[sessionId] = open
        if open.isEmpty, let since = blockedSince.removeValue(forKey: sessionId) {
            assembler(sessionId).excludeSince(since)
        }
        changed.emit(sessionId)
    }

    /// Oldest first, so answering one at a time follows the order asked.
    public func openDialogs(_ sessionId: String) -> [ExtensionUiRequest] { dialogs[sessionId] ?? [] }

    /// `notify` is an event rather than state: replaying it on reconnect
    /// would announce something that already happened.
    public func applyPresentationRequest(_ sessionId: String, _ request: ExtensionUiRequest) {
        guard !request.isDialog else { return }
        if request.method == .notify {
            if let message = request.message { addNotice(sessionId, stripAnsi(message), type: request.notifyType ?? "info") }
            return
        }
        let current = presentation(sessionId)
        let next = applyPresentation(current, request)
        guard next != current else { return }
        presentations[sessionId] = next
        changed.emit(sessionId)
    }

    /// The daemon's snapshot supersedes whatever was accumulated live.
    public func setPresentation(_ sessionId: String, _ presentation: SessionPresentation) {
        presentations[sessionId] = presentation
        changed.emit(sessionId)
    }

    public func presentation(_ sessionId: String) -> SessionPresentation { presentations[sessionId] ?? SessionPresentation() }

    public func addNotice(_ sessionId: String, _ message: String, type: String = "info") {
        noticeCounter += 1
        let list = (notices[sessionId] ?? []) + [Notice(id: "n\(noticeCounter)", message: message, type: type)]
        notices[sessionId] = Array(list.suffix(maxNotices))
        changed.emit(sessionId)
    }

    public func openNotices(_ sessionId: String) -> [Notice] { notices[sessionId] ?? [] }

    public func dismissNotice(_ sessionId: String, _ id: String) {
        notices[sessionId]?.removeAll { $0.id == id }
        changed.emit(sessionId)
    }

    /// Drops everything for a session, for a reset.
    public func clear(_ sessionId: String) {
        caches[sessionId] = nil
        assemblers[sessionId] = nil
        daemonStatus[sessionId] = nil
        interrupting.remove(sessionId)
        dialogs[sessionId] = nil
        blockedSince[sessionId] = nil
        presentations[sessionId] = nil
        notices[sessionId] = nil
        bashRuns[sessionId] = nil
        storage?.remove(storagePrefix + sessionId)
        changed.emit(sessionId)
    }

    /// Adopts the daemon's live cursor on subscribe. seq is only meaningful
    /// within one process, so an older, larger one must not win.
    public func setLastSeq(_ sessionId: String, _ seq: Int) {
        var cache = cache(sessionId)
        guard cache.lastSeq != seq else { return }
        cache.lastSeq = seq
        save(cache)
    }

    /// After a gap the tail is incomplete, so the live transcript is rebuilt.
    public func resetLiveTranscript(_ sessionId: String) {
        assemblers[sessionId] = nil
        var cache = cache(sessionId)
        cache.lastSeq = 0
        save(cache)
    }

    private func assembler(_ sessionId: String) -> TranscriptAssembler {
        if let existing = assemblers[sessionId] { return existing }
        let created = TranscriptAssembler()
        assemblers[sessionId] = created
        return created
    }

    private func save(_ cache: SessionCache) {
        caches[cache.sessionId] = cache
        if let storage { writeVersioned(storage, storagePrefix + cache.sessionId, version: sessionCacheVersion, cache) }
        changed.emit(cache.sessionId)
    }
}
