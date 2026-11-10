import XCTest
@testable import PiOSCore

@MainActor
final class RecordingSink: TerminalSink {
    var screen = ""
    var resets = 0
    var exited: Int?
    var failure: String?
    func reset() { resets += 1; screen = "" }
    func output(_ data: String) { screen += data }
    func exit(code: Int, signal: Int?) { exited = code }
    func failed(_ message: String) { failure = message }
}

@MainActor
final class TerminalTests: XCTestCase {
    func connected() async -> (PiosClient, TransportPool) {
        let pool = TransportPool()
        var counter = 0
        let client = PiosClient(
            createTransport: pool.factory, storage: MemoryStorage(), scheduler: FakeScheduler(), clientVersion: "test",
            generateId: { counter += 1; return "id\(counter)" }
        )
        client.start(Credentials(url: URL(string: "ws://x/ws")!, deviceToken: "t"))
        await settle()
        pool.last.acceptHello()
        return (client, pool)
    }

    func attach(_ pool: TransportPool, instance: String = "i1", offset: Int = 0, reset: Bool = false) {
        let open = pool.last.sent("terminal_open").last!
        pool.last.emit([
            "type": "terminal_attached", "commandId": open["commandId"]!, "terminalId": "s",
            "instance": .string(instance), "offset": .number(Double(offset)), "reset": .bool(reset),
        ])
    }

    func output(_ pool: TransportPool, offset: Int, _ data: String) {
        pool.last.emit(["type": "terminal_output", "terminalId": "s", "offset": .number(Double(offset)), "data": .string(data)])
    }

    func testOutputIsPlacedByOffsetAndDuplicatesAreDropped() async {
        let (client, pool) = await connected()
        let sink = RecordingSink()
        _ = client.terminals.open("s", cwd: "/p", size: TerminalSize(cols: 80, rows: 24), sink: sink)
        let open = pool.last.sent("terminal_open").last!
        XCTAssertEqual(open["cols"], 80)
        XCTAssertNil(open["since"])
        output(pool, offset: 0, "ignored before attach")
        attach(pool)
        output(pool, offset: 0, "ab")
        output(pool, offset: 1, "bcd")
        output(pool, offset: 0, "abcd")
        XCTAssertEqual(sink.screen, "abcd")
    }

    func testOffsetsCountUtf16UnitsLikeTheDaemon() async {
        let (client, pool) = await connected()
        let sink = RecordingSink()
        _ = client.terminals.open("s", cwd: "/p", size: TerminalSize(cols: 80, rows: 24), sink: sink)
        attach(pool)
        // One emoji is two UTF-16 units in JavaScript.
        output(pool, offset: 0, "\u{1F600}x")
        output(pool, offset: 2, "xy")
        XCTAssertEqual(sink.screen, "\u{1F600}xy")
    }

    func testGapReopensFromCursorAndReconnectResumes() async {
        let (client, pool) = await connected()
        let sink = RecordingSink()
        _ = client.terminals.open("s", cwd: "/p", size: TerminalSize(cols: 80, rows: 24), sink: sink)
        attach(pool)
        output(pool, offset: 0, "abc")
        output(pool, offset: 10, "late")
        let reopen = pool.last.sent("terminal_open").last!
        XCTAssertEqual(reopen["since"]?["offset"], 3)
        XCTAssertEqual(reopen["since"]?["instance"], "i1")
        XCTAssertEqual(sink.screen, "abc")

        pool.last.drop()
        client.supervisor.wake("test")
        await settle()
        pool.last.acceptHello()
        XCTAssertEqual(pool.last.sent("terminal_open").last?["since"]?["offset"], 3)
    }

    func testResetClearsAndRefusedOpenIsReported() async {
        let (client, pool) = await connected()
        let sink = RecordingSink()
        let handle = client.terminals.open("s", cwd: "/p", size: TerminalSize(cols: 80, rows: 24), sink: sink)
        attach(pool, instance: "i2", offset: 0, reset: true)
        XCTAssertEqual(sink.resets, 1)

        handle.restart()
        let restart = pool.last.sent("terminal_open").last!
        XCTAssertEqual(restart["restart"], true)
        XCTAssertNil(restart["since"])
        pool.last.emit(["type": "error", "commandId": restart["commandId"]!, "code": "bad_request", "message": "too many shells"])
        XCTAssertEqual(sink.failure, "too many shells")
    }

