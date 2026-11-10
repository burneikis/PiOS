import Foundation
import PiOSCore

struct PairResult: Decodable {
    var deviceToken: String
    var deviceId: String
    var serverVersion: String?
}

enum MachineAPIError: LocalizedError {
    case status(Int, String?)
    case badURL

    var errorDescription: String? {
        switch self {
        case .status(401, _): return "The machine refused this device (401)."
        case let .status(code, message): return message ?? "Request failed (\(code))."
        case .badURL: return "The machine URL is not valid."
        }
    }
}

/// Which project a route is about: a session, or for a draft, which has no
/// session yet, the directory it names.
struct Project: Hashable {
    var sessionId: String
    var cwd: String?

    var query: [URLQueryItem] {
        var items = [URLQueryItem(name: "session", value: sessionId)]
        if let cwd { items.append(.init(name: "cwd", value: cwd)) }
        return items
    }
}

enum SaveResult {
    case saved(etag: String)
    /// The file changed underneath: the agent or another device wrote it.
    case conflict(etag: String)
    case failed(String)
}

/// The daemon's HTTP routes. Every call but `/pair` and `/health` carries the
/// device token, and none of them touches the WebSocket.
struct MachineAPI {
    var base: URL
    var token: String?

    /// Splits a pasted `pios-server pair` link into its origin and token.
    /// The token rides in the fragment, which never reaches a server log.
    static func parsePairingLink(_ input: String) -> (origin: URL, token: String)? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("pios://") { text = "https://" + text.dropFirst("pios://".count) }
        guard let components = URLComponents(string: text), let fragment = components.fragment,
              let scheme = components.scheme, let host = components.host
        else { return nil }
        let pairs = URLComponents(string: "?" + fragment)?.queryItems ?? []
        guard let token = pairs.first(where: { $0.name == "pt" })?.value, !token.isEmpty else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = components.port
        return origin.url.map { ($0, token) }
    }

    func pair(pairingToken: String, label: String) async throws -> PairResult {
        var request = URLRequest(url: base.appendingPathComponent("pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = JSON.object(["pairingToken": .string(pairingToken), "label": .string(label)]).encoded()
        return try await decode(request)
    }

    /// Whether the machine revoked this device. Only an authenticated route
    /// answering 401 proves it; a relay hiccup must never cost a pairing.
    func isRevoked() async -> Bool {
        guard let request = try? authorized("push/key", []) else { return false }
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 401
    }

    // MARK: Directories and files

    /// Directories under home, newest pi work first.
    func directories(path: String?) async throws -> DirectoryListing {
        try await decode(try authorized("dirs", path.map { [.init(name: "path", value: $0)] } ?? []))
    }

    /// The project tree, files included, rooted at the session's directory.
    func tree(_ project: Project, path: String?) async throws -> DirectoryListing {
        var query = project.query + [.init(name: "files", value: "1")]
        if let path { query.append(.init(name: "path", value: path)) }
        return try await decode(try authorized("dirs", query))
    }

    /// Fuzzy file search in the project: gitignore-aware, daemon-side.
    func findFiles(_ project: Project, query: String, limit: Int = 30) async throws -> FileMatches {
        try await decode(try authorized("files", project.query + [.init(name: "q", value: query), .init(name: "limit", value: String(limit))]))
    }

    func textFile(_ project: Project, path: String) async throws -> TextFile {
        let request = try authorized("file", project.query + [.init(name: "path", value: path), .init(name: "text", value: "1")])
        return try await decode(request)
    }

    /// Saves against the etag the text was loaded from; `force` overwrites
    /// whatever is there now.
    func saveText(_ project: Project, path: String, text: String, file: TextFile, force: Bool) async throws -> SaveResult {
        var request = try authorized("file", project.query + [
            .init(name: "path", value: path), .init(name: "eol", value: file.eol),
            .init(name: "nl", value: file.trailingNewline ? "1" : "0"),
        ])
        request.httpMethod = "PUT"
        request.setValue(force ? "*" : file.etag, forHTTPHeaderField: "if-match")
        request.setValue("text/plain", forHTTPHeaderField: "content-type")
        request.httpBody = Data(text.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = try? JSON.parse(data)
        if (200 ..< 300).contains(status), let etag = body?["etag"]?.string { return .saved(etag: etag) }
        if status == 409, let etag = body?["etag"]?.string { return .conflict(etag: etag) }
        return .failed(body?["error"]?.string ?? "Save failed (\(status)).")
    }

    /// Raw bytes of a project file, for images and downloads.
    func file(_ project: Project, path: String) async throws -> Data {
        let request = try authorized("file", project.query + [.init(name: "path", value: path)])
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return data
    }

    /// Bytes of an image the transcript refers to by name. Content-addressed,
    /// so a cache may keep them for good.
    func image(ref: String) async throws -> Data {
        let request = try authorized("image", [.init(name: "name", value: ref)])
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return data
    }

    // MARK: Git

    /// Nil is the daemon saying "not a repository", a different fact from a
    /// failed read, which throws.
    func gitStatus(_ project: Project, fresh: Bool) async throws -> GitStatus? {
        struct Body: Decodable { var status: GitStatus? }
        var query = project.query
        if fresh { query.append(.init(name: "fresh", value: "1")) }
        let body: Body = try await decode(try authorized("git/status", query))
        return body.status
    }

    enum DiffSubject: Hashable {
        case file(path: String, staged: Bool)
        case commit(String)
        case stash(String)
    }

    func gitDiff(_ project: Project, _ subject: DiffSubject) async throws -> String {
        struct Body: Decodable { var diff: String? }
        var query = project.query
        switch subject {
        case let .file(path, staged):
            query.append(.init(name: "path", value: path))
            if staged { query.append(.init(name: "staged", value: "1")) }
        case let .commit(sha): query.append(.init(name: "commit", value: sha))
        case let .stash(ref): query.append(.init(name: "stash", value: ref))
        }
        let body: Body = try await decode(try authorized("git/diff", query))
        return body.diff ?? ""
    }

    func gitLog(_ project: Project, skip: Int, limit: Int = 40) async throws -> [GitLogEntry] {
        struct Body: Decodable { var commits: [GitLogEntry] }
        let query = project.query + [.init(name: "skip", value: String(skip)), .init(name: "limit", value: String(limit))]
        let body: Body = try await decode(try authorized("git/log", query))
        return body.commits
    }

    func gitBranches(_ project: Project) async throws -> GitBranches? {
        struct Body: Decodable { var branches: GitBranches? }
        let body: Body = try await decode(try authorized("git/branches", project.query))
        return body.branches
    }

    func gitStashes(_ project: Project) async throws -> [GitStash] {
        struct Body: Decodable { var stashes: [GitStash] }
        let body: Body = try await decode(try authorized("git/stashes", project.query))
        return body.stashes
    }

    /// Runs an action; the recomputed status and git's own output come back
    /// on the response, so the view never needs a second round trip.
    func gitAction(_ project: Project, _ action: GitAction) async throws -> (status: GitStatus?, output: String) {
        struct Body: Decodable { var status: GitStatus?; var output: String? }
        var request = try authorized("git/action", project.query)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = action.json.encoded()
        // Push and pull can sit on a slow remote.
        request.timeoutInterval = 180
        let body: Body = try await decode(request)
        return (body.status, body.output ?? "")
    }

    // MARK: Usage

    /// Plan usage for pi's Anthropic login; nil when the machine has none.
    func usage() async throws -> UsageReport? {
        struct Body: Decodable { var usage: UsageReport? }
        let body: Body = try await decode(try authorized("usage", []))
        return body.usage
    }

    // MARK: Plumbing

    private func authorized(_ path: String, _ query: [URLQueryItem]) throws -> URLRequest {
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw MachineAPIError.badURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw MachineAPIError.badURL }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        return request
    }

    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard !(200 ..< 300).contains(status) else { return }
        // The daemon reports a failed git invocation verbatim; it is the only
        // useful thing to show.
        let body = try? JSON.parse(data)
        throw MachineAPIError.status(status, body?["message"]?.string ?? body?["error"]?.string)
    }
}
