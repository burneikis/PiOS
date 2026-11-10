import Foundation

/// A content block while it is still streaming. `message_update` carries
/// deltas with no cumulative snapshot, so the client holds this itself.
public enum PartialContent: Hashable, Sendable {
    case text(String, done: Bool)
    case thinking(String, done: Bool)
    /// `id` and `name` stay nil until `toolcall_end`.
    case toolCall(id: String?, name: String?, argsText: String, arguments: JSON?, done: Bool)
}

public struct PartialMessage: Hashable, Sendable {
    public var content: [PartialContent]
}

/// One in-flight assistant message, keyed by `contentIndex` because a
/// provider may interleave indices.
final class MessageAssembler {
    private var blocks: [Int: PartialContent] = [:]

    var isEmpty: Bool { blocks.isEmpty }

    func apply(_ event: AssistantMessageEvent) {
        switch event {
        case let .textStart(index):
            blocks[index] = .text("", done: false)
        case let .textDelta(index, delta):
            blocks[index] = .text(text(index) + delta, done: false)
        case let .textEnd(index, content):
            // `content` is the provider's authoritative value for the block.
            blocks[index] = .text(content, done: true)
        case let .thinkingStart(index):
            blocks[index] = .thinking("", done: false)
        case let .thinkingDelta(index, delta):
            blocks[index] = .thinking(thinking(index) + delta, done: false)
        case let .thinkingEnd(index, content):
            blocks[index] = .thinking(content, done: true)
        case let .toolCallStart(index):
            blocks[index] = .toolCall(id: nil, name: nil, argsText: "", arguments: nil, done: false)
        case let .toolCallDelta(index, delta):
            if case let .toolCall(id, name, args, arguments, _) = blocks[index] {
                blocks[index] = .toolCall(id: id, name: name, argsText: args + delta, arguments: arguments, done: false)
            } else {
                blocks[index] = .toolCall(id: nil, name: nil, argsText: delta, arguments: nil, done: false)
            }
        case let .toolCallEnd(index, call):
            var args = ""
            if case let .toolCall(_, _, text, _, _) = blocks[index] { args = text }
            blocks[index] = .toolCall(id: call.id, name: call.name, argsText: args, arguments: call.arguments, done: true)
        case .other:
            break
        }
    }

    func snapshot() -> PartialMessage {
        PartialMessage(content: blocks.sorted { $0.key < $1.key }.map(\.value))
    }

    private func text(_ index: Int) -> String {
        if case let .text(text, _) = blocks[index] { return text }
        return ""
    }

    private func thinking(_ index: Int) -> String {
        if case let .thinking(text, _) = blocks[index] { return text }
        return ""
    }
}

/// `abandoned` is a call whose result never arrived and whose turn is over.
public enum ToolExecutionStatus: String, Hashable, Sendable {
    case running, done, abandoned
}

public struct ToolExecution: Hashable, Sendable, Identifiable {
    public var toolCallId: String
    public var toolName: String
    public var args: JSON?
    /// Cumulative, not a delta: each update replaces the previous value.
    public var partialResult: JSON?
    public var result: JSON?
    public var isError: Bool
    public var status: ToolExecutionStatus
    /// Epoch ms, already corrected into the local clock.
    public var startedAt: Double?
    public var durationMs: Double?

    public var id: String { toolCallId }

    public init(
        toolCallId: String, toolName: String, args: JSON? = nil, partialResult: JSON? = nil, result: JSON? = nil,
        isError: Bool = false, status: ToolExecutionStatus = .running, startedAt: Double? = nil, durationMs: Double? = nil
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.args = args
        self.partialResult = partialResult
        self.result = result
        self.isError = isError
        self.status = status
        self.startedAt = startedAt
        self.durationMs = durationMs
    }

    /// Text and image parts of the result, or of the partial one while running.
    public var resultParts: [JSON] {
        (result ?? partialResult)?["content"]?.array ?? []
    }

    public var resultText: String {
        resultParts.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined(separator: "\n")
    }

    public var resultImages: [ImageContent] {
        resultParts.compactMap(ImageContent.init(json:))
    }
}

public struct TranscriptStatus: Hashable, Sendable {
    public var compaction: String?
    public var retry: RetryStatus?
    public var summarizationRetry: RetryStatus?
    /// Never cleared automatically: a broken extension stays visible.
    public var extensionErrors: [ExtensionError] = []
}

