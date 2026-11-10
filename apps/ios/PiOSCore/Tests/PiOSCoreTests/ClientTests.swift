import XCTest
@testable import PiOSCore

@MainActor
final class SupervisorTests: XCTestCase {
    let credentials = Credentials(url: URL(string: "wss://relay.example/ws")!, deviceToken: "tok")

    func make() -> (ConnectionSupervisor, TransportPool, FakeScheduler) {
        let pool = TransportPool()
        let scheduler = FakeScheduler()
        let supervisor = ConnectionSupervisor(createTransport: pool.factory, scheduler: scheduler, clientVersion: "test")
        return (supervisor, pool, scheduler)
    }

    func testConnectedOnlyAfterWelcome() async {
        let (supervisor, pool, _) = make()
        supervisor.setCredentials(credentials)
        supervisor.start()
        await settle()
        XCTAssertEqual(supervisor.state.transport, .connecting)
        XCTAssertEqual(pool.last.sent("hello").first?["deviceToken"], "tok")
        pool.last.acceptHello()
        XCTAssertEqual(supervisor.state.transport, .connected)
    }

    func testBackoffIsCappedAndResetsAfterStableConnection() async {
        let (supervisor, pool, scheduler) = make()
        supervisor.setCredentials(credentials)
        supervisor.start()
        var delays: [Double] = []
        for _ in 0 ..< 7 {
            await settle()
            pool.last.drop()
            delays.append(scheduler.pending.max() ?? -1)
            scheduler.advance(delays.last!)
        }
        XCTAssertEqual(delays, [500, 1000, 2000, 4000, 8000, 16000, 16000])

        await settle()
        pool.last.acceptHello()
        scheduler.advance(ConnectionSupervisor.stableAfterMs)
        pool.last.drop()
        XCTAssertEqual(scheduler.pending, [500])
    }

    func testAuthCloseBlocksUntilCredentialsChange() async {
        let (supervisor, pool, scheduler) = make()
        supervisor.setCredentials(credentials)
        supervisor.start()
        await settle()
        pool.last.drop(code: 4401, reason: "unauthorized")
        XCTAssertEqual(supervisor.state.transport, .blocked)
        XCTAssertTrue(scheduler.pending.isEmpty, "a block must not arm a retry")

        supervisor.setCredentials(Credentials(url: credentials.url, deviceToken: "new"))
        await settle()
        XCTAssertEqual(pool.made.count, 2)
    }

    func testOfflineArmsNothingAndOnlineReconnectsAtOnce() async {
        let (supervisor, pool, scheduler) = make()
        supervisor.setCredentials(credentials)
        supervisor.start()
        await settle()
        supervisor.setOnline(false)
        XCTAssertEqual(supervisor.state.transport, .offline)
        XCTAssertTrue(pool.last.closed)
        XCTAssertTrue(scheduler.pending.isEmpty)
        supervisor.setOnline(true)
        await settle()
        XCTAssertEqual(pool.made.count, 2)
    }

    func testHostOfflineCloseIsTransient() async {
        let (supervisor, pool, _) = make()
        supervisor.setCredentials(credentials)
        supervisor.start()
        await settle()
        pool.last.acceptHello()
        pool.last.drop(code: hostOfflineCloseCode, reason: "host offline")
        XCTAssertEqual(supervisor.state.transport, .waiting)
        XCTAssertTrue(supervisor.state.hostOffline)
    }
}

@MainActor
final class ClientTests: XCTestCase {
    func make(storage: MemoryStorage = MemoryStorage()) async -> (PiosClient, TransportPool, FakeScheduler) {
        let pool = TransportPool()
        let scheduler = FakeScheduler()
        var counter = 0
        let client = PiosClient(
            createTransport: pool.factory, storage: storage, scheduler: scheduler, clientVersion: "test",
            generateId: { counter += 1; return "id\(counter)" }
        )
        client.start(Credentials(url: URL(string: "ws://x/ws")!, deviceToken: "t"))
        await settle()
        return (client, pool, scheduler)
    }

