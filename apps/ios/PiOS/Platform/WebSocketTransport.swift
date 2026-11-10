import Foundation
import PiOSCore

/// `URLSessionWebSocketTask` behind the core's `Transport`.
///
/// The factory resolves only once the socket is open, so the supervisor's
/// "open, then hello, then connected" order holds. Every failure after that
/// is reported as a close with a code, which is the one signal the
/// supervisor acts on.
@MainActor
final class WebSocketTransport: NSObject, Transport {
    var onMessage: ((String) -> Void)?
    var onClose: ((Int, String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var opened: CheckedContinuation<Void, Error>?
    private var finished = false

    static let factory: TransportFactory = { url in
        let transport = WebSocketTransport()
        try await transport.open(url)
        return transport
    }

    private func open(_ url: URL) async throws {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: url)
        // Transcript pages and inline images are far past the 1 MiB default.
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task
        try await withCheckedThrowingContinuation { continuation in
            opened = continuation
            task.resume()
        }
        receive()
    }

    func send(_ text: String) {
        task?.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.finish(code: 1006, reason: "send failed") }
        }
    }

    func close() {
        finished = true
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                switch result {
                case let .success(.string(text)):
                    self.onMessage?(text)
                    self.receive()
                case let .success(.data(data)):
                    self.onMessage?(String(decoding: data, as: UTF8.self))
                    self.receive()
                case .success:
                    self.receive()
                case .failure:
                    let code = self.task.map { $0.closeCode.rawValue } ?? 1006
                    let reason = self.task?.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    self.finish(code: code == 0 ? 1006 : code, reason: reason)
                }
            }
        }
    }

    private func finish(code: Int, reason: String) {
        if let opened {
            self.opened = nil
            opened.resume(throwing: TransportRefused(code: code, reason: reason))
            return
        }
        guard !finished else { return }
        finished = true
        session?.invalidateAndCancel()
        onClose?(code, reason)
    }
}

extension WebSocketTransport: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?
    ) {
        MainActor.assumeIsolated {
            opened?.resume()
            opened = nil
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        MainActor.assumeIsolated {
            finish(code: closeCode.rawValue, reason: reason.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            // A 401 on the upgrade is the daemon refusing the device, not the
            // network: report it as the auth close the supervisor blocks on.
            let status = (task.response as? HTTPURLResponse)?.statusCode
            let relayOffline = (task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-pios-relay") == "host-offline"
            let code = status == 401 || status == 403 ? 4401 : relayOffline ? hostOfflineCloseCode : 1006
            finish(code: code, reason: relayOffline ? "machine offline" : error?.localizedDescription ?? "closed")
        }
    }
}
