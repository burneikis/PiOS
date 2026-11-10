import Foundation

/// An image block. `data` is empty when the daemon sent `ref` instead and the
/// bytes are fetched from its `/image` route.
public struct ImageContent: Hashable, Codable, Sendable {
    public var data: String
    public var mimeType: String
    public var ref: String?
    public var width: Double?
    public var height: Double?

    public init(data: String, mimeType: String, ref: String? = nil, width: Double? = nil, height: Double? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.ref = ref
        self.width = width
        self.height = height
    }

    public init?(json: JSON) {
        guard json["type"]?.string == "image", let mimeType = json["mimeType"]?.string else { return nil }
        self.init(
            data: json["data"]?.string ?? "",
            mimeType: mimeType,
            ref: json["ref"]?.string,
            width: json["width"]?.double,
            height: json["height"]?.double
        )
    }

    public var json: JSON {
        .compact([
            "type": "image",
            "data": .string(data),
            "mimeType": .string(mimeType),
            "ref": ref.json,
            "width": width.map(JSON.number),
            "height": height.map(JSON.number),
        ])
    }
}

public struct ToolCall: Hashable, Sendable {
    public var id: String
    public var name: String
    public var arguments: JSON

    public init(id: String, name: String, arguments: JSON) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public init?(json: JSON) {
        guard let id = json["id"]?.string, let name = json["name"]?.string else { return nil }
        self.init(id: id, name: name, arguments: json["arguments"] ?? .null)
    }
}

public enum ContentPart: Hashable, Sendable {
    case text(String)
    case thinking(String)
    case image(ImageContent)
    case toolCall(ToolCall)

    init?(json: JSON) {
        switch json["type"]?.string {
        case "text": self = .text(json["text"]?.string ?? "")
        case "thinking": self = .thinking(json["thinking"]?.string ?? "")
        case "image":
            guard let image = ImageContent(json: json) else { return nil }
            self = .image(image)
        case "toolCall":
            guard let call = ToolCall(json: json) else { return nil }
            self = .toolCall(call)
        default: return nil
        }
    }
}

public struct Usage: Hashable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var costTotal: Double?

    init?(json: JSON?) {
        guard let json, json.object != nil else { return nil }
        input = json["input"]?.double ?? 0
        output = json["output"]?.double ?? 0
        cacheRead = json["cacheRead"]?.double ?? 0
        cacheWrite = json["cacheWrite"]?.double ?? 0
        costTotal = json["cost"]?["total"]?.double
    }
}

/// One message of the conversation, as pi puts it on the wire.
///
/// A single struct rather than an enum per role: most fields are read by
/// several views, and the roles share more than they differ. `raw` keeps the
/// original so the persisted cache round-trips what the daemon sent.
public struct AgentMessage: Hashable, Sendable {
    public enum Role: String, Sendable {
        case system, user, assistant, toolResult, bashExecution
    }

    public var role: Role
    public var content: [ContentPart]
    public var timestamp: Double?
    // assistant
    public var provider: String?
    public var model: String?
    public var stopReason: String?
    public var errorMessage: String?
    public var usage: Usage?
    // toolResult
    public var toolCallId: String?
    public var toolName: String?
    public var isError: Bool
    // bashExecution
    public var command: String?
    public var output: String?
    public var exitCode: Int?
    public var cancelled: Bool
    public var truncated: Bool
    public var excludeFromContext: Bool

    public var raw: JSON

    public init?(json: JSON) {
        guard let roleName = json["role"]?.string, let role = Role(rawValue: roleName) else { return nil }
        self.role = role
        if let text = json["content"]?.string {
            content = [.text(text)]
        } else {
            content = json["content"]?.array?.compactMap(ContentPart.init(json:)) ?? []
        }
        timestamp = json["timestamp"]?.double
        provider = json["provider"]?.string
        model = json["model"]?.string
        stopReason = json["stopReason"]?.string
        errorMessage = json["errorMessage"]?.string
        usage = Usage(json: json["usage"])
        toolCallId = json["toolCallId"]?.string
        toolName = json["toolName"]?.string
        isError = json["isError"]?.bool ?? false
        command = json["command"]?.string
        output = json["output"]?.string
        exitCode = json["exitCode"]?.int
        cancelled = json["cancelled"]?.bool ?? false
        truncated = json["truncated"]?.bool ?? false
        excludeFromContext = json["excludeFromContext"]?.bool ?? false
        raw = json
        if role == .toolResult, toolCallId == nil { return nil }
    }

