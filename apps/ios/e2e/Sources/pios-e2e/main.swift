import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PiOSCore

/// Minimal transport for the harness. swift-corelibs on Linux has no
/// open callback and no ping, so a short pause stands in for "open". It also
/// drops frames past libcurl's 16 KB buffer, so run against a fresh sandbox;
/// the iOS transport uses Apple's URLSession and has neither limit.
@MainActor
final class LinuxTransport: Transport {
    var onMessage: ((String) -> Void)?
    var onClose: ((Int, String) -> Void)?
    let task: URLSessionWebSocketTask

    init(_ url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024
    }

    func open() async throws {
        task.resume()
        try await Task.sleep(nanoseconds: 300_000_000)
        receive()
    }

    func receive() {
        task.receive { result in
            Task { @MainActor in
                switch result {
                case let .success(.string(text)): self.onMessage?(text); self.receive()
                case let .success(.data(data)): self.onMessage?(String(decoding: data, as: UTF8.self)); self.receive()
                case .success: self.receive()
                case let .failure(error): self.onClose?(1006, "\(error)")
                }
            }
        }
    }

    func send(_ text: String) { task.send(.string(text)) { _ in } }
    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

@MainActor
func wait(_ what: String, timeout: Double = 15, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { print("FAIL: timed out waiting for \(what)"); exit(1) }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    print("ok: \(what)")
}

@MainActor
func run() async {
    guard CommandLine.arguments.count >= 2 else {
        print("usage: pios-e2e <device-token> [ws-url]   (token from `pnpm sandbox --no-web`)")
        exit(2)
    }
    let token = CommandLine.arguments[1]
    let socket = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "ws://127.0.0.1:4311/ws"
    let client = PiosClient(
        createTransport: { url in let t = LinuxTransport(url); try await t.open(); return t },
        storage: MemoryStorage(), clientVersion: "e2e"
    )
    client.start(Credentials(url: URL(string: socket)!, deviceToken: token))
    await wait("connected") { client.supervisor.state.transport == .connected }
    await wait("session list") { !client.supervisor.state.sessions.isEmpty }
    for s in client.supervisor.state.sessions { print("   session", s.sessionId, s.title, s.status.rawValue) }

    let session = client.supervisor.state.sessions.first { $0.name == "api" } ?? client.supervisor.state.sessions[0]
    let id = session.sessionId
    client.watch(id)
    await wait("transcript synced") { client.supervisor.state.sync == .synced && !client.view(id).items.isEmpty }
    let before = client.view(id)
    print("   items:", before.items.count, "tools:", before.tools.count, "hasOlder:", before.hasOlder)

    // Prompt through the outbox and wait for the turn to settle.
    client.prompt(sessionId: id, text: "hello from swift")
    await wait("prompt acked") { client.outbox.entries.isEmpty }
    func replied() -> Bool {
        let roles = client.view(id).items.compactMap { item -> AgentMessage? in
            if case let .message(_, m, _, _) = item { return m }
            return nil
        }
        guard let index = roles.lastIndex(where: { $0.text.contains("hello from swift") && $0.role == .user }) else { return false }
        return roles[(index + 1)...].contains { $0.role == .assistant }
    }
    await wait("assistant replied") { replied() }
    await wait("agent settled") { !client.view(id).running }
    try? await Task.sleep(nanoseconds: 500_000_000)
    let after = client.view(id)
    let texts = after.items.compactMap { item -> String? in
        if case let .message(_, m, _, _) = item { return "\(m.role.rawValue): \(m.text.prefix(60))" }
        return nil
    }
    print("   last messages:", texts.suffix(2))
    if !(texts.last?.hasPrefix("assistant") ?? false) { print("FAIL: no assistant reply"); exit(1) }
    if !texts.contains(where: { $0.contains("hello from swift") }) { print("FAIL: prompt missing"); exit(1) }
    let dupes = Dictionary(grouping: after.items.map(\.id), by: { $0 }).filter { $0.value.count > 1 }
    if !dupes.isEmpty { print("FAIL: duplicate item ids", dupes.keys); exit(1) }
    print("ok: reply rendered once, no duplicate items")

    // Extension dialog round trip.
    client.prompt(sessionId: id, text: "ASK_DIALOG please")
    await wait("dialog opened") { !client.view(id).dialogs.isEmpty }
    let dialog = client.view(id).dialogs[0]
    print("   dialog:", dialog.method.rawValue, dialog.title ?? "", dialog.options)
    switch dialog.method {
    case .select: client.answerDialog(id, requestId: dialog.id, value: dialog.options.first)
    case .confirm: client.answerDialog(id, requestId: dialog.id, confirmed: true)
    default: client.answerDialog(id, requestId: dialog.id, value: "yes")
    }
    await wait("dialog closed") { client.view(id).dialogs.isEmpty }
    await wait("settled after dialog") { !client.view(id).running }

    // One-shot shell.
    _ = client.runBash(id, "echo swift-bash-ok")
    // The live run is replaced by pi's persisted entry as soon as it lands.
    await wait("bash finished") {
        let view = client.view(id)
        if let run = view.bash { return !run.running }
        return view.items.contains { if case let .message(_, m, _, _) = $0 { return m.role == .bashExecution && m.command == "echo swift-bash-ok" }; return false }
    }
    print("   bash:", client.view(id).bash?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", "exit", client.view(id).bash?.result?.exitCode ?? -1)

    // Draft: the first prompt creates the session under the client's id.
    let draftId = client.newSessionId()
    client.prompt(sessionId: draftId, text: "first prompt of a draft", create: SessionCreate(cwd: session.cwd, trustProject: true))
    await wait("draft acked") { client.outbox.entries.isEmpty }
    client.refreshSessions()
    await wait("draft listed as a session") { client.supervisor.state.sessions.contains { $0.sessionId == draftId } }
    client.watch(draftId)
    await wait("draft transcript") { client.view(draftId).items.contains { if case .message = $0 { return true }; return false } }

    // Models and stats.
    _ = client.listModels(id)
    _ = client.requestStats(id)
    await wait("models") { !client.models(id).models.isEmpty }
    await wait("stats") { client.stats(id) != nil }
    print("PASS")
    exit(0)
}

Task { @MainActor in await run() }
dispatchMain()
