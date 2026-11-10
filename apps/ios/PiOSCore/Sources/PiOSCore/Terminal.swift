import Foundation

/// A position in one shell's output. `instance` changes when the shell is
/// replaced, which makes an offset from the old one meaningless.
///
/// Offsets count UTF-16 code units, because that is how the daemon (in
/// JavaScript) measures its strings.
public struct TerminalCursor: Hashable, Sendable {
    public var instance: String
    public var offset: Int
}

public struct TerminalSize: Hashable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

/// Where a terminal's output goes: in the app, a SwiftTerm view.
@MainActor
public protocol TerminalSink: AnyObject {
    /// What follows does not continue what was written; clear first.
    func reset()
    func output(_ data: String)
    func exit(code: Int, signal: Int?)
    /// The daemon refused to open the shell.
    func failed(_ message: String)
}

/// One open terminal, as the UI holds it. Never touches a socket itself.
@MainActor
public final class TerminalHandle {
    private let channel: TerminalChannel
    private let terminalId: String
    private let attachment: TerminalChannel.Attachment

    init(channel: TerminalChannel, terminalId: String, attachment: TerminalChannel.Attachment) {
        self.channel = channel
        self.terminalId = terminalId
        self.attachment = attachment
    }

    private var live: Bool { channel.attachments[terminalId] === attachment }

    /// False when there is no connection; keystrokes are never queued.
    @discardableResult
    public func write(_ data: String) -> Bool {
        live && channel.command(.terminalInput(terminalId: terminalId, data: data))
    }

    public func resize(_ size: TerminalSize) {
        guard live, size != attachment.size else { return }
        attachment.size = size
        channel.command(.terminalResize(terminalId: terminalId, cols: size.cols, rows: size.rows))
    }

    /// Starts a new shell in place of one that has exited.
    public func restart() {
        if live { channel.sendOpen(terminalId, attachment, restart: true) }
    }

    /// Stops streaming here and leaves the shell running.
    public func detach() {
        guard live else { return }
        channel.attachments[terminalId] = nil
        channel.command(.terminalDetach(terminalId: terminalId))
    }

    /// Hangs up the shell for every device.
    public func kill() {
        guard live else { return }
        channel.attachments[terminalId] = nil
        channel.command(.terminalClose(terminalId: terminalId))
    }
}

/// Daemon-owned shells, streamed over the client's one socket.
///
/// Output is tracked by offset, so a reconnect asks for exactly what was
/// missed, and a duplicate or a gap in the live stream is visible rather than
/// silently corrupting the screen. Input is never queued: keystrokes replayed
/// after a reconnect would land in whatever the shell is doing by then.
@MainActor
public final class TerminalChannel {
    final class Attachment {
        let cwd: String
        var size: TerminalSize
        weak var sink: TerminalSink?
        /// Absent until the daemon has said which shell this is.
        var cursor: TerminalCursor?
        var openCommandId: String?

        init(cwd: String, size: TerminalSize, sink: TerminalSink) {
            self.cwd = cwd
            self.size = size
            self.sink = sink
        }
    }

    /// Marks the commands this channel sent, so their errors come back here.
    static let idPrefix = "term:"

    fileprivate(set) var attachments: [String: Attachment] = [:]
    private let send: (ClientCommand, String) -> Bool
    private let generateId: () -> String

    init(send: @escaping (ClientCommand, String) -> Bool, generateId: @escaping () -> String) {
        self.send = send
        self.generateId = generateId
    }

    /// Attaches to the shell under `terminalId`, starting it if it has none.
    /// Opening an id already held hands the stream to the new sink and
    /// replays from scratch, since the new sink starts empty.
    public func open(_ terminalId: String, cwd: String, size: TerminalSize, sink: TerminalSink) -> TerminalHandle {
        let attachment = Attachment(cwd: cwd, size: size, sink: sink)
        attachments[terminalId] = attachment
        sendOpen(terminalId, attachment, restart: false)
        return TerminalHandle(channel: self, terminalId: terminalId, attachment: attachment)
    }

    /// Re-attaches everything after a reconnect, each from its own cursor.
    func reconnected() {
        for (id, attachment) in attachments { sendOpen(id, attachment, restart: false) }
    }

    /// True when the frame was a terminal's, handled or not.
    func onFrame(_ frame: ServerFrame) -> Bool {
        switch frame.body {
        case let .terminalAttached(id, instance, offset, reset):
            // A reply to an open this sink has since replaced is not its to apply.
            guard let attachment = attachments[id], frame.commandId == attachment.openCommandId else { return true }
            attachment.openCommandId = nil
            if reset { attachment.sink?.reset() }
            attachment.cursor = TerminalCursor(instance: instance, offset: offset)
            return true
        case let .terminalOutput(id, offset, data):
            onOutput(id, offset: offset, data: data)
            return true
        case let .terminalExit(id, code, signal):
            attachments[id]?.sink?.exit(code: code, signal: signal)
            return true
        default:
            return false
        }
    }

    /// Claims a refusal of any terminal command. Only a refused open is
    /// reported: a keystroke refused because the shell is gone says nothing
    /// the exit has not, once per key.
    func onError(_ commandId: String, message: String) -> Bool {
        guard commandId.hasPrefix(Self.idPrefix) else { return false }
        for attachment in attachments.values where attachment.openCommandId == commandId {
            attachment.openCommandId = nil
            attachment.sink?.failed(message)
        }
        return true
    }

    fileprivate func sendOpen(_ terminalId: String, _ attachment: Attachment, restart: Bool) {
        let commandId = nextId()
        attachment.openCommandId = commandId
        _ = send(
            .terminalOpen(
                terminalId: terminalId, cwd: attachment.cwd, cols: attachment.size.cols, rows: attachment.size.rows,
                since: restart ? nil : attachment.cursor, restart: restart
            ),
            commandId
        )
    }

    private func onOutput(_ terminalId: String, offset: Int, data: String) {
        // Before the attach reply there is no offset to place output against,
        // and the replay that follows the reply covers it.
        guard let attachment = attachments[terminalId], attachment.openCommandId == nil,
              var cursor = attachment.cursor
        else { return }
        let units = Array(data.utf16)
        let end = offset + units.count
        if end <= cursor.offset { return }
        if offset > cursor.offset {
            // Output went missing in between. Ask again from what is held.
            sendOpen(terminalId, attachment, restart: false)
            return
        }
        let fresh = units[(cursor.offset - offset)...]
        attachment.sink?.output(String(decoding: fresh, as: UTF16.self))
        cursor.offset = end
        attachment.cursor = cursor
    }

    @discardableResult
    fileprivate func command(_ command: ClientCommand) -> Bool {
        send(command, nextId())
    }

    private func nextId() -> String { Self.idPrefix + generateId() }
}
