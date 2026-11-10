import Foundation

public let outboxSchemaVersion = 1
private let outboxKey = "pios.outbox"

public struct OutboxEntry: Hashable, Codable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case queued, sending, failed
    }

    /// Identity of the composed message, for rendering and dedupe.
    public var messageId: String
    /// Idempotency key for delivery. The daemon dedupes on this.
    public var commandId: String
    public var sessionId: String
    public var text: String
    /// Inlined, not a file reference: the file may be gone by send time.
    public var images: [ImageContent]
    public var streamingBehavior: StreamingBehavior?
    /// Starts the session at delivery, not at composition, so composing
    /// offline and sending later still creates it.
    public var create: SessionCreate?
    public var createdAt: Double
    public var attempts: Int
    public var status: Status
    public var lastError: String?

    public var id: String { messageId }

    var command: ClientCommand {
        .prompt(
            sessionId: sessionId, messageId: messageId, text: text, images: images,
            streamingBehavior: streamingBehavior, create: create
        )
    }
}

/// Durable queue of composed prompts.
///
/// Written to storage before it is sent, removed only when the daemon
/// acknowledges. That is what makes composing on a train work: the message
/// survives the app being killed and drains when signal returns.
@MainActor
public final class ThreadOutbox {
    public private(set) var entries: [OutboxEntry]
    public let changed = Listeners<[OutboxEntry]>()

    private let storage: StorageAdapter
    private let scheduler: Scheduler
    private var backoff: Backoff
    private let sendEntry: (OutboxEntry) -> Bool
    private var retryTimer: TimerHandle?
    private var draining = false

    public init(storage: StorageAdapter, scheduler: Scheduler, backoff: Backoff = Backoff(), send: @escaping (OutboxEntry) -> Bool) {
        self.storage = storage
        self.scheduler = scheduler
        self.backoff = backoff
        sendEntry = send
        entries = readVersioned(storage, outboxKey, version: outboxSchemaVersion, fallback: [OutboxEntry]())
        // Anything mid-flight last run is queued again: the daemon's ledger
        // makes a redundant redelivery harmless, a lost prompt is not.
        for index in entries.indices where entries[index].status == .sending {
            entries[index].status = .queued
        }
    }

    public func list(sessionId: String? = nil) -> [OutboxEntry] {
        guard let sessionId else { return entries }
        return entries.filter { $0.sessionId == sessionId }
    }

    @discardableResult
    public func enqueue(
        messageId: String, commandId: String, sessionId: String, text: String, images: [ImageContent],
        streamingBehavior: StreamingBehavior?, create: SessionCreate?
    ) -> OutboxEntry {
        if let existing = entries.first(where: { $0.commandId == commandId }) { return existing }
        let entry = OutboxEntry(
            messageId: messageId, commandId: commandId, sessionId: sessionId, text: text, images: images,
            streamingBehavior: streamingBehavior, create: create, createdAt: scheduler.now(), attempts: 0,
            status: .queued
        )
        entries.append(entry)
        persistAndNotify()
        drain()
        return entry
    }

    /// The daemon accepted the command; it never needs sending again.
    public func acknowledge(_ commandId: String) {
        let before = entries.count
        entries.removeAll { $0.commandId == commandId }
        guard entries.count != before else { return }
        backoff.reset()
        persistAndNotify()
        drain()
    }

    /// Refused outright. Kept and marked failed rather than dropped: the user
    /// wrote it, and the usual cause is fixable. True when it was queued here.
    @discardableResult
    public func reject(_ commandId: String, error: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.commandId == commandId }) else { return false }
        entries[index].status = .failed
        entries[index].lastError = error
        persistAndNotify()
        return true
    }

    public func discard(_ commandId: String) {
        entries.removeAll { $0.commandId == commandId }
        persistAndNotify()
    }

    /// Retries a failed entry after the user fixed whatever caused it.
    public func requeue(_ commandId: String, streamingBehavior: StreamingBehavior? = nil) {
        guard let index = entries.firstIndex(where: { $0.commandId == commandId }) else { return }
        if let streamingBehavior { entries[index].streamingBehavior = streamingBehavior }
        entries[index].status = .queued
        entries[index].lastError = nil
        persistAndNotify()
        drain()
    }

    /// Always safe: delivery is idempotent.
    public func drain() {
        guard !draining else { return }
        draining = true
        defer {
            draining = false
            persistAndNotify()
        }
        // By id, not index: an ack can land mid-pass and shrink the array.
        let queued = entries.filter { $0.status == .queued }.map(\.commandId)
        for commandId in queued {
            guard let index = entries.firstIndex(where: { $0.commandId == commandId }) else { continue }
            entries[index].status = .sending
            entries[index].attempts += 1
            if sendEntry(entries[index]) { continue }
            // No live socket: stop the pass rather than marking every entry
            // as attempted against a socket that is not there.
            guard let failed = entries.firstIndex(where: { $0.commandId == commandId }) else { break }
            entries[failed].status = .queued
            entries[failed].attempts -= 1
            scheduleRetry()
            break
        }
    }

    public var pendingCount: Int {
        entries.filter { $0.status != .failed }.count
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = scheduler.after(backoff.next()) { [weak self] in
            self?.retryTimer = nil
            self?.drain()
        }
    }

    private func persistAndNotify() {
        writeVersioned(storage, outboxKey, version: outboxSchemaVersion, entries)
        changed.emit(entries)
    }
}
