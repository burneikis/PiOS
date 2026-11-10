import Foundation
@testable import PiOSCore

/// A socket the test drives by hand, to script failures that are hard to
/// produce on purpose: a drop mid-stream, an auth rejection.
@MainActor
final class FakeTransport: Transport {
    var sent: [JSON] = []
    var closed = false
    var onMessage: ((String) -> Void)?
    var onClose: ((Int, String) -> Void)?

    func send(_ text: String) { sent.append(try! JSON.parse(text)) }
    func close() { closed = true }

    func emit(_ frame: JSON) {
        var fields = frame.object ?? [:]
        fields["v"] = .number(Double(wireVersion))
        onMessage?(JSON.object(fields).encodedString())
    }

    func drop(code: Int = 1006, reason: String = "connection lost") {
        closed = true
        onClose?(code, reason)
    }

    func sent(_ type: String) -> [JSON] { sent.filter { $0["type"]?.string == type } }

    func acceptHello(_ sessions: [JSON] = []) {
        emit(["type": "welcome", "serverVersion": "test", "piVersion": "test", "sessions": .array(sessions)])
    }
}

/// Time that only moves when the test says so.
@MainActor
final class FakeScheduler: Scheduler {
    private(set) var time: Double = 1_000_000
    private var timers: [(handle: Int, at: Double, action: @MainActor () -> Void)] = []
    private var counter = 0

    func now() -> Double { time }

    func after(_ ms: Double, _ action: @escaping @MainActor () -> Void) -> TimerHandle {
        counter += 1
        timers.append((counter, time + ms, action))
        return counter
    }

    func cancel(_ handle: TimerHandle) { timers.removeAll { $0.handle == handle } }

    var pending: [Double] { timers.map { $0.at - time } }

    func advance(_ ms: Double) {
        let target = time + ms
        while let next = timers.filter({ $0.at <= target }).min(by: { $0.at < $1.at }) {
            timers.removeAll { $0.handle == next.handle }
            time = next.at
            next.action()
        }
        time = target
    }
}

/// Hands out fake transports and remembers them, newest last.
@MainActor
final class TransportPool {
    var made: [FakeTransport] = []
    var failNext = false

    var factory: TransportFactory {
        { [unowned self] _ in
            if self.failNext {
                self.failNext = false
                throw URLError(.cannotConnectToHost)
            }
            let transport = FakeTransport()
            self.made.append(transport)
            return transport
        }
    }

    var last: FakeTransport { made.last! }
}

/// Lets the transport-creation task run.
@MainActor
func settle() async {
    for _ in 0 ..< 10 { await Task.yield() }
}

func summary(_ id: String, status: String = "idle", leafId: String? = nil, cwd: String = "/home/u/proj") -> JSON {
    .compact([
        "sessionId": .string(id), "cwd": .string(cwd), "status": .string(status), "updatedAt": 1,
        "leafId": leafId.map(JSON.string) ?? .null,
    ])
}

func userEntry(_ id: String, _ text: String, ts: Double) -> JSON {
    ["id": .string(id), "type": "message", "message": ["role": "user", "content": .string(text), "timestamp": .number(ts)]]
}

func assistantEntry(_ id: String, _ text: String, ts: Double) -> JSON {
    [
        "id": .string(id), "type": "message",
        "message": ["role": "assistant", "content": [["type": "text", "text": .string(text)]], "timestamp": .number(ts), "stopReason": "stop"],
    ]
}

let traceDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("../../../../../spikes/traces").standardized
