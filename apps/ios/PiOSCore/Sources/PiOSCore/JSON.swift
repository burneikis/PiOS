import Foundation

/// Untyped JSON.
///
/// pi adds fields between minor versions and the wire schemas are loose on
/// purpose, so frames are read field by field from this rather than through
/// strict `Codable` structs that would reject a payload with a new key.
public enum JSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public subscript(key: String) -> JSON? {
        if case let .object(fields) = self { return fields[key] }
        return nil
    }

    public subscript(index: Int) -> JSON? {
        if case let .array(items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    public var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var double: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    public var int: Int? {
        guard case let .number(value) = self, value.isFinite else { return nil }
        return Int(value)
    }

    public var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var array: [JSON]? {
        if case let .array(items) = self { return items }
        return nil
    }

    public var object: [String: JSON]? {
        if case let .object(fields) = self { return fields }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Strings of an array, skipping anything that is not one.
    public var strings: [String] {
        array?.compactMap(\.string) ?? []
    }
}

extension JSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSON].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value):
            // Integral values go out as integers: the daemon validates some
            // fields with `.int()`, and `3.0` is not what it expects to read.
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

public extension JSON {
    static func parse(_ data: Data) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data)
    }

    static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    func encodedString() -> String {
        String(decoding: encoded(), as: UTF8.self)
    }

    /// Pretty text for showing arguments to a person.
    func prettyString() -> String {
        if let string { return string }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Optional values become absent keys rather than `null`, as zod expects.
    static func compact(_ fields: [String: JSON?]) -> JSON {
        .object(fields.compactMapValues { $0 })
    }
}

public extension Optional where Wrapped == String {
    var json: JSON? { map(JSON.string) }
}

public extension Optional where Wrapped == Bool {
    var json: JSON? { map(JSON.bool) }
}

public extension Optional where Wrapped == Int {
    var json: JSON? { map { JSON.number(Double($0)) } }
}
