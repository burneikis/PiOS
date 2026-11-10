import Foundation

/// Streaming deltas inside `message_update`. `contentIndex` is the only
/// correlation key: tool call deltas carry no id until `toolcall_end`.
public enum AssistantMessageEvent: Sendable {
    case textStart(Int)
    case textDelta(Int, String)
    case textEnd(Int, String)
    case thinkingStart(Int)
    case thinkingDelta(Int, String)
    case thinkingEnd(Int, String)
    case toolCallStart(Int)
    case toolCallDelta(Int, String)
    case toolCallEnd(Int, ToolCall)
    case other

    init(json: JSON) {
        let index = json["contentIndex"]?.int ?? 0
        switch json["type"]?.string {
        case "text_start": self = .textStart(index)
        case "text_delta": self = .textDelta(index, json["delta"]?.string ?? "")
        case "text_end": self = .textEnd(index, json["content"]?.string ?? "")
        case "thinking_start": self = .thinkingStart(index)
        case "thinking_delta": self = .thinkingDelta(index, json["delta"]?.string ?? "")
        case "thinking_end": self = .thinkingEnd(index, json["content"]?.string ?? "")
        case "toolcall_start": self = .toolCallStart(index)
        case "toolcall_delta": self = .toolCallDelta(index, json["delta"]?.string ?? "")
        case "toolcall_end":
            if let call = json["toolCall"].flatMap(ToolCall.init(json:)) {
                self = .toolCallEnd(index, call)
            } else {
                self = .other
            }
        default: self = .other
        }
    }
}

/// A pi agent event. Unknown types decode to `.other` rather than failing:
/// a newer pi must not cost the client the rest of the stream.
public enum AgentEvent: Sendable {
    case agentStart
    case agentEnd
    /// Terminal. `agent_end` may be followed by retry, compaction or a queued
    /// continuation; `agent_settled` may not.
    case agentSettled
    case messageStart(AgentMessage)
    case messageEnd(AgentMessage)
    case messageUpdate(AssistantMessageEvent)
    case bashExecutionUpdate(id: String?, delta: String)
    case toolExecutionStart(toolCallId: String, toolName: String, args: JSON?, startedAt: Double?)
    /// `partialResult` is cumulative, so it replaces rather than appends.
    case toolExecutionUpdate(toolCallId: String, toolName: String, partialResult: JSON?)
    case toolExecutionEnd(toolCallId: String, toolName: String, result: JSON?, isError: Bool, durationMs: Double?)
    case queueUpdate(steering: [String], followUp: [String])
    case compactionStart(reason: String)
    case compactionEnd(errorMessage: String?)
    case autoRetryStart(RetryStatus)
    case autoRetryEnd
    case summarizationRetryScheduled(RetryStatus)
    case summarizationRetryFinished
    case extensionError(ExtensionError)
    case other(String)

    public init?(json: JSON) {
        guard let type = json["type"]?.string else { return nil }
        switch type {
        case "agent_start": self = .agentStart
        case "agent_end": self = .agentEnd
        case "agent_settled": self = .agentSettled
        case "message_start", "message_end":
            guard let message = json["message"].flatMap(AgentMessage.init(json:)) else { return nil }
            self = type == "message_start" ? .messageStart(message) : .messageEnd(message)
        case "message_update":
            guard let inner = json["assistantMessageEvent"] else { return nil }
            self = .messageUpdate(AssistantMessageEvent(json: inner))
        case "bash_execution_update":
            self = .bashExecutionUpdate(id: json["id"]?.string, delta: json["delta"]?.string ?? "")
        case "tool_execution_start":
            guard let id = json["toolCallId"]?.string else { return nil }
            self = .toolExecutionStart(
                toolCallId: id,
                toolName: json["toolName"]?.string ?? "tool",
                args: json["args"],
                startedAt: json["startedAt"]?.double
            )
        case "tool_execution_update":
            guard let id = json["toolCallId"]?.string else { return nil }
            self = .toolExecutionUpdate(
                toolCallId: id, toolName: json["toolName"]?.string ?? "tool", partialResult: json["partialResult"]
            )
        case "tool_execution_end":
            guard let id = json["toolCallId"]?.string else { return nil }
            self = .toolExecutionEnd(
                toolCallId: id,
                toolName: json["toolName"]?.string ?? "tool",
                result: json["result"],
                isError: json["isError"]?.bool ?? false,
                durationMs: json["durationMs"]?.double
            )
        case "queue_update":
            self = .queueUpdate(steering: json["steering"]?.strings ?? [], followUp: json["followUp"]?.strings ?? [])
        case "compaction_start":
            self = .compactionStart(reason: json["reason"]?.string ?? "manual")
        case "compaction_end":
            self = .compactionEnd(errorMessage: json["errorMessage"]?.string)
        case "auto_retry_start":
            self = .autoRetryStart(RetryStatus(json: json))
        case "auto_retry_end":
            self = .autoRetryEnd
        case "summarization_retry_scheduled":
            self = .summarizationRetryScheduled(RetryStatus(json: json))
        case "summarization_retry_finished":
            self = .summarizationRetryFinished
        case "extension_error":
            self = .extensionError(ExtensionError(
                extensionPath: json["extensionPath"]?.string,
                event: json["event"]?.string,
                error: json["error"]?.string ?? "unknown extension error"
            ))
        default:
            self = .other(type)
        }
    }
}

public struct RetryStatus: Hashable, Sendable {
    public var attempt: Int
    public var maxAttempts: Int?
    public var delayMs: Double?
    public var error: String?

    init(json: JSON) {
        attempt = json["attempt"]?.int ?? 1
        maxAttempts = json["maxAttempts"]?.int
        delayMs = json["delayMs"]?.double
        error = json["errorMessage"]?.string
    }
}

public struct ExtensionError: Hashable, Sendable {
    public var extensionPath: String?
    public var event: String?
    public var error: String
}

/// An extension UI request. Only the four dialog methods block the agent.
public struct ExtensionUiRequest: Hashable, Sendable, Identifiable {
    public enum Method: String, Sendable {
        case select, confirm, input, editor, notify, setStatus, setWidget, setTitle
        case setEditorText = "set_editor_text"
    }

    public var id: String
    public var method: Method
    public var title: String?
    public var message: String?
    public var options: [String]
    public var placeholder: String?
    public var prefill: String?
    public var timeout: Double?
    public var notifyType: String?
    public var statusKey: String?
    public var statusText: String?
    public var widgetKey: String?
    public var widgetLines: [String]?
    public var widgetPlacement: String?
    public var text: String?

    public init?(json: JSON) {
        guard let id = json["id"]?.string, let method = json["method"]?.string.flatMap(Method.init(rawValue:)) else {
            return nil
        }
        self.id = id
        self.method = method
        title = json["title"]?.string
        message = json["message"]?.string
        options = json["options"]?.strings ?? []
        placeholder = json["placeholder"]?.string
        prefill = json["prefill"]?.string
        timeout = json["timeout"]?.double
        notifyType = json["notifyType"]?.string
        statusKey = json["statusKey"]?.string
        statusText = json["statusText"]?.string
        widgetKey = json["widgetKey"]?.string
        widgetLines = json["widgetLines"]?.array?.compactMap(\.string)
        widgetPlacement = json["widgetPlacement"]?.string
        text = json["text"]?.string
    }

    public var isDialog: Bool {
        switch method {
        case .select, .confirm, .input, .editor: return true
        default: return false
        }
    }
}
