import Foundation

// Bodies of the daemon's HTTP routes, matching `protocol/src/http.ts`.

public struct GitFile: Decodable, Hashable, Sendable {
    public var path: String
    /// Porcelain v2 staged-side code, "." when unchanged.
    public var index: String
    /// Porcelain v2 worktree-side code, "." when unchanged.
    public var work: String
    public var from: String?
    public var untracked: Bool?
    public var unmerged: Bool?
}

public struct GitUpstream: Decodable, Hashable, Sendable {
    public var name: String
    public var ahead: Int
    public var behind: Int
}

public struct GitStatus: Decodable, Hashable, Sendable {
    public var root: String
    public var prefix: String
    public var branch: String?
    public var head: String?
    /// Read from local refs only, so as fresh as the last fetch.
    public var upstream: GitUpstream?
    public var staged: Int
    public var unstaged: Int
    public var untracked: Int
    public var conflicted: Int
    public var files: [GitFile]
    /// `files` was cut short; the counts are still exact.
    public var truncated: Bool
    public var operation: String?
    public var stashes: Int
    public var remotes: [String]
    public var defaultRemote: String?

    public var changedCount: Int { staged + unstaged + untracked + conflicted }
}

public struct GitLogEntry: Decodable, Hashable, Sendable, Identifiable {
    public var sha: String
    public var subject: String
    public var author: String
    public var at: Double
    public var refs: [String]
    public var id: String { sha }
}

public struct GitBranch: Decodable, Hashable, Sendable, Identifiable {
    public var name: String
    public var remote: Bool
    public var current: Bool
    public var sha: String
    public var subject: String
    public var at: Double
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var gone: Bool
    public var id: String { (remote ? "r:" : "l:") + name }
}

public struct GitBranches: Decodable, Hashable, Sendable {
    public var current: String?
    public var detached: Bool
    public var local: [GitBranch]
    public var remote: [GitBranch]
    public var remotes: [String]
}

public struct GitStash: Decodable, Hashable, Sendable, Identifiable {
    public var ref: String
    public var message: String
    public var at: Double
    public var branch: String?
    /// Refs shift as stashes are dropped; the message and time do not.
    public var id: String { "\(ref):\(at)" }

    /// The stash's own words, without the "On <branch>:" git puts in front.
    public var title: String {
        guard let range = message.range(of: #"^(?:WIP on|On) [^:]+: "#, options: .regularExpression) else { return message }
        let rest = String(message[range.upperBound...])
        return rest.isEmpty ? message : rest
    }
}

/// Everything the git view can ask the daemon to do.
public enum GitAction: Hashable, Sendable {
    case stage([String])
    case stageAll
    case unstage([String])
    case unstageAll
    case discard([String])
    case commit(message: String, amend: Bool)
    case stash(message: String?)
    case stashPop(ref: String?)
    case stashApply(ref: String)
    case stashDrop(ref: String)
    case checkout(branch: String, create: Bool, from: String?)
    case deleteBranch(branch: String, force: Bool)
    case merge(branch: String)
    case abort
    case `continue`
    case initialize
    case fetch(prune: Bool)
    case pull(rebase: Bool)
    case push(force: Bool, setUpstream: Bool)

    public var kind: String {
        switch self {
        case .stage: return "stage"
        case .stageAll: return "stage_all"
        case .unstage: return "unstage"
        case .unstageAll: return "unstage_all"
        case .discard: return "discard"
        case .commit: return "commit"
        case .stash: return "stash"
        case .stashPop: return "stash_pop"
        case .stashApply: return "stash_apply"
        case .stashDrop: return "stash_drop"
        case .checkout: return "checkout"
        case .deleteBranch: return "delete_branch"
        case .merge: return "merge"
        case .abort: return "abort"
        case .continue: return "continue"
        case .initialize: return "init"
        case .fetch: return "fetch"
        case .pull: return "pull"
        case .push: return "push"
        }
    }

