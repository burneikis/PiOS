import XCTest
@testable import PiOSCore

/// Replays the recorded pi traces shared with the TypeScript packages, so the
/// Swift assembler is held to the same fixtures as the web client.
final class FixtureReplayTests: XCTestCase {
    func traces() throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: traceDir.path).filter { $0.hasSuffix(".jsonl") }
        XCTAssertFalse(names.isEmpty, "no fixtures in \(traceDir.path)")
        return names.sorted().map { traceDir.appendingPathComponent($0) }
    }

    /// LF-only split: JSON strings may legally hold U+2028/U+2029.
    func records(_ url: URL) throws -> [JSON] {
        let data = try Data(contentsOf: url)
        return try data.split(separator: UInt8(ascii: "\n")).map { try JSON.parse(Data($0)) }
    }

    func testEveryRecordParsesAndTranscriptMatchesMessageEnds() throws {
        for url in try traces() {
            let records = try records(url)
            let events = records.filter { $0["type"]?.string != "response" && $0["type"]?.string != "extension_ui_request" }
            let assembler = TranscriptAssembler()
            var expected: [AgentMessage] = []
            for record in events {
                let event = try XCTUnwrap(AgentEvent(json: record), "\(url.lastPathComponent): \(record["type"]?.string ?? "?")")
                if case let .messageEnd(message) = event { expected.append(message) }
                assembler.apply(event)
            }
            let snapshot = assembler.snapshot()
            XCTAssertEqual(snapshot.messages, expected, url.lastPathComponent)
            // A trace cut mid-stream (the crash one) legitimately ends partial.
            if events.contains(where: { $0["type"]?.string == "agent_settled" }) {
                XCTAssertNil(snapshot.streaming, "\(url.lastPathComponent) left a partial behind")
                XCTAssertFalse(snapshot.running, url.lastPathComponent)
            }
        }
    }

    /// Streamed deltas must reproduce what `message_end` says the text was.
    func testStreamingDeltasMatchFinalText() throws {
        let events = try records(traceDir.appendingPathComponent("streaming.jsonl")).compactMap(AgentEvent.init(json:))
        let assembler = TranscriptAssembler()
        var lastPartial: PartialMessage?
        for event in events {
            if case .messageEnd = event { lastPartial = assembler.snapshot().streaming ?? lastPartial }
            assembler.apply(event)
        }
        let final = try XCTUnwrap(assembler.snapshot().messages.last { $0.role == .assistant })
        let partialText = try XCTUnwrap(lastPartial).content.compactMap { part -> String? in
            if case let .text(text, _) = part { return text }
            return nil
        }.joined()
        XCTAssertEqual(partialText, final.text)
    }

    func testEntriesFixtureDecodes() throws {
        let json = try JSON.parse(Data(contentsOf: traceDir.appendingPathComponent("entries-full.json")))
        let entries = (json["entries"] ?? json["data"]?["entries"])?.array ?? []
        XCTAssertFalse(entries.isEmpty)
        XCTAssertEqual(entries.compactMap(SessionEntry.init(json:)).count, entries.count)
    }
}

final class WireTests: XCTestCase {
    func testPromptFrameCarriesEnvelopeAndOmitsAbsentFields() throws {
        let frame = ClientCommand.prompt(
            sessionId: "s", messageId: "m", text: "hi", images: [], streamingBehavior: nil, create: nil
        ).frame(commandId: "c")
        XCTAssertEqual(frame["v"], 2)
        XCTAssertEqual(frame["commandId"], "c")
        XCTAssertEqual(frame["type"], "prompt")
        XCTAssertNil(frame["streamingBehavior"])
        XCTAssertNil(frame["create"])
        XCTAssertTrue(frame.encodedString().contains("\"v\":2"), "integers must not go out as 2.0")
    }

    func testVersionMismatchIsRefused() {
        XCTAssertThrowsError(try ServerFrame(text: #"{"v":3,"type":"welcome"}"#)) { error in
            XCTAssertEqual(error as? ServerFrame.ParseError, .versionMismatch(3))
        }
    }

    func testUnknownFrameTypeIsKeptNotThrown() throws {
        let frame = try ServerFrame(text: #"{"v":2,"type":"something_newer","x":1}"#)
        guard case .unhandled("something_newer") = frame.body else { return XCTFail("\(frame.body)") }
    }

    func testLineSeparatorsSurviveParsing() throws {
        let text = "{\"v\":2,\"type\":\"exported\",\"sessionId\":\"s\",\"path\":\"a\u{2028}b\u{2029}c\"}"
        let frame = try ServerFrame(text: text)
        guard case let .exported(_, path) = frame.body else { return XCTFail() }
        XCTAssertEqual(path, "a\u{2028}b\u{2029}c")
    }

    func testPreviewCollapsesInjectedBlocks() {
        XCTAssertEqual(previewText("<skill name=\"git\">long body</skill>\n do  it"), "<skill:git> do it")
        XCTAssertEqual(previewText("look /tmp/paste-1.png please"), "look <image> please")
    }

    func testReadableError() {
        XCTAssertEqual(readableError(#"429: {"error":{"message":"Slow down"}}"#), "429: Slow down")
        XCTAssertEqual(readableError("plain"), "plain")
    }

    func testPresentationReducer() throws {
        var state = SessionPresentation()
        let set = try XCTUnwrap(ExtensionUiRequest(json: ["id": "1", "method": "setStatus", "statusKey": "k", "statusText": "\u{1B}[31mred\u{1B}[0m"]))
        state = applyPresentation(state, set)
        XCTAssertEqual(state.status.map(\.text), ["red"])
        let clear = try XCTUnwrap(ExtensionUiRequest(json: ["id": "2", "method": "setStatus", "statusKey": "k"]))
        state = applyPresentation(state, clear)
        XCTAssertTrue(state.status.isEmpty)
    }

    func testDiff() {
        let lines = diffLines("a\nb\nc", "a\nx\nc")
        XCTAssertEqual(lines.map(\.kind), [.same, .remove, .add, .same])
    }

    func testShortenPreview() {
        XCTAssertEqual(shortenPreview("cd /home/u/p && ls", cwd: "/home/u/p"), "ls")
        XCTAssertEqual(shortenPreview("/home/u/p/src/a.ts", cwd: "/home/u/p"), "src/a.ts")
        XCTAssertEqual(shortenPreview("/home/u/other", cwd: "/home/u/p"), "~/other")
    }
}
