import Foundation
import PiOSCore

struct PairResult: Decodable {
    var deviceToken: String
    var deviceId: String
    var serverVersion: String?
}

struct DirectoryListing: Decodable {
    struct Entry: Decodable, Identifiable, Hashable {
        var name: String
        var path: String
        var dir: Bool?
        var lastSessionAt: Double?
        var id: String { path }
    }

    var root: String
    var path: String
    var name: String
    var parent: String?
    var entries: [Entry]
}

struct FileMatches: Decodable {
    var cwd: String
    var files: [String]
}

struct TextFile: Decodable {
    var etag: String
    var bytes: Int
    var text: String
    var editable: Bool
    var reason: String?
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

    func health() async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("health"))
        request.timeoutInterval = 4
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Whether the machine revoked this device. Only an authenticated route
    /// answering 401 proves it; a relay hiccup must never cost a pairing.
    func isRevoked() async -> Bool {
        guard let request = try? authorized("push/key", []) else { return false }
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 401
    }

    /// Directories under home, newest pi work first; or, with a session,
    /// the project tree including files.
    func directories(path: String?, session: String? = nil, files: Bool = false) async throws -> DirectoryListing {
        var query: [URLQueryItem] = []
        if let path { query.append(.init(name: "path", value: path)) }
        if let session { query.append(.init(name: "session", value: session)) }
        if files { query.append(.init(name: "files", value: "1")) }
        return try await decode(try authorized("dirs", query))
    }

    /// Fuzzy file search in a session's directory, for `@` mentions.
    func findFiles(session: String, cwd: String?, query: String) async throws -> FileMatches {
        var items = [URLQueryItem(name: "session", value: session), .init(name: "q", value: query), .init(name: "limit", value: "20")]
        if let cwd { items.append(.init(name: "cwd", value: cwd)) }
        return try await decode(try authorized("files", items))
    }

    func textFile(session: String, path: String) async throws -> TextFile {
        try await decode(try authorized("file", [.init(name: "session", value: session), .init(name: "path", value: path), .init(name: "text", value: "1")]))
    }

    /// Bytes of an image the transcript refers to by name. Content-addressed,
    /// so the cache may keep them for good.
    func image(ref: String) async throws -> Data {
        let request = try authorized("image", [.init(name: "name", value: ref)])
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return data
    }

    func file(session: String, path: String) async throws -> Data {
        let request = try authorized("file", [.init(name: "session", value: session), .init(name: "path", value: path)])
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return data
    }

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
        let body = try? JSON.parse(data)
        throw MachineAPIError.status(status, body?["message"]?.string ?? body?["error"]?.string)
    }
}
