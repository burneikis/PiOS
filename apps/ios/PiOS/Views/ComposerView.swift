import PhotosUI
import PiOSCore
import SwiftUI
import UIKit

enum ComposerAction {
    case picker(SessionPicker)
    case info
}

/// Commands handled on the phone. Typed or picked, they never reach the model.
private struct NativeCommand {
    var name: String
    var hint: String
}

private let nativeCommands = [
    NativeCommand(name: "model", hint: "Switch model"),
    NativeCommand(name: "thinking", hint: "Thinking level"),
    NativeCommand(name: "compact", hint: "Compact context [instructions]"),
    NativeCommand(name: "autocompact", hint: "Auto-compaction [on|off]"),
    NativeCommand(name: "name", hint: "Rename session <name>"),
    NativeCommand(name: "copy", hint: "Copy the last reply"),
    NativeCommand(name: "session", hint: "Session info and stats"),
    NativeCommand(name: "export", hint: "Export to HTML [path]"),
    NativeCommand(name: "reload", hint: "Reload extensions and skills"),
]

/// Compose, then send. Prompts go through the outbox, so composing offline
/// works and a flaky connection never sends a message twice.
struct ComposerView: View {
    let sessionId: String
    let view: SessionView
    var onAction: (ComposerAction) -> Void = { _ in }
    var onSent: () -> Void = {}

    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var images: [ImageContent] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var behavior: StreamingBehavior = .steer
    @State private var fileMatches: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            suggestions
            VStack(alignment: .leading, spacing: 8) {
                if !images.isEmpty { attachments }
                HStack(alignment: .bottom, spacing: 8) {
                    PhotosPicker(selection: $picked, maxSelectionCount: 6, matching: .images) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.title3)
                            .frame(width: 32, height: 36)
                    }
                    .foregroundStyle(.secondary)

                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(1 ... 8)
                        .focused($focused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .font(isShell ? .system(.body, design: .monospaced) : .body)

                    if view.running, isEmpty {
                        Button { model.client.interrupt(sessionId) } label: {
                            Image(systemName: "stop.circle.fill").font(.title)
                        }
                        .tint(.red)
                        .disabled(view.interrupting)
                    } else {
                        sendButton
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .onAppear {
            text = model.client.takeRewoundText(sessionId) ?? model.composerText(sessionId)
        }
        .onChange(of: text) { _, value in model.setComposerText(sessionId, value) }
        .onChange(of: view.presentation.editorText) { _, value in
            if let value { text = value }
        }
        .onChange(of: picked) { _, items in Task { await attach(items) } }
        .task(id: mentionQuery) { await searchFiles() }
    }

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
    }

    private var isShell: Bool { text.hasPrefix("!") }

    private var placeholder: String {
        view.running ? (behavior == .steer ? "Steer the agent" : "Queue a follow-up") : "Message, /command or !shell"
    }