    public var json: JSON {
        var fields: [String: JSON?] = ["type": .string(kind)]
        switch self {
        case let .stage(paths), let .unstage(paths), let .discard(paths):
            fields["paths"] = .array(paths.map(JSON.string))
        case let .commit(message, amend):
            fields["message"] = .string(message)
            fields["amend"] = .bool(amend)
        case let .stash(message):
            fields["message"] = message.json
        case let .stashPop(ref):
            fields["ref"] = ref.json
        case let .stashApply(ref), let .stashDrop(ref):
            fields["ref"] = .string(ref)
        case let .checkout(branch, create, from):
            fields["branch"] = .string(branch)
            fields["create"] = create ? .bool(true) : nil
            fields["from"] = from.json
        case let .deleteBranch(branch, force):
            fields["branch"] = .string(branch)
            fields["force"] = force ? .bool(true) : nil
        case let .merge(branch):
            fields["branch"] = .string(branch)
        case let .fetch(prune):
            fields["prune"] = prune ? .bool(true) : nil
        case let .pull(rebase):
            fields["rebase"] = rebase ? .bool(true) : nil
        case let .push(force, setUpstream):
            fields["force"] = force ? .bool(true) : nil
            fields["setUpstream"] = setUpstream ? .bool(true) : nil
        case .stageAll, .unstageAll, .abort, .continue, .initialize:
            break
        }
        return .compact(fields)
    }

    /// Fetch, pull and push: the ones whose progress text is worth showing.
    public var isRemote: Bool {
        switch self {
        case .fetch, .pull, .push: return true
        default: return false
        }
    }

    /// A sentence naming what it will do, for anything not plainly undoable.
    /// Nil means it just runs.
    public var confirmation: String? {
        switch self {
        case let .discard(paths):
            return "Discard changes to \(paths.joined(separator: ", "))? They are stashed, so `git stash pop` brings them back."
        case let .stashDrop(ref):
            return "Drop \(ref)? A dropped stash is not recoverable from the app."
        case .abort:
            return "Abort the operation in progress? Everything it had applied is undone."
        case let .deleteBranch(branch, force):
            return force ? "Force-delete \(branch)? Unmerged commits on it are lost." : "Delete \(branch)?"
        case let .commit(_, amend):
            return amend ? "Amend the last commit? It gets a new hash." : nil
        case let .push(force, _):
            return force ? "Force-push with lease? It overwrites the remote branch unless someone else pushed first." : nil
        default:
            return nil
        }
    }

    /// The verb on the confirm button, so it names the deed.
    public var confirmLabel: String {
        switch self {
        case .discard: return "Discard"
        case .stashDrop: return "Drop"
        case .abort: return "Abort"
        case .deleteBranch: return "Delete"
        case .commit: return "Amend"
        case .push: return "Force push"
        default: return "Confirm"
        }
    }

    /// The one action that unsticks a failure, when there is one. A refused
    /// fast-forward is the common remote failure, and its fix is a rebase pull.
    public static func recovery(for error: String) -> (label: String, action: GitAction)? {
        let lowered = error.lowercased()
        guard lowered.contains("diverg") || lowered.contains("fast-forward") || lowered.contains("fast forward") else { return nil }
        return ("Pull with rebase", .pull(rebase: true))
    }
}

public extension GitStatus {
    /// The chat header's summary: whether anything is pending, and any
    /// operation in progress, which matters more than any count.
    var chip: (operation: String?, counts: String) {
        var counts: [String] = []
        if let behind = upstream?.behind, behind > 0 { counts.append("\u{2193}\(behind)") }
        if let ahead = upstream?.ahead, ahead > 0 { counts.append("\u{2191}\(ahead)") }
        if conflicted > 0 { counts.append("!\(conflicted)") }
        let changed = staged + unstaged + untracked
        if changed > 0 { counts.append("\u{00B1}\(changed)") }
        return (operation?.uppercased(), counts.joined(separator: " "))
    }

    /// What the working tree amounts to, in words.
    var summary: String {
        var parts: [String] = []
        if conflicted > 0 { parts.append("\(conflicted) conflicted") }
        if staged > 0 { parts.append("\(staged) staged") }
        if unstaged > 0 { parts.append("\(unstaged) changed") }
        if untracked > 0 { parts.append("\(untracked) untracked") }
        return parts.isEmpty ? "Working tree clean" : parts.joined(separator: " \u{00B7} ")
    }
}

public extension GitFile {
    enum Tone: Sendable { case add, remove, warn, muted }

    /// Single-letter label for a file row, worst state first.
    var mark: (mark: String, tone: Tone) {
        if unmerged == true { return ("!", .warn) }
        if untracked == true { return ("?", .muted) }
        let code = index != "." ? index : work
        switch code {
        case "D": return ("D", .remove)
        case "A": return ("A", .add)
        case "R": return ("R", .add)
        default: return ("M", .add)
        }
    }