public struct Transcript: Sendable {
    public var messages: [AgentMessage]
    public var streaming: PartialMessage?
    public var toolExecutions: [ToolExecution]
    public var steering: [String]
    public var followUp: [String]
    /// True between `agent_start` and `agent_settled`.
    public var running: Bool
    public var status: TranscriptStatus
}

/// Applies a stream of agent events to a running transcript. Tolerant: a
/// client that reconnects mid-turn sees deltas for a message whose
/// `message_start` it missed, and renders them anyway.
public final class TranscriptAssembler {
    private var messages: [AgentMessage] = []
    private var tools: [String: ToolExecution] = [:]
    private var toolOrder: [String] = []
    private var assembler = MessageAssembler()
    private var streamingActive = false
    private var steering: [String] = []
    private var followUp: [String] = []
    private var running = false
    private var status = TranscriptStatus()

    public init() {}

    public func apply(_ event: AgentEvent) {
        switch event {
        case .agentStart:
            running = true
        case .agentSettled:
            running = false
            // A settled run cannot still be retrying.
            status.retry = nil
            status.summarizationRetry = nil
        case let .messageStart(message):
            // Non-assistant messages are recorded on message_end only.
            if message.role == .assistant {
                assembler = MessageAssembler()
                streamingActive = true
            }
        case let .messageUpdate(delta):
            if !streamingActive {
                assembler = MessageAssembler()
                streamingActive = true
            }
            assembler.apply(delta)
        case let .messageEnd(message):
            messages.append(message)
            if message.role == .assistant {
                assembler = MessageAssembler()
                streamingActive = false
            }
        case let .toolExecutionStart(id, name, args, startedAt):
            if tools[id] == nil { toolOrder.append(id) }
            tools[id] = ToolExecution(toolCallId: id, toolName: name, args: args, startedAt: startedAt)
        case let .toolExecutionUpdate(id, name, partial):
            var tool = self.tool(id, name)
            tool.partialResult = partial
            tools[id] = tool
        case let .toolExecutionEnd(id, name, result, isError, durationMs):
            var tool = self.tool(id, name)
            tool.result = result
            tool.isError = isError
            tool.status = .done
            tool.durationMs = durationMs
            tools[id] = tool
        case let .queueUpdate(steering, followUp):
            self.steering = steering
            self.followUp = followUp
        case let .compactionStart(reason):
            status.compaction = reason
        case let .compactionEnd(error):
            status.compaction = nil
            if let error { status.extensionErrors.append(.init(extensionPath: nil, event: "compaction", error: error)) }
        case let .autoRetryStart(retry):
            status.retry = retry
        case .autoRetryEnd:
            status.retry = nil
        case let .summarizationRetryScheduled(retry):
            status.summarizationRetry = retry
        case .summarizationRetryFinished:
            status.summarizationRetry = nil
        case let .extensionError(error):
            status.extensionErrors.append(error)
        case .agentEnd, .bashExecutionUpdate, .other:
            break
        }
    }

    public func snapshot() -> Transcript {
        Transcript(
            messages: messages,
            streaming: streamingActive && !assembler.isEmpty ? assembler.snapshot() : nil,
            toolExecutions: toolOrder.compactMap { tools[$0] },
            steering: steering,
            followUp: followUp,
            running: running,
            status: status
        )
    }

    /// Discounts a span during which nothing could run, so a live counter does
    /// not climb past the daemon's final number while a dialog sat unanswered.
    public func excludeSince(_ since: Double, until: Double = nowMs()) {
        for (id, var tool) in tools where tool.status == .running {
            guard let startedAt = tool.startedAt else { continue }
            let from = max(since, startedAt)
            if until > from { tool.startedAt = startedAt + (until - from) }
            tools[id] = tool
        }
    }

    /// Ends the turn without its `agent_settled`, for an agent whose process
    /// is gone: its calls will never get results.
    public func abandon() {
        running = false
        streamingActive = false
        assembler = MessageAssembler()
        status.retry = nil
        status.summarizationRetry = nil
        status.compaction = nil
        for (id, var tool) in tools where tool.status == .running {
            tool.status = .abandoned
            tools[id] = tool
        }
    }

    private func tool(_ id: String, _ name: String) -> ToolExecution {
        if let tool = tools[id] { return tool }
        toolOrder.append(id)
        return ToolExecution(toolCallId: id, toolName: name)
    }
}

public func nowMs() -> Double {
    Date().timeIntervalSince1970 * 1000
}
