import Foundation

/// PiOS wire protocol: one WebSocket multiplexing every session. Bumped on any
/// breaking envelope change; a mismatch is refused, never guessed at.
public let wireVersion = 2

public enum StreamingBehavior: String, Codable, Sendable, CaseIterable {
    case steer
    case followUp
}

public struct ModelOption: Hashable, Codable, Sendable, Identifiable {
    public var provider: String
    public var modelId: String
    public var name: String
    /// In the scope pi was configured with; the picker shows these first.
    public var scoped: Bool

    public var id: String { "\(provider)/\(modelId)" }

    init?(json: JSON?) {
        guard let json, let provider = json["provider"]?.string, let modelId = json["modelId"]?.string else {
            return nil
        }
        self.provider = provider
        self.modelId = modelId
        name = json["name"]?.string ?? modelId
        scoped = json["scoped"]?.bool ?? false
    }
}

/// A slash command, invoked by sending `/name args` as an ordinary prompt.
public struct CommandOption: Hashable, Sendable, Identifiable {
    public var name: String
    public var description: String?
    public var source: String?

    public var id: String { name }

    init?(json: JSON) {
        guard let name = json["name"]?.string else { return nil }
        self.name = name
        description = json["description"]?.string
        source = json["source"]?.string
    }
}

public struct SessionSummary: Hashable, Sendable, Codable, Identifiable {
    public enum Status: String, Sendable {
        case cold, idle, running, crashed
    }

    public var sessionId: String
    public var name: String?
    public var cwd: String
    public var status: Status
    /// Blocked on an extension dialog; kept beside `status`, not folded in.
    public var awaitingInput: Bool
    public var trusted: Bool
    /// Durable cursor. Nil for a cold session, whose cursor is on disk.
    public var leafId: String?
    public var lastSeq: Int
    public var updatedAt: Double
    /// Last prompt or shell command, which the list is ordered by.
    public var activeAt: Double?
    public var messageCount: Int?
    public var preview: String?
    public var model: ModelOption?
    public var thinkingLevel: String?
    public var thinkingLevels: [String]
    public var autoCompaction: Bool?
    public var raw: JSON

    public var id: String { sessionId }

    public init?(json: JSON) {
        guard let sessionId = json["sessionId"]?.string, let cwd = json["cwd"]?.string else { return nil }
        self.sessionId = sessionId
        self.cwd = cwd
        name = json["name"]?.string
        status = json["status"]?.string.flatMap(Status.init(rawValue:)) ?? .cold
        awaitingInput = json["awaitingInput"]?.bool ?? false
        trusted = json["trusted"]?.bool ?? false
        leafId = json["leafId"]?.string
        lastSeq = json["lastSeq"]?.int ?? 0
        updatedAt = json["updatedAt"]?.double ?? 0
        activeAt = json["activeAt"]?.double
        messageCount = json["messageCount"]?.int
        preview = json["preview"]?.string
        model = ModelOption(json: json["model"])
        thinkingLevel = json["thinkingLevel"]?.string
        thinkingLevels = json["thinkingLevels"]?.strings ?? []
        autoCompaction = json["autoCompaction"]?.bool
        raw = json
    }

    public init(from decoder: Decoder) throws {
        let json = try JSON(from: decoder)
        guard let summary = SessionSummary(json: json) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a summary"))
        }
        self = summary
    }

    public func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }

    /// What the list orders by: the user's activity, not the agent's.
    public var sortKey: Double { activeAt ?? updatedAt }

    /// A row title that reads without opening the session.
    public var title: String {
        if let name, !name.isEmpty { return name }
        if let preview, !preview.isEmpty { return previewText(preview) }
        return (cwd as NSString).lastPathComponent
    }
}

/// Token, cost and context accounting for one session.
public struct SessionStats: Hashable, Sendable {
    public var userMessages: Int?
    public var assistantMessages: Int?
    public var toolCalls: Int?
    public var tokensInput: Double?
    public var tokensOutput: Double?
    public var tokensCacheRead: Double?
    public var tokensCacheWrite: Double?
    public var tokensTotal: Double?
    public var cost: Double?
    public var contextTokens: Double?
    public var contextWindow: Double?
    public var contextPercent: Double?