    /// Text of the message, ignoring thinking and tool calls.
    public var text: String {
        if role == .bashExecution { return output ?? "" }
        return content.compactMap { part in
            if case let .text(text) = part { return text }
            return nil
        }.joined()
    }

    public var images: [ImageContent] {
        content.compactMap { part in
            if case let .image(image) = part { return image }
            return nil
        }
    }

    /// Why an assistant turn failed, or nil when it did not.
    public var turnFailure: String? {
        guard role == .assistant, stopReason == "error" else { return nil }
        let readable = readableError(errorMessage ?? "")
        return readable.isEmpty ? "The model request failed." : readable
    }

    /// A one-line name: image parts keep their place as `<image>`.
    public var preview: String {
        guard role == .user else { return previewText(text) }
        let parts = content.map { part -> String in
            switch part {
            case let .text(text): return text
            case .image: return "<image>"
            default: return ""
            }
        }
        return previewText(parts.joined(separator: " "))
    }
}

/// A node of the session tree. `id` is the resume cursor.
public struct SessionEntry: Hashable, Sendable, Codable {
    public var id: String
    public var parentId: String?
    public var type: String
    public var message: AgentMessage?
    public var raw: JSON

    public init?(json: JSON) {
        guard let id = json["id"]?.string, let type = json["type"]?.string else { return nil }
        self.id = id
        parentId = json["parentId"]?.string
        self.type = type
        message = json["message"].flatMap(AgentMessage.init(json:))
        raw = json
    }

    public init(from decoder: Decoder) throws {
        let json = try JSON(from: decoder)
        guard let entry = SessionEntry(json: json) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an entry"))
        }
        self = entry
    }

    public func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }
}

/// Blocks pi or a client injects into a user message. Long, machine-facing,
/// and they would otherwise become the session's name.
private let injectedTags = [
    "skill", "available_skills", "system-reminder", "project_context",
    "project_instructions", "environment", "context",
]

private let injectedBlocks: NSRegularExpression = {
    let tags = injectedTags.joined(separator: "|")
    let pattern = "<(\(tags))(\\s[^>]*)?>[\\s\\S]*?</\\1>|<(\(tags))(\\s[^>]*)?/?>"
    return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}()

private let pastedImagePath = try! NSRegularExpression(
    pattern: "(^|\\s)/tmp/[\\w.-]*\\.(png|jpe?g|gif|webp|bmp)(?=\\s|$)",
    options: [.caseInsensitive]
)

private let nameAttribute = try! NSRegularExpression(
    pattern: "name\\s*=\\s*[\"']([^\"']+)[\"']",
    options: [.caseInsensitive]
)

/// Message text as a human-facing one-liner.
public func previewText(_ text: String) -> String {
    let source = text as NSString
    var result = ""
    var cursor = 0
    for match in injectedBlocks.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
        let tagRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 3)
        let attrRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 4)
        let label = tagRange.location != NSNotFound ? source.substring(with: tagRange).lowercased() : ""
        var name: String?
        if attrRange.location != NSNotFound {
            let attrs = source.substring(with: attrRange)
            if let found = nameAttribute.firstMatch(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)) {
                name = (attrs as NSString).substring(with: found.range(at: 1))
            }
        }
        result += " <\(name.map { "\(label):\($0)" } ?? label)> "
        cursor = match.range.location + match.range.length
    }
    result += source.substring(from: cursor)
    let mutable = NSMutableString(string: result)
    _ = pastedImagePath.replaceMatches(in: mutable, range: NSRange(location: 0, length: mutable.length), withTemplate: "$1 <image> ")
    let collapsed = collapseWhitespace(mutable as String)
    return collapsed.isEmpty ? collapseWhitespace(text) : collapsed
}

func collapseWhitespace(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// A provider error as one readable line. pi reports HTTP failures as
/// `<status>: <json body>`, which buries the one sentence a person needs.
public func readableError(_ raw: String) -> String {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count > 4, let first = text.firstIndex(of: "{") else { return text }
    let head = text[..<first].trimmingCharacters(in: CharacterSet(charactersIn: ": "))
    guard head.count == 3, head.allSatisfy(\.isNumber) else { return text }
    guard let body = try? JSON.parse(String(text[first...])) else { return text }
    let message = body["error"]?["message"]?.string ?? body["message"]?.string
    guard let message, !message.trimmingCharacters(in: .whitespaces).isEmpty else { return text }
    return "\(head): \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
}