    func testInputIsNeverQueuedAndDetachStopsTheStream() async {
        let (client, pool) = await connected()
        let sink = RecordingSink()
        let handle = client.terminals.open("s", cwd: "/p", size: TerminalSize(cols: 80, rows: 24), sink: sink)
        attach(pool)
        XCTAssertTrue(handle.write("ls\r"))
        XCTAssertEqual(pool.last.sent("terminal_input").last?["data"], "ls\r")
        handle.resize(TerminalSize(cols: 40, rows: 20))
        handle.resize(TerminalSize(cols: 40, rows: 20))
        XCTAssertEqual(pool.last.sent("terminal_resize").count, 1)
        handle.detach()
        XCTAssertEqual(pool.last.sent("terminal_detach").count, 1)
        XCTAssertFalse(handle.write("x"))
        output(pool, offset: 0, "after")
        XCTAssertEqual(sink.screen, "")

        let other = client.terminals.open("t", cwd: "/p", size: TerminalSize(cols: 80, rows: 24), sink: sink)
        pool.last.drop()
        XCTAssertFalse(other.write("lost"), "offline keys are dropped, not queued")
    }
}

final class GitHelperTests: XCTestCase {
    func status(_ json: String) throws -> GitStatus {
        try JSONDecoder().decode(GitStatus.self, from: Data(json.utf8))
    }

    let sample = """
    {"root":"/r","prefix":"","branch":"main","head":"abc","upstream":{"name":"origin/main","ahead":2,"behind":1},
     "staged":1,"unstaged":2,"untracked":1,"conflicted":0,
     "files":[{"path":"a.ts","index":"M","work":"."},{"path":"b.ts","index":".","work":"D"},{"path":"n.md","index":".","work":".","untracked":true}],
     "truncated":false,"operation":null,"stashes":0,"remotes":["origin"],"defaultRemote":"origin"}
    """

    func testStatusDecodesAndSummarises() throws {
        let value = try status(sample)
        XCTAssertEqual(value.chip.counts, "\u{2193}1 \u{2191}2 \u{00B1}4")
        XCTAssertNil(value.chip.operation)
        XCTAssertEqual(value.summary, "1 staged \u{00B7} 2 changed \u{00B7} 1 untracked")
        XCTAssertEqual(value.files.map(\.mark.mark), ["M", "D", "?"])
        XCTAssertEqual(value.files.map(\.isStaged), [true, false, false])
    }

    func testNotARepositoryIsNullStatus() throws {
        struct Body: Decodable { var status: GitStatus? }
        XCTAssertNil(try JSONDecoder().decode(Body.self, from: Data(#"{"status":null}"#.utf8)).status)
    }

    func testActionsEncodeAsTheDaemonParsesThem() {
        XCTAssertEqual(GitAction.stage(["a"]).json, ["type": "stage", "paths": ["a"]])
        XCTAssertEqual(GitAction.push(force: false, setUpstream: true).json, ["type": "push", "setUpstream": true])
        XCTAssertEqual(GitAction.checkout(branch: "x", create: true, from: "origin/x").json,
                       ["type": "checkout", "branch": "x", "create": true, "from": "origin/x"])
        XCTAssertEqual(GitAction.initialize.json, ["type": "init"])
        XCTAssertNil(GitAction.stage(["a"]).confirmation)
        XCTAssertNotNil(GitAction.discard(["a"]).confirmation)
        XCTAssertEqual(GitAction.recovery(for: "Updates were rejected (non-fast-forward)")?.action, .pull(rebase: true))
    }

    func testPatchLinesTrimSharedIndent() {
        let patch = """
        diff --git a/x b/x
        index 1..2 100644
        --- a/x
        +++ b/x
        @@ -1,2 +1,2 @@
                 keep
        -        old
        +        new

        """
        let lines = patchLines(patch)
        XCTAssertEqual(lines.map(\.kind), [.meta, .meta, .meta, .same, .remove, .add])
        XCTAssertEqual(lines.suffix(3).map(\.text), [" keep", "-old", "+new"])
    }

    func testStashTitle() {
        let stash = GitStash(ref: "stash@{0}", message: "On main: wip parser", at: 0, branch: "main")
        XCTAssertEqual(stash.title, "wip parser")
    }
}