    private var sendButton: some View {
        HStack(spacing: 4) {
            if view.running {
                Menu {
                    Picker("While working", selection: $behavior) {
                        Label("Steer now", systemImage: "arrow.turn.down.right").tag(StreamingBehavior.steer)
                        Label("Follow up after", systemImage: "text.append").tag(StreamingBehavior.followUp)
                    }
                } label: {
                    Image(systemName: behavior == .steer ? "arrow.turn.down.right" : "text.append")
                        .font(.footnote)
                        .frame(width: 24, height: 36)
                }
            }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .disabled(isEmpty)
        }
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    if let data = Data(base64Encoded: image.data), let ui = UIImage(data: data) {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(alignment: .topTrailing) {
                                Button { images.remove(at: index) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .offset(x: 4, y: -4)
                            }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: Suggestions

    /// The `/word` being typed, when the whole input is one.
    private var slashQuery: String? {
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return nil }
        return String(text.dropFirst()).lowercased()
    }

    /// The `@path` being typed at the end of the input.
    private var mentionQuery: String? {
        guard let last = text.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("@") else { return nil }
        return String(last.dropFirst())
    }

    @ViewBuilder
    private var suggestions: some View {
        if let query = slashQuery {
            let native = nativeCommands.filter { query.isEmpty || $0.name.hasPrefix(query) }
            let session = model.commandsFor(sessionId).filter { query.isEmpty || $0.name.lowercased().contains(query) }
            if !native.isEmpty || !session.isEmpty {
                SuggestionList {
                    ForEach(native, id: \.name) { command in
                        SuggestionRow(title: "/\(command.name)", detail: command.hint, badge: "app") {
                            text = "/\(command.name) "
                        }
                    }
                    ForEach(session.prefix(30)) { command in
                        SuggestionRow(title: "/\(command.name)", detail: command.description, badge: command.source) {
                            text = "/\(command.name) "
                        }
                    }
                }
            }
        } else if mentionQuery != nil, !fileMatches.isEmpty {
            SuggestionList {
                ForEach(fileMatches, id: \.self) { path in
                    SuggestionRow(title: path, detail: nil, badge: nil) { completeMention(path) }
                }
            }
        }
    }

    private func completeMention(_ path: String) {
        var parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return }
        parts[parts.count - 1] = "@\(path) "
        text = parts.joined(separator: " ")
        fileMatches = []
    }

    /// Daemon-side fuzzy search: an installed picker extension cannot serve
    /// a client in RPC mode.
    private func searchFiles() async {
        guard let query = mentionQuery, let api = model.api else {
            fileMatches = []
            return
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard !Task.isCancelled else { return }
        let isDraft = model.summary(sessionId) == nil
        let matches = try? await api.findFiles(
            session: sessionId, cwd: isDraft ? model.cwd(sessionId) : nil, query: query
        )
        fileMatches = matches?.files ?? []
    }

    // MARK: Sending

    private func attach(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = encodeForPrompt(data) else { continue }
            images.append(image)
        }
        picked = []
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }

        if images.isEmpty, runNative(trimmed) {
            text = ""
            return
        }
        // `!` runs a shell command into the conversation, `!!` for the reader
        // alone. Never queued: replayed later it would hit a tree that moved.
        if trimmed.hasPrefix("!"), images.isEmpty {
            guard model.summary(sessionId) != nil else {
                model.toast = "Send a prompt first: a draft has no shell yet."
                return
            }
            let exclude = trimmed.hasPrefix("!!")
            let command = String(trimmed.dropFirst(exclude ? 2 : 1)).trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return }
            if model.client.runBash(sessionId, command, excludeFromContext: exclude) {
                text = ""
            } else {
                model.toast = "Not connected. Shell commands are never queued."
            }
            return
        }

        model.send(sessionId: sessionId, text: trimmed, images: images, behavior: view.running ? behavior : nil)
        text = ""
        images = []
        onSent()
    }

    /// True when the input was a phone-side command and has been handled.
    private func runNative(_ input: String) -> Bool {
        guard input.hasPrefix("/") else { return false }
        let parts = input.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        guard let name = parts.first?.lowercased() else { return false }
        let args = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let client = model.client
        switch name {
        case "model":
            onAction(.picker(.model))
        case "thinking":
            if args.isEmpty { onAction(.picker(.thinking)) } else { client.setThinkingLevel(sessionId, args) }
        case "compact":
            client.compact(sessionId, instructions: args)
        case "autocompact":
            let current = model.summary(sessionId)?.autoCompaction ?? true
            let enabled = args.isEmpty ? !current : ["on", "true", "1", "yes"].contains(args.lowercased())
            client.setAutoCompaction(sessionId, enabled)
            model.toast = "Auto-compaction \(enabled ? "on" : "off")"
        case "name":
            guard !args.isEmpty else { return false }
            client.setSessionName(sessionId, args)
        case "copy":
            if let reply = view.lastAssistantText {
                UIPasteboard.general.string = reply
                model.toast = "Copied last reply"
            } else {
                model.toast = "Nothing to copy"
            }
        case "session":
            onAction(.info)
        case "export":
            client.exportSession(sessionId, path: args)
        case "reload":
            client.reload(sessionId)
        default:
            return false
        }
        return true
    }
}

struct SuggestionList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
        }
        .frame(maxHeight: 220)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct SuggestionRow: View {
    let title: String
    let detail: String?
    let badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(.callout, design: .monospaced))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if let badge { Text(badge).font(.caption2).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
