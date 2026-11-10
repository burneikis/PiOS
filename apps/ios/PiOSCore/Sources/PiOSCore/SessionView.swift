import Foundation

public enum ViewItem: Identifiable, Sendable {
    /// `entryId` exists only once the entry is persisted.
    case message(key: String, message: AgentMessage, entryId: String?, failedAttempts: Int)
    /// History before here was summarised for the model; it is still shown.
    case compaction(key: String, tokensBefore: Double?)
    case streaming(PartialMessage)
    case pending(OutboxEntry)

    public var id: String {
        switch self {
        case let .message(key, _, _, _): return key
        case let .compaction(key, _): return key
        case .streaming: return "streaming"
        case let .pending(entry): return "p:\(entry.messageId)"
        }
    }
}

public struct SessionView: Sendable {
    public var items: [ViewItem]
    /// Tool state by `toolCallId`, live or reconstructed from history.
    public var tools: [String: ToolExecution]
    public var steering: [String]
    public var followUp: [String]
    public var running: Bool
    /// Stop was sent and the agent has not stopped yet.
    public var interrupting: Bool
    public var dialogs: [ExtensionUiRequest]
    public var presentation: SessionPresentation
    public var notices: [Notice]
    public var bash: BashRun?
    public var hasOlder: Bool
    public var status: TranscriptStatus