    func testPromptQueuedOfflineDrainsOnConnectAndClearsOnAck() async {
        let (client, pool, _) = await make()
        let entry = client.prompt(sessionId: "s", text: "hello")
        XCTAssertEqual(client.outbox.entries.count, 1)
        XCTAssertTrue(pool.last.sent("prompt").isEmpty, "nothing reaches a socket before welcome")

        pool.last.acceptHello()
        let sent = pool.last.sent("prompt")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["commandId"]?.string, entry.commandId)
        XCTAssertEqual(sent.first?["messageId"]?.string, entry.messageId)

        pool.last.emit(["type": "ack", "commandId": .string(entry.commandId)])
        XCTAssertTrue(client.outbox.entries.isEmpty)
    }

    func testOutboxSurvivesRestartAndRedeliversWithSameCommandId() async {
        let storage = MemoryStorage()
        let (first, pool, _) = await make(storage: storage)
        pool.last.acceptHello()
        let entry = first.prompt(sessionId: "s", text: "hello")
        XCTAssertEqual(first.outbox.entries.first?.status, .sending)

        let (second, pool2, _) = await make(storage: storage)
        XCTAssertEqual(second.outbox.entries.first?.status, .queued)
        pool2.last.acceptHello()
        XCTAssertEqual(pool2.last.sent("prompt").first?["commandId"]?.string, entry.commandId)
    }

    func testRejectedPromptIsKeptAsFailed() async {
        let (client, pool, _) = await make()
        pool.last.acceptHello()
        let entry = client.prompt(sessionId: "s", text: "x")
        pool.last.emit(["type": "error", "commandId": .string(entry.commandId), "code": "bad_request", "message": "need streamingBehavior"])
        XCTAssertEqual(client.outbox.entries.first?.status, .failed)
        XCTAssertEqual(client.outbox.entries.first?.lastError, "need streamingBehavior")
    }

    func testWatchResyncsFromCursorAndDivergedLeafRefetches() async {
        let (client, pool, _) = await make()
        pool.last.acceptHello([summary("s", leafId: "e2")])
        client.watch("s")
        let first = pool.last.sent("get_entries").last!
        XCTAssertNil(first["since"], "first load takes the tail")
        XCTAssertEqual(first["limit"], 200)
        pool.last.emit([
            "type": "entries", "sessionId": "s", "commandId": first["commandId"]!,
            "entries": [userEntry("e1", "hi", ts: 1), assistantEntry("e2", "yo", ts: 2)], "leafId": "e2", "total": 2,
        ])
        XCTAssertEqual(client.sessions.cursor("s"), "e2")
        XCTAssertEqual(client.view("s").items.count, 2)

        // Reconnect with the same leaf: a delta from the cursor.
        pool.last.drop()
        client.supervisor.wake("test")
        await settle()
        pool.last.acceptHello([summary("s", leafId: "e2")])
        XCTAssertEqual(pool.last.sent("get_entries").last?["since"], "e2")

        // Reconnect with a leaf never seen: the cache is dropped.
        pool.last.drop()
        client.supervisor.wake("test")
        await settle()
        pool.last.acceptHello([summary("s", leafId: "other")])
        XCTAssertNil(pool.last.sent("get_entries").last?["since"])
        XCTAssertTrue(client.sessions.cache("s").entries.isEmpty)
    }

    func testLiveEventsAndPersistedEntriesCollapse() async {
        let (client, pool, _) = await make()
        pool.last.acceptHello()
        client.watch("s")
        let user: JSON = ["role": "user", "content": "hi", "timestamp": 10]
        pool.last.emit(["type": "agent_event", "sessionId": "s", "seq": 1, "event": ["type": "agent_start"]])
        pool.last.emit(["type": "agent_event", "sessionId": "s", "seq": 2, "event": ["type": "message_end", "message": user]])
        pool.last.emit(["type": "agent_event", "sessionId": "s", "seq": 3, "event": [
            "type": "message_update", "assistantMessageEvent": ["type": "text_delta", "contentIndex": 0, "delta": "Hel"],
        ]])
        var view = client.view("s")
        XCTAssertTrue(view.running)
        guard case .streaming = view.items.last else { return XCTFail("expected a streaming bubble") }

        pool.last.emit(["type": "entries", "sessionId": "s", "entries": [userEntry("e1", "hi", ts: 10)], "leafId": "e1"])
        view = client.view("s")
        XCTAssertEqual(view.items.filter { if case .message = $0 { return true } else { return false } }.count, 1)
    }

    func testIdenticalPersistedRepliesAreNotCollapsed() async {
        let (client, pool, _) = await make()
        pool.last.acceptHello()
        let reply: JSON = ["role": "assistant", "content": [["type": "text", "text": "same"]]]
        pool.last.emit(["type": "entries", "sessionId": "s", "leafId": "b", "entries": [
            ["id": "a", "type": "message", "message": reply],
            ["id": "b", "type": "message", "message": reply],
        ]])
        XCTAssertEqual(client.view("s").items.count, 2)
        // The live copy of the same reply still collapses onto them.
        pool.last.emit(["type": "agent_event", "sessionId": "s", "seq": 1, "event": ["type": "message_end", "message": reply]])
        XCTAssertEqual(client.view("s").items.count, 2)
    }

    func testDialogsOpenAndCloseAcrossDevices() async {
        let (client, pool, _) = await make()
        pool.last.acceptHello()
        pool.last.emit(["type": "extension_ui_request", "sessionId": "s", "request": [
            "type": "extension_ui_request", "id": "r1", "method": "confirm", "title": "Run?",
        ]])
        pool.last.emit(["type": "extension_ui_request", "sessionId": "s", "request": [
            "type": "extension_ui_request", "id": "r1", "method": "confirm", "title": "Run?",
        ]])
        XCTAssertEqual(client.view("s").dialogs.count, 1, "a redelivered dialog collapses")
        pool.last.emit(["type": "extension_ui_closed", "sessionId": "s", "requestId": "r1"])
        XCTAssertTrue(client.view("s").dialogs.isEmpty)
    }

    func testFailedResyncIsSyncErrorNotReconnect() async {
        let (client, pool, _) = await make()
        pool.last.acceptHello()
        client.watch("s")
        let request = pool.last.sent("get_entries").last!
        pool.last.emit(["type": "error", "commandId": request["commandId"]!, "code": "internal", "message": "boom"])
        XCTAssertEqual(client.supervisor.state.sync, .error)
        XCTAssertEqual(client.supervisor.state.transport, .connected)
    }

    func testSessionListPagesMerge() async {
        let (client, pool, _) = await make()
        pool.last.acceptHello()
        pool.last.emit(["type": "sessions", "sessions": [summary("a"), summary("b")], "offset": 0, "total": 3, "hasMore": true])
        pool.last.emit(["type": "sessions", "sessions": [summary("c")], "offset": 2, "total": 3, "hasMore": false])
        XCTAssertEqual(client.supervisor.state.sessions.map(\.sessionId), ["a", "b", "c"])
        pool.last.emit(["type": "sessions", "sessions": [summary("z")], "offset": 0, "total": 1])
        XCTAssertEqual(client.supervisor.state.sessions.map(\.sessionId), ["z"], "page 0 replaces")
    }

    func testAppStatePolicy() async {
        let (client, pool, scheduler) = await make()
        pool.last.acceptHello()
        client.appState.set(.background)
        scheduler.advance(5_000)
        client.appState.set(.active)
        await settle()
        XCTAssertEqual(pool.made.count, 1, "a short background only probes a healthy socket")

        client.appState.set(.background)
        scheduler.advance(11_000)
        client.appState.set(.active)
        await settle()
        XCTAssertEqual(pool.made.count, 2, "a long background replaces the socket")
    }
}