    init(json: JSON) {
        userMessages = json["userMessages"]?.int
        assistantMessages = json["assistantMessages"]?.int
        toolCalls = json["toolCalls"]?.int
        tokensInput = json["tokens"]?["input"]?.double
        tokensOutput = json["tokens"]?["output"]?.double
        tokensCacheRead = json["tokens"]?["cacheRead"]?.double
        tokensCacheWrite = json["tokens"]?["cacheWrite"]?.double
        tokensTotal = json["tokens"]?["total"]?.double
        cost = json["cost"]?.double
        contextTokens = json["contextUsage"]?["tokens"]?.double
        contextWindow = json["contextUsage"]?["contextWindow"]?.double
        contextPercent = json["contextUsage"]?["percent"]?.double
    }
}

/// Outcome of one `!` command.
public struct BashResult: Hashable, Sendable {
    public var output: String
    public var exitCode: Int?
    public var cancelled: Bool
    public var truncated: Bool
    public var fullOutputPath: String?

    public init(output: String = "", exitCode: Int? = nil, cancelled: Bool = false, truncated: Bool = false, fullOutputPath: String? = nil) {
        self.output = output
        self.exitCode = exitCode
        self.cancelled = cancelled
        self.truncated = truncated
        self.fullOutputPath = fullOutputPath
    }

    init(json: JSON) {
        self.init(
            output: json["output"]?.string ?? "",
            exitCode: json["exitCode"]?.int,
            cancelled: json["cancelled"]?.bool ?? false,
            truncated: json["truncated"]?.bool ?? false,
            fullOutputPath: json["fullOutputPath"]?.string
        )
    }
}

/// Brings a session into being under an id the client already composed against.
public struct SessionCreate: Hashable, Codable, Sendable {
    public var cwd: String
    public var name: String?
    /// Explicit: pi's headless trust default is not something to inherit.
    public var trustProject: Bool
    public var model: String?

    public init(cwd: String, name: String? = nil, trustProject: Bool = false, model: String? = nil) {
        self.cwd = cwd
        self.name = name
        self.trustProject = trustProject
        self.model = model
    }

    var json: JSON {
        .compact(["cwd": .string(cwd), "name": name.json, "trustProject": .bool(trustProject), "model": model.json])
    }
}

/// A client frame minus the envelope, which the client stamps on every send.
public enum ClientCommand: Sendable {
    case hello(deviceToken: String, clientVersion: String)
    case listSessions(cwd: String?, query: String?, limit: Int?, offset: Int?)
    case setSessionTrust(sessionId: String, trustProject: Bool)
    case subscribe(sessionId: String, sinceSeq: Int?)
    case unsubscribe(sessionId: String)
    case listModels(sessionId: String, all: Bool, create: SessionCreate?)
    case listCommands(sessionId: String)
    case getStats(sessionId: String)
    case setModel(sessionId: String, provider: String, modelId: String)
    case setThinkingLevel(sessionId: String, level: String)
    case setSessionName(sessionId: String, name: String)
    case compact(sessionId: String, customInstructions: String?)
    case setAutoCompaction(sessionId: String, enabled: Bool)
    case reloadSession(sessionId: String)
    case exportSession(sessionId: String, outputPath: String?)
    case getEntries(sessionId: String, since: String?, limit: Int?, before: Int?)
    case prompt(
        sessionId: String, messageId: String, text: String, images: [ImageContent],
        streamingBehavior: StreamingBehavior?, create: SessionCreate?
    )
    case interrupt(sessionId: String)
    case runBash(sessionId: String, command: String, excludeFromContext: Bool)
    case abortBash(sessionId: String)
    case rewind(sessionId: String, entryId: String)
    case extensionUiResponse(sessionId: String, requestId: String, value: String?, confirmed: Bool?, cancelled: Bool?)
    case activity(visible: Bool, focused: Bool, appState: String, sessionIds: [String])

    /// The full frame, envelope included.
    public func frame(commandId: String) -> JSON {
        var fields = self.fields
        fields["v"] = .number(Double(wireVersion))
        fields["commandId"] = .string(commandId)
        return .compact(fields)
    }