    /// What pi's `/copy` copies: the last answer's text.
    public var lastAssistantText: String? {
        for item in items.reversed() {
            guard case let .message(_, message, _, _) = item, message.role == .assistant else { continue }
            if message.stopReason == "aborted" && message.content.isEmpty { continue }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }
}

/// One render-ready transcript from three overlapping sources: cached
/// entries, the live assembler, and the outbox. A resync can return an entry
/// for a message that also arrived as an event, so duplicates collapse.
@MainActor
public func sessionView(store: SessionStore, outbox: [OutboxEntry], sessionId: String) -> SessionView {
    let transcript = store.transcript(sessionId)
    let cached = store.cache(sessionId).entries

    var items: [ViewItem] = []
    var seen: Set<String> = []
    var tools: [String: ToolExecution] = [:]

    func add(_ message: AgentMessage, renderKey: String, entryId: String?) {
        // pi's assembled prompt is transcript data, not conversation.
        guard message.role != .system else { return }
        let key = messageKey(message)
        // Persisted entries are distinct by id even when their content is
        // not (the same reply twice, no timestamp); only a live copy of one
        // collapses onto it.
        let fresh = seen.insert(key).inserted
        guard fresh || entryId != nil else { return }
        if message.role == .assistant { recordToolCalls(&tools, message) }
        // Tool results belong on their card, not as a bubble of their own.
        if message.role == .toolResult { return recordToolResult(&tools, message) }
        items.append(.message(key: renderKey, message: message, entryId: entryId, failedAttempts: 0))
    }

    for entry in cached {
        if entry.type == "compaction" {
            items.append(.compaction(key: "e:\(entry.id)", tokensBefore: entry.raw["tokensBefore"]?.double))
            continue
        }
        guard let message = entry.message else { continue }
        add(message, renderKey: "e:\(entry.id)", entryId: entry.id)
    }
    for message in transcript.messages { add(message, renderKey: messageKey(message), entryId: nil) }

    // Live state wins: it has args and partial output a persisted result lacks.
    for tool in transcript.toolExecutions {
        let historic = tools[tool.toolCallId]
        var merged = tool
        merged.args = tool.args ?? historic?.args
        merged.result = tool.result ?? historic?.result
        merged.isError = tool.isError || (historic?.isError ?? false)
        merged.startedAt = tool.startedAt ?? historic?.startedAt
        merged.durationMs = tool.durationMs ?? historic?.durationMs
        if historic?.status == .done, merged.status == .running { merged.status = .done }
        tools[tool.toolCallId] = merged
    }

    // The daemon is authoritative about busy, both ways. Unknown defers to
    // the stream.
    let daemonStatus = store.status(sessionId)
    let running = daemonStatus.map { $0 == .running } ?? transcript.running

    // A call left mid-flight by a restart never gets a result.
    if !running {
        for (id, tool) in tools where tool.status == .running {
            tools[id]?.status = .abandoned
        }
    }

    if let streaming = transcript.streaming { items.append(.streaming(streaming)) }
    for entry in outbox where entry.sessionId == sessionId { items.append(.pending(entry)) }

    return SessionView(
        items: foldRetries(items, retrying: transcript.status.retry != nil),
        tools: tools,
        steering: transcript.steering,
        followUp: transcript.followUp,
        running: running,
        interrupting: running && store.isInterrupting(sessionId),
        dialogs: store.openDialogs(sessionId),
        presentation: store.presentation(sessionId),
        notices: store.openNotices(sessionId),
        bash: store.bash(sessionId),
        hasOlder: store.hasOlder(sessionId),
        status: transcript.status
    )
}

/// Collapses auto-retried attempts into the one that followed them. An empty
/// failed turn followed directly by another assistant turn can only be a
/// retry; while a retry waits, the latest failure is not final either.
func foldRetries(_ items: [ViewItem], retrying: Bool) -> [ViewItem] {
    var folded: [ViewItem] = []
    let last = items.lastIndex { if case .pending = $0 { return false } else { return true } }
    var failed = 0
    for (index, item) in items.enumerated() {
        let next = index + 1 < items.count ? items[index + 1] : nil
        let superseded = isAssistantTurn(next) || (retrying && index == last)
        if isEmptyFailure(item), superseded {
            failed += 1
            continue
        }
        if failed > 0, case let .message(key, message, entryId, _) = item {
            folded.append(.message(key: key, message: message, entryId: entryId, failedAttempts: failed))
        } else {
            folded.append(item)
        }
        failed = 0
    }
    return folded
}

private func isEmptyFailure(_ item: ViewItem) -> Bool {
    guard case let .message(_, message, _, _) = item else { return false }
    return message.role == .assistant && message.stopReason == "error" && message.content.isEmpty
}

private func isAssistantTurn(_ item: ViewItem?) -> Bool {
    switch item {
    case .streaming: return true
    case let .message(_, message, _, _): return message.role == .assistant
    default: return false
    }
}

/// Files the arguments a turn's tool calls were made with; the result
/// arrives as a separate entry.
private func recordToolCalls(_ tools: inout [String: ToolExecution], _ message: AgentMessage) {
    for part in message.content {
        guard case let .toolCall(call) = part else { continue }
        let existing = tools[call.id]
        tools[call.id] = ToolExecution(
            toolCallId: call.id, toolName: call.name, args: call.arguments, result: existing?.result,
            isError: existing?.isError ?? false, status: existing?.status ?? .running,
            startedAt: existing?.startedAt, durationMs: existing?.durationMs
        )
    }
}

private func recordToolResult(_ tools: inout [String: ToolExecution], _ message: AgentMessage) {
    guard let id = message.toolCallId else { return }
    let existing = tools[id]
    let content = message.raw["content"] ?? .array([])
    tools[id] = ToolExecution(
        toolCallId: id, toolName: message.toolName ?? existing?.toolName ?? "tool", args: existing?.args,
        result: .object(["content": content]), isError: message.isError, status: .done,
        startedAt: existing?.startedAt, durationMs: existing?.durationMs
    )
}

/// Identity for a message with no id: role, timestamp and text are enough to
/// spot the live copy of a persisted one.
func messageKey(_ message: AgentMessage) -> String {
    let timestamp = message.timestamp.map { String(Int64($0)) } ?? ""
    let suffix = message.role == .toolResult ? (message.toolCallId ?? "") : message.text
    return "m:\(message.role.rawValue):\(timestamp):\(suffix)"
}
