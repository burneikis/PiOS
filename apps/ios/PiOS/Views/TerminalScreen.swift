import PiOSCore
import SwiftTerm
import SwiftUI
import UIKit

/// The interactive shell in the session directory, on a daemon-owned PTY.
///
/// The shell outlives this screen, the socket and the app: leaving detaches,
/// and coming back replays what was missed. SwiftTerm's own key row (esc,
/// ctrl, tab, arrows) sits above the keyboard.
struct TerminalScreen: View {
    let terminalId: String
    let cwd: String
    @Environment(AppModel.self) private var model
    @AppStorage("pios.terminalFontSize") private var fontSize = 12.0
    @State private var session = TerminalSession()
    @State private var confirmClose = false

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 6) {
                if model.connection.transport != .connected {
                    StatusLine(text: "Not connected. Keys typed now are dropped, not queued.", tone: .warn)
                }
                if let failure = session.failure {
                    StatusLine(text: failure, tone: .error)
                }
                if let exit = session.exitText {
                    StatusLine(text: exit, tone: .muted) {
                        Button("Restart") { session.restart() }
                    }
                }
            }
            .padding(.horizontal, 12)
            TerminalHost(session: session, fontSize: fontSize)
                .padding(.horizontal, 4)
        }
        .background(Theme.bg)
        .navigationTitle(session.title ?? collapseHome(cwd))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    if let text = UIPasteboard.general.string { session.write(text) }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                Menu {
                    Button(role: .destructive) { confirmClose = true } label: { Label("Close the shell", systemImage: "xmark") }
                        .disabled(session.exitText != nil)
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .confirmationDialog("Close the shell?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close shell", role: .destructive) { session.kill() }
        } message: {
            Text("It ends for every device attached to it.")
        }
        .onAppear { session.attach(client: model.client, terminalId: terminalId, cwd: cwd) }
        .onDisappear { session.detach() }
    }
}

/// Glue between the core's channel and one SwiftTerm view.
@Observable
@MainActor
final class TerminalSession: TerminalSink {
    var exitText: String?
    var failure: String?
    var title: String?

    @ObservationIgnored weak var view: TerminalView?
    @ObservationIgnored private var handle: TerminalHandle?
    @ObservationIgnored private var pending: (client: PiosClient, terminalId: String, cwd: String)?
    /// Output that arrived before the view existed.
    @ObservationIgnored private var backlog = ""
    @ObservationIgnored private var size: TerminalSize?

    func attach(client: PiosClient, terminalId: String, cwd: String) {
        pending = (client, terminalId, cwd)
        openIfReady()
        // A view that lays out at exactly the default size reports no change;
        // open with that size rather than wait for a report that never comes.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if self.size == nil { self.sized(TerminalSize(cols: 80, rows: 25)) }
        }
    }

    func sized(_ next: TerminalSize) {
        size = next
        if let handle { handle.resize(next) } else { openIfReady() }
    }

    private func openIfReady() {
        guard handle == nil, let pending, let size else { return }
        handle = pending.client.terminals.open(pending.terminalId, cwd: pending.cwd, size: size, sink: self)
    }

    @discardableResult
    func write(_ data: String) -> Bool { handle?.write(data) ?? false }

    func restart() {
        exitText = nil
        failure = nil
        handle?.restart()
    }

    func detach() {
        handle?.detach()
        handle = nil
        pending = nil
    }

    func kill() {
        handle?.kill()
        handle = nil
    }

    func viewReady(_ view: TerminalView) {
        self.view = view
        if !backlog.isEmpty {
            view.feed(text: backlog)
            backlog = ""
        }
    }

    // MARK: TerminalSink

    func reset() {
        exitText = nil
        backlog = ""
        view?.feed(text: "\u{1B}c")
    }

    func output(_ data: String) {
        if let view { view.feed(text: data) } else { backlog += data }
    }

    func exit(code: Int, signal: Int?) {
        exitText = signal.map { "Shell ended by signal \($0)." } ?? "Shell exited with code \(code)."
    }

    func failed(_ message: String) {
        failure = message
    }
}

struct TerminalHost: UIViewRepresentable {
    let session: TerminalSession
    let fontSize: Double

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: fontSize, weight: .regular))
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = UIColor(Theme.bg)
        view.nativeForegroundColor = UIColor(Theme.text)
        view.caretColor = UIColor(Theme.accent)
        view.keyboardAppearance = .dark
        view.optionAsMetaKey = true
        session.viewReady(view)
        // Focus once laid out: the keyboard is why someone opened a shell.
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        context.coordinator.session = session
        if view.font.pointSize != fontSize {
            view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        var session: TerminalSession

        init(session: TerminalSession) { self.session = session }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            session.sized(TerminalSize(cols: min(newCols, 1000), rows: min(newRows, 1000)))
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.write(String(decoding: data, as: UTF8.self))
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            session.title = title.isEmpty ? nil : title
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
        }

        func clipboardRead(source: TerminalView) -> Data? { nil }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {}
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