    private var fields: [String: JSON?] {
        switch self {
        case let .hello(token, version):
            return ["type": "hello", "deviceToken": .string(token), "clientVersion": .string(version)]
        case let .listSessions(cwd, query, limit, offset):
            return ["type": "list_sessions", "cwd": cwd.json, "query": query.json, "limit": limit.json, "offset": offset.json]
        case let .setSessionTrust(id, trust):
            return ["type": "set_session_trust", "sessionId": .string(id), "trustProject": .bool(trust)]
        case let .subscribe(id, since):
            return ["type": "subscribe", "sessionId": .string(id), "sinceSeq": since.json]
        case let .unsubscribe(id):
            return ["type": "unsubscribe", "sessionId": .string(id)]
        case let .listModels(id, all, create):
            return ["type": "list_models", "sessionId": .string(id), "all": .bool(all), "create": create?.json]
        case let .listCommands(id):
            return ["type": "list_commands", "sessionId": .string(id)]
        case let .getStats(id):
            return ["type": "get_stats", "sessionId": .string(id)]
        case let .setModel(id, provider, modelId):
            return ["type": "set_model", "sessionId": .string(id), "provider": .string(provider), "modelId": .string(modelId)]
        case let .setThinkingLevel(id, level):
            return ["type": "set_thinking_level", "sessionId": .string(id), "level": .string(level)]
        case let .setSessionName(id, name):
            return ["type": "set_session_name", "sessionId": .string(id), "name": .string(name)]
        case let .compact(id, instructions):
            return ["type": "compact", "sessionId": .string(id), "customInstructions": instructions.json]
        case let .setAutoCompaction(id, enabled):
            return ["type": "set_auto_compaction", "sessionId": .string(id), "enabled": .bool(enabled)]
        case let .reloadSession(id):
            return ["type": "reload_session", "sessionId": .string(id)]
        case let .exportSession(id, path):
            return ["type": "export_session", "sessionId": .string(id), "outputPath": path.json]
        case let .getEntries(id, since, limit, before):
            return ["type": "get_entries", "sessionId": .string(id), "since": since.json, "limit": limit.json, "before": before.json]
        case let .prompt(id, messageId, text, images, behavior, create):
            return [
                "type": "prompt", "sessionId": .string(id), "messageId": .string(messageId), "text": .string(text),
                "images": .array(images.map(\.json)), "streamingBehavior": behavior.map { .string($0.rawValue) },
                "create": create?.json,
            ]
        case let .interrupt(id):
            return ["type": "interrupt", "sessionId": .string(id)]
        case let .runBash(id, command, exclude):
            return ["type": "run_bash", "sessionId": .string(id), "command": .string(command), "excludeFromContext": .bool(exclude)]
        case let .abortBash(id):
            return ["type": "abort_bash", "sessionId": .string(id)]
        case let .rewind(id, entryId):
            return ["type": "rewind", "sessionId": .string(id), "entryId": .string(entryId)]
        case let .extensionUiResponse(id, requestId, value, confirmed, cancelled):
            return [
                "type": "extension_ui_response", "sessionId": .string(id), "requestId": .string(requestId),
                "value": value.json, "confirmed": confirmed.json, "cancelled": cancelled.json,
            ]
        case let .activity(visible, focused, appState, sessionIds):
            return [
                "type": "activity", "visible": .bool(visible), "focused": .bool(focused),
                "appState": .string(appState), "sessionIds": .array(sessionIds.map(JSON.string)),
            ]
        }
    }
}

public enum ErrorCode: String, Sendable {
    case unauthorized
    case unknownSession = "unknown_session"
    case unknownCursor = "unknown_cursor"
    case badRequest = "bad_request"
    case agentBusy = "agent_busy"
    case `internal`
}

/// A frame from the daemon. `commandId` echoes the request that caused it.
public struct ServerFrame: Sendable {
    public var commandId: String?
    public var sessionId: String?
    public var body: Body

    public enum Body: Sendable {
        case welcome(serverVersion: String, piVersion: String, sessions: [SessionSummary])
        case ack(commandId: String, duplicate: Bool)
        case subscribed(sessionId: String, seq: Int, gap: Bool)
        case error(code: ErrorCode, message: String)
        case sessions([SessionSummary], offset: Int, total: Int, hasMore: Bool)
        case sessionsChanged
        case models(sessionId: String, models: [ModelOption], all: Bool)
        case commands(sessionId: String, commands: [CommandOption])
        case sessionStats(sessionId: String, stats: SessionStats)
        case exported(sessionId: String, path: String)
        case sessionState(SessionSummary)
        case entries(sessionId: String, entries: [SessionEntry], leafId: String?, reset: Bool, offset: Int, total: Int)
        case agentEvent(sessionId: String, seq: Int, at: Double?, event: AgentEvent)
        case extensionUiRequest(sessionId: String, request: ExtensionUiRequest)
        case extensionUiClosed(sessionId: String, requestId: String)
        case extensionUiState(sessionId: String, presentation: SessionPresentation)
        case bashState(sessionId: String, command: String, excludeFromContext: Bool, running: Bool, result: BashResult?)
        case rewound(sessionId: String, branchSessionId: String, text: String?)
        case sessionRecovered(sessionId: String, leafId: String?, reason: String)
        /// Terminal frames and anything newer than this build.
        case unhandled(String)
    }