    var isStaged: Bool { index != "." && unmerged != true }
}

public struct PatchLine: Hashable, Sendable {
    public enum Kind: Sendable { case add, remove, same, meta }
    public var kind: Kind
    public var text: String
}

/// Above this a patch is not readable on a phone.
private let maxPatchLines = 1200

/// Splits a unified diff into renderable lines, hunk headers kept as meta.
/// The indentation every content line shares carries no information but
/// costs a phone's whole width, so it is removed; markers keep their column.
public func patchLines(_ patch: String) -> [PatchLine] {
    var out: [(kind: PatchLine.Kind, marker: String, body: String)] = []
    for text in patch.components(separatedBy: "\n").prefix(maxPatchLines) {
        if text.hasPrefix("+++") || text.hasPrefix("---") || text.hasPrefix("@@") || text.hasPrefix("\\") {
            out.append((.meta, "", text))
            continue
        }
        if text.hasPrefix("diff ") || text.hasPrefix("index ") || text.hasPrefix("new ") { continue }
        let kind: PatchLine.Kind = text.hasPrefix("+") ? .add : text.hasPrefix("-") ? .remove : .same
        out.append((kind, String(text.prefix(1)), String(text.dropFirst())))
    }
    // A trailing blank from the final newline is not a line of the patch.
    if let last = out.last, last.body.isEmpty, last.marker.isEmpty { out.removeLast() }

    let shared = commonIndent(out.filter { $0.kind != .meta }.map(\.body))
    return out.map { line in
        PatchLine(kind: line.kind, text: line.marker + (line.kind == .meta ? line.body : String(line.body.dropFirst(shared))))
    }
}

/// Leading whitespace every non-blank line shares. Blank lines are skipped:
/// counting them as zero would defeat the trim on every hunk with one.
private func commonIndent(_ bodies: [String]) -> Int {
    var shared: [Character]?
    for body in bodies where !body.trimmingCharacters(in: .whitespaces).isEmpty {
        let indent = Array(body.prefix { $0 == " " || $0 == "\t" })
        guard let current = shared else {
            shared = indent
            continue
        }
        var count = 0
        while count < current.count, count < indent.count, current[count] == indent[count] { count += 1 }
        shared = Array(current.prefix(count))
        if count == 0 { break }
    }
    return shared?.count ?? 0
}

/// A directory listing from `/dirs`: folders for the picker, or the project
/// tree including files.
public struct DirectoryListing: Decodable, Hashable, Sendable {
    public struct Entry: Decodable, Hashable, Sendable, Identifiable {
        public var name: String
        public var path: String
        public var dir: Bool?
        public var lastSessionAt: Double?
        public var id: String { path }
    }

    public var root: String
    public var path: String
    public var name: String
    public var parent: String?
    public var entries: [Entry]
}

public struct FileMatches: Decodable, Sendable {
    public var cwd: String
    public var files: [String]
}

/// The editor's view of a file: text plus what is needed to save it back.
public struct TextFile: Decodable, Hashable, Sendable {
    public var etag: String
    public var bytes: Int
    /// LF-normalised, or the head of it when `editable` is false.
    public var text: String
    public var eol: String
    public var trailingNewline: Bool
    public var editable: Bool
    public var reason: String?

    /// Why editing is refused, in words.
    public var refusal: String? {
        switch reason {
        case "too_large": return "Too large to edit. Showing the start of the file."
        case "binary": return "Not a text file. Showing the start of it as text."
        case "long_lines": return "Lines are too long to edit. Showing the start of the file."
        default: return editable ? nil : "Read only."
        }
    }
}

public struct UsageReport: Decodable, Hashable, Sendable {
    public struct Window: Decodable, Hashable, Sendable, Identifiable {
        public var key: String
        public var label: String
        public var percent: Double
        public var resetsAt: String?
        public var id: String { key }
    }

    public struct Spend: Decodable, Hashable, Sendable {
        public var used: Double
        public var limit: Double?
        public var currency: String
        public var exponent: Int
    }

    public var windows: [Window]
    public var spend: Spend?
    public var fetchedAt: Double
}

/// "resets in 4h 22m": the only part of the timestamp worth reading.
public func resetsIn(_ iso: String, now: Date = Date()) -> String? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let at = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
    let minutes = Int((at.timeIntervalSince(now) / 60).rounded())
    if minutes <= 0 { return "resets now" }
    if minutes < 60 { return "resets in \(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "resets in \(hours)h \(minutes % 60)m" }
    return "resets in \(hours / 24)d \(hours % 24)h"
}
