import Foundation

/// Exponential ladder, capped and infinite. Capped at 16s so a phone back
/// from an hour in a tunnel reconnects in seconds; never gives up, because a
/// client that stopped trying is indistinguishable from a broken one.
public struct Backoff: Sendable {
    public static let capMs: Double = 16_000

    public private(set) var attempts = 0
    let baseMs: Double
    let capMs: Double
    let factor: Double

    public init(baseMs: Double = 500, capMs: Double = Backoff.capMs, factor: Double = 2) {
        self.baseMs = baseMs
        self.capMs = capMs
        self.factor = factor
    }

    /// Delay for the next attempt, and advances the ladder.
    public mutating func next() -> Double {
        let raw = baseMs * pow(factor, Double(attempts))
        attempts += 1
        return min(raw, capMs)
    }

    public mutating func reset() {
        attempts = 0
    }
}

public typealias TimerHandle = Int

/// Time, injected so tests drive the ladders without waiting.
@MainActor
public protocol Scheduler: AnyObject {
    func now() -> Double
    func after(_ ms: Double, _ action: @escaping @MainActor () -> Void) -> TimerHandle
    func cancel(_ handle: TimerHandle)
}

@MainActor
public final class SystemScheduler: Scheduler {
    private var tasks: [TimerHandle: Task<Void, Never>] = [:]
    private var counter = 0

    public init() {}

    public func now() -> Double { nowMs() }

    public func after(_ ms: Double, _ action: @escaping @MainActor () -> Void) -> TimerHandle {
        counter += 1
        let handle = counter
        tasks[handle] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(ms, 0) * 1_000_000))
            guard !Task.isCancelled, let self, self.tasks.removeValue(forKey: handle) != nil else { return }
            action()
        }
        return handle
    }

    public func cancel(_ handle: TimerHandle) {
        tasks.removeValue(forKey: handle)?.cancel()
    }
}

/// Key-value persistence, so the core does not care whether it lands in
/// files, `UserDefaults`, or memory.
public protocol StorageAdapter: AnyObject {
    func read(_ key: String) -> Data?
    func write(_ key: String, _ data: Data)
    func remove(_ key: String)
}

public final class MemoryStorage: StorageAdapter {
    public private(set) var values: [String: Data] = [:]
    public init() {}
    public func read(_ key: String) -> Data? { values[key] }
    public func write(_ key: String, _ data: Data) { values[key] = data }
    public func remove(_ key: String) { values[key] = nil }
}

private struct Versioned<T: Codable>: Codable {
    var v: Int
    var data: T
}

private struct VersionOnly: Codable {
    var v: Int
}

/// Reads a persisted structure, migrating or discarding an old version. A
/// shape this build cannot read is dropped rather than crashing the launch.
public func readVersioned<T: Codable>(
    _ storage: StorageAdapter, _ key: String, version: Int, fallback: T,
    migrate: ((JSON, Int) -> T?)? = nil
) -> T {
    guard let data = storage.read(key) else { return fallback }
    let decoder = JSONDecoder()
    if let current = try? decoder.decode(Versioned<T>.self, from: data), current.v == version {
        return current.data
    }
    guard let migrate, let found = try? decoder.decode(VersionOnly.self, from: data),
          let json = try? JSON.parse(data), let payload = json["data"]
    else { return fallback }
    return migrate(payload, found.v) ?? fallback
}

public func writeVersioned<T: Codable>(_ storage: StorageAdapter, _ key: String, version: Int, _ value: T) {
    guard let data = try? JSONEncoder().encode(Versioned(v: version, data: value)) else { return }
    storage.write(key, data)
}

/// A set of callbacks with removal by token.
public final class Listeners<Value> {
    private var handlers: [Int: (Value) -> Void] = [:]
    private var counter = 0

    public init() {}

    @discardableResult
    public func add(_ handler: @escaping (Value) -> Void) -> Cancel {
        counter += 1
        let id = counter
        handlers[id] = handler
        return Cancel { [weak self] in self?.handlers[id] = nil }
    }

    public func emit(_ value: Value) {
        for key in handlers.keys.sorted() { handlers[key]?(value) }
    }
}

public final class Cancel {
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    public func callAsFunction() {
        action?()
        action = nil
    }
}

/// The socket, abstracted so the core stays platform-free. Only the
/// supervisor ever opens one.
@MainActor
public protocol Transport: AnyObject {
    func send(_ text: String)
    func close()
    var onMessage: ((String) -> Void)? { get set }
    var onClose: ((_ code: Int, _ reason: String) -> Void)? { get set }
}

public typealias TransportFactory = @MainActor (URL) async throws -> Transport

/// Thrown by a factory whose socket never opened, with the close code it
/// stands for: an HTTP 401 on the upgrade is a 4401, a relay 503 a 4503.
public struct TransportRefused: Error, Equatable {
    public var code: Int
    public var reason: String
    public init(code: Int, reason: String) {
        self.code = code
        self.reason = reason
    }
}

/// Close codes the daemon uses for "do not retry with these inputs".
public let authCloseCodes: Set<Int> = [4401, 4403]
/// The relay's "host offline": transient, backed off like a network drop.
public let hostOfflineCloseCode = 4503

public func defaultId() -> String {
    let millis = String(Int(nowMs()), radix: 36)
    let random = String(UInt64.random(in: 0 ..< UInt64(1) << 40), radix: 36)
    return "\(millis)-\(random)"
}