    public enum ParseError: Error, Equatable {
        case malformed
        case versionMismatch(Int?)
    }

    public init(text: String) throws {
        guard let json = try? JSON.parse(text) else { throw ParseError.malformed }
        try self.init(json: json)
    }

    public init(json: JSON) throws {
        guard let type = json["type"]?.string else { throw ParseError.malformed }
        let version = json["v"]?.int
        guard version == wireVersion else { throw ParseError.versionMismatch(version) }
        commandId = json["commandId"]?.string
        sessionId = json["sessionId"]?.string
        let sid = sessionId ?? ""

        func summaries(_ value: JSON?) -> [SessionSummary] {
            value?.array?.compactMap(SessionSummary.init(json:)) ?? []
        }

        switch type {
        case "welcome":
            body = .welcome(
                serverVersion: json["serverVersion"]?.string ?? "",
                piVersion: json["piVersion"]?.string ?? "",
                sessions: summaries(json["sessions"])
            )
        case "ack":
            body = .ack(commandId: commandId ?? "", duplicate: json["duplicate"]?.bool ?? false)
        case "subscribed":
            body = .subscribed(sessionId: sid, seq: json["seq"]?.int ?? 0, gap: json["gap"]?.bool ?? false)
        case "error":
            body = .error(
                code: json["code"]?.string.flatMap(ErrorCode.init(rawValue:)) ?? .internal,
                message: json["message"]?.string ?? "unknown error"
            )
        case "sessions":
            body = .sessions(
                summaries(json["sessions"]),
                offset: json["offset"]?.int ?? 0,
                total: json["total"]?.int ?? 0,
                hasMore: json["hasMore"]?.bool ?? false
            )
        case "sessions_changed":
            body = .sessionsChanged
        case "models":
            body = .models(
                sessionId: sid,
                models: json["models"]?.array?.compactMap { ModelOption(json: $0) } ?? [],
                all: json["all"]?.bool ?? false
            )
        case "commands":
            body = .commands(sessionId: sid, commands: json["commands"]?.array?.compactMap(CommandOption.init(json:)) ?? [])
        case "session_stats":
            body = .sessionStats(sessionId: sid, stats: SessionStats(json: json["stats"] ?? .object([:])))
        case "exported":
            body = .exported(sessionId: sid, path: json["path"]?.string ?? "")
        case "session_state":
            guard let summary = json["summary"].flatMap(SessionSummary.init(json:)) else { throw ParseError.malformed }
            body = .sessionState(summary)
        case "entries":
            body = .entries(
                sessionId: sid,
                entries: json["entries"]?.array?.compactMap(SessionEntry.init(json:)) ?? [],
                leafId: json["leafId"]?.string,
                reset: json["reset"]?.bool ?? false,
                offset: json["offset"]?.int ?? 0,
                total: json["total"]?.int ?? 0
            )
        case "agent_event":
            guard let event = json["event"].flatMap(AgentEvent.init(json:)) else { throw ParseError.malformed }
            body = .agentEvent(sessionId: sid, seq: json["seq"]?.int ?? 0, at: json["at"]?.double, event: event)
        case "extension_ui_request":
            guard let request = json["request"].flatMap(ExtensionUiRequest.init(json:)) else { throw ParseError.malformed }
            body = .extensionUiRequest(sessionId: sid, request: request)
        case "extension_ui_closed":
            body = .extensionUiClosed(sessionId: sid, requestId: json["requestId"]?.string ?? "")
        case "extension_ui_state":
            body = .extensionUiState(sessionId: sid, presentation: SessionPresentation(json: json["presentation"] ?? .object([:])))
        case "bash_state":
            body = .bashState(
                sessionId: sid,
                command: json["command"]?.string ?? "",
                excludeFromContext: json["excludeFromContext"]?.bool ?? false,
                running: json["running"]?.bool ?? false,
                result: json["result"].map(BashResult.init(json:))
            )
        case "rewound":
            body = .rewound(sessionId: sid, branchSessionId: json["branchSessionId"]?.string ?? "", text: json["text"]?.string)
        case "session_recovered":
            body = .sessionRecovered(sessionId: sid, leafId: json["leafId"]?.string, reason: json["reason"]?.string ?? "")
        default:
            body = .unhandled(type)
        }
    }
}
