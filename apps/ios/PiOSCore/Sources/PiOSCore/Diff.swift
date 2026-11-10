import Foundation

public struct DiffLine: Hashable, Sendable {
    public enum Kind: Sendable { case same, add, remove }
    public var kind: Kind
    public var text: String
}

/// Above this many lines the table is not worth the memory on a phone.
private let maxDiffLines = 800

/// Line diff via LCS. Large sides fall back to a whole-block replacement: an
/// exact diff of a 5000-line file is unreadable on a phone anyway.
public func diffLines(_ before: String, _ after: String) -> [DiffLine] {
    let a = before.components(separatedBy: "\n")
    let b = after.components(separatedBy: "\n")
    if a.count > maxDiffLines || b.count > maxDiffLines {
        return a.map { DiffLine(kind: .remove, text: $0) } + b.map { DiffLine(kind: .add, text: $0) }
    }
    var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
        for j in stride(from: b.count - 1, through: 0, by: -1) {
            lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
        }
    }
    var out: [DiffLine] = []
    var i = 0
    var j = 0
    while i < a.count, j < b.count {
        if a[i] == b[j] {
            out.append(.init(kind: .same, text: a[i]))
            i += 1
            j += 1
        } else if lcs[i + 1][j] >= lcs[i][j + 1] {
            out.append(.init(kind: .remove, text: a[i]))
            i += 1
        } else {
            out.append(.init(kind: .add, text: b[j]))
            j += 1
        }
    }
    while i < a.count { out.append(.init(kind: .remove, text: a[i])); i += 1 }
    while j < b.count { out.append(.init(kind: .add, text: b[j])); j += 1 }
    return out
}

public struct EditBlock: Hashable, Sendable {
    public var path: String?
    /// Nil for a whole-file write: there is nothing to diff against.
    public var oldText: String?
    public var newText: String
}

/// Recognises edit- and write-shaped tool arguments. Multi-edit calls carry
/// replacements in `edits[]` and the path on the call itself.
public func editBlocks(_ args: JSON?) -> [EditBlock] {
    guard let args, args.object != nil else { return [] }
    let path = args["path"]?.string
    if let edits = args["edits"]?.array { return edits.compactMap { editBlock($0, path: path) } }
    return editBlock(args, path: nil).map { [$0] } ?? []
}

private func editBlock(_ json: JSON, path: String?) -> EditBlock? {
    let oldText = json["oldText"]?.string ?? json["old_text"]?.string ?? json["old"]?.string
    guard let newText = json["newText"]?.string ?? json["new_text"]?.string ?? json["new"]?.string ?? json["content"]?.string
    else { return nil }
    return EditBlock(path: json["path"]?.string ?? path, oldText: oldText, newText: newText)
}

/// Argument keys shown on the card's row, so never repeated in its body.
public let headlineKeys = ["command", "path", "file_path", "pattern", "query", "url"]
/// Rendered as a diff or code block, so not printed again as arguments.
private let blockKeys: Set<String> = ["edits", "oldText", "old_text", "old", "newText", "new_text", "new", "content"]

public func toolHeadline(_ args: JSON?) -> String {
    for key in headlineKeys {
        if let value = args?[key]?.string { return value }
    }
    return ""
}

/// The arguments nothing else on the card shows, as `key: value` lines.
public func leftoverArgs(_ args: JSON?) -> String {
    guard let fields = args?.object else { return "" }
    let skip = Set(headlineKeys).union(blockKeys)
    return fields.keys.sorted().filter { !skip.contains($0) }.compactMap { key in
        guard let value = fields[key], !value.isNull else { return nil }
        return "\(key): \(value.string ?? value.prettyString())"
    }.joined(separator: "\n")
}

/// `.` for the cwd itself, cwd-relative inside it, else `~`-collapsed.
public func shortenPath(_ path: String, cwd: String?) -> String {
    let base = cwd.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 } ?? ""
    if !base.isEmpty, path == base { return "." }
    if !base.isEmpty, path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
    return collapseHome(path)
}

/// The client has no $HOME; it is inferred from the path itself.
public func collapseHome(_ path: String) -> String {
    for prefix in ["/home/", "/Users/"] where path.hasPrefix(prefix) {
        let rest = path.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return "~" }
        return "~" + rest[slash...]
    }
    if path == "/root" { return "~" }
    if path.hasPrefix("/root/") { return "~" + path.dropFirst(5) }
    return path
}

/// Shortens the `cd <dir> &&` prefix of a command and bare path arguments.
public func shortenPreview(_ headline: String, cwd: String?) -> String {
    if headline.hasPrefix("cd "), let range = headline.range(of: #"^cd\s+('[^']*'|"[^"]*"|[^\s;&]+)\s*(&&|;)\s*"#, options: .regularExpression) {
        let prefix = String(headline[range])
        let rest = String(headline[range.upperBound...])
        var dir = prefix.dropFirst(3).trimmingCharacters(in: .whitespaces)
        let separator = dir.hasSuffix(";") ? ";" : " &&"
        dir = dir.replacingOccurrences(of: #"\s*(&&|;)$"#, with: "", options: .regularExpression)
        dir = dir.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        let shown = shortenPath(dir, cwd: cwd)
        return shown == "." ? rest : "cd \(shown)\(separator) \(rest)"
    }
    if (headline.hasPrefix("/") || headline.hasPrefix("~")), !headline.contains(where: \.isWhitespace) {
        return shortenPath(headline, cwd: cwd)
    }
    return headline
}
