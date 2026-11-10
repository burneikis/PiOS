import PhotosUI
import PiOSCore
import SwiftUI
import UIKit

/// Commands handled on the phone. Typed or picked, they never reach the model.
private struct NativeCommand {
    var name: String
    var hint: String
}

private let nativeCommands = [
    NativeCommand(name: "model", hint: "Switch model"),
    NativeCommand(name: "thinking", hint: "Thinking level [level]"),
    NativeCommand(name: "compact", hint: "Compact context [instructions]"),
    NativeCommand(name: "autocompact", hint: "Auto-compaction [on|off]"),
    NativeCommand(name: "name", hint: "Rename session <name>"),
    NativeCommand(name: "copy", hint: "Copy the last reply"),
    NativeCommand(name: "session", hint: "Session info and stats"),
    NativeCommand(name: "export", hint: "Export to HTML [path]"),
    NativeCommand(name: "reload", hint: "Reload extensions and skills"),
    NativeCommand(name: "new", hint: "Start a new session"),
    NativeCommand(name: "sessions", hint: "Back to the session list"),
    NativeCommand(name: "trust", hint: "Trust this directory"),
    NativeCommand(name: "settings", hint: "Machine and app settings"),
]

/// Compose, then send. Prompts go through the outbox, so composing offline
/// works and a flaky connection never sends a message twice.
///
/// Input and its controls are one surface, as in the PWA. While typing the
/// pickers fold away and the field takes their room.
struct ComposerView: View {
    let sessionId: String
    let view: SessionView
    let summary: SessionSummary?
    let isDraft: Bool
    var focused: FocusState<Bool>.Binding
    var onAllModels: () -> Void
    var onInfo: () -> Void
    var onSent: () -> Void

    @Environment(AppModel.self) private var model
    @AppStorage("pios.steeringMode") private var steeringMode = StreamingBehavior.steer.rawValue
    @State private var text = ""
    @State private var images: [ImageContent] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var fileMatches: [String] = []

    var body: some View {
        let typing = focused.wrappedValue
        // One layout or the other, with the same children: the field keeps
        // its identity, and with it the keyboard, across the change.
        let layout = typing
            ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 4))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 4))

        VStack(spacing: 6) {
            suggestions
            VStack(alignment: .leading, spacing: 4) {
                if !images.isEmpty { attachments }
                layout {
                    TextField("Message pi", text: $text, axis: .vertical)
                        .lineLimit(1 ... 10)
                        .font(isShell ? Theme.mono(14) : Theme.body)
                        .foregroundStyle(Theme.text)
                        .focused(focused)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    actions(typing: typing)
                }
            }
            .padding(8)
            .glassSurface(cornerRadius: 20)
        }
        .onAppear {
            text = model.client.takeRewoundText(sessionId) ?? model.composerText(sessionId)
        }
        .onChange(of: text) { _, value in model.setComposerText(sessionId, value) }
        .onChange(of: view.presentation.editorText) { _, value in
            if let value { text = value }
        }
        .onChange(of: picked) { _, items in Task { await attach(items) } }
        .photosPicker(isPresented: $showLibrary, selection: $picked, maxSelectionCount: 6, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in
                if let image = encodeForPrompt(data) { images.append(image) }
            }
            .ignoresSafeArea()
        }
        .task(id: mentionQuery) { await searchFiles() }
    }

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
    }

    private var isShell: Bool { text.hasPrefix("!") }

    private var behavior: StreamingBehavior { StreamingBehavior(rawValue: steeringMode) ?? .steer }

    // MARK: Actions row

    @ViewBuilder
    private func actions(typing: Bool) -> some View {
        HStack(spacing: 4) {
            if !typing {
                Menu {
                    Button { showLibrary = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                    }
                    Button { pasteImage() } label: { Label("Paste Image", systemImage: "doc.on.clipboard") }
                        .disabled(!UIPasteboard.general.hasImages)
                } label: {
                    Image(systemName: "plus").font(.system(size: 17)).frame(width: 36, height: 36)
                }
                .foregroundStyle(Theme.muted)
                modelMenu
                thinkingMenu
                Spacer(minLength: 4)
            }
            // Stop sits beside Send, not instead of it: the next turn can be
            // queued while the agent still runs.
            if view.running {
                Button { model.client.interrupt(sessionId) } label: {
                    Image(systemName: "stop.fill").font(.system(size: 13)).frame(width: 36, height: 36)
                }
                .foregroundStyle(Theme.muted)
                .disabled(view.interrupting)
            }
            sendButton
        }
    }

    /// Tap sends; while the agent works, a long press picks steer or follow-up
    /// for this one message.
    @ViewBuilder
    private var sendButton: some View {
        if view.running {
            Menu {
                Button { send(behavior: .steer) } label: { Label("Steer now", systemImage: "arrow.turn.down.right") }
                Button { send(behavior: .followUp) } label: { Label("Follow up after", systemImage: "text.append") }
            } label: {
                sendGlyph
                    .foregroundStyle(Theme.onAccent)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(isEmpty ? 0.4 : 1)))
            } primaryAction: {
                send(behavior: behavior)
            }
            .disabled(isEmpty)
        } else {
            Button { send(behavior: nil) } label: { sendGlyph }
                .primaryButton()
                .disabled(isEmpty)
        }
    }

    /// The one filled control on screen; the button style supplies the fill.
    private var sendGlyph: some View {
        Image(systemName: view.running && behavior == .followUp ? "text.append" : "arrow.up")
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 24, height: 24)
    }

    /// The session's model scope, as the PWA's dock picker; the whole
    /// catalogue is one more tap, in a searchable sheet.
    private var modelMenu: some View {
        let current = summary?.model
        let options = modelOptions(current: current)
        return Menu {
            if options.isEmpty {
                Button("Load models") { model.client.listModels(sessionId, create: model.create(for: sessionId)) }
            } else {
                Picker("Model", selection: Binding(
                    get: { current?.id ?? "" },
                    set: { id in
                        if let pick = options.first(where: { $0.id == id }) {
                            model.client.setModel(sessionId, provider: pick.provider, modelId: pick.modelId)
                        }
                    }
                )) {
                    ForEach(options) { option in Text(option.name).tag(option.id) }
                }
            }
            Divider()
            Button { onAllModels() } label: { Label("All models...", systemImage: "list.bullet") }
        } label: {
            pickerLabel(current?.name ?? (isDraft ? "Model" : "Default model"))
        }
    }

    /// Scoped models, or everything when pi has no scope. The running model
    /// is always offered, or the menu would hide what is actually in use.
    private func modelOptions(current: ModelOption?) -> [ModelOption] {
        let listing = model.modelsFor(sessionId)
        let scoped = listing.models.filter(\.scoped)
        let options = scoped.isEmpty ? listing.models : scoped
        guard let current, !options.contains(where: { $0.id == current.id }) else { return options }
        return [current] + options
    }

    @ViewBuilder
    private var thinkingMenu: some View {
        let levels = summary?.thinkingLevels ?? []
        if !levels.isEmpty {
            Menu {
                Picker("Thinking", selection: Binding(
                    get: { summary?.thinkingLevel ?? "" },
                    set: { model.client.setThinkingLevel(sessionId, $0) }
                )) {
                    ForEach(levels, id: \.self) { level in Text(level.capitalized).tag(level) }
                }
            } label: {
                pickerLabel((summary?.thinkingLevel ?? "default").capitalized)
            }
        }
    }

    private func pickerLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .contentShape(Rectangle())
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    if let data = Data(base64Encoded: image.data), let ui = UIImage(data: data) {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            .padding(.horizontal, 4)
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

    /// Floats with the composer and goes away once a choice is made.
    @ViewBuilder
    private var suggestions: some View {
        if let query = slashQuery {
            let native = nativeCommands.filter { query.isEmpty || $0.name.hasPrefix(query) }
            let session = model.commandsFor(sessionId).filter { query.isEmpty || $0.name.lowercased().contains(query) }
            if !native.isEmpty || !session.isEmpty {
                SuggestionList {
                    ForEach(native, id: \.name) { command in
                        SuggestionRow(title: "/\(command.name)", detail: command.hint) { text = "/\(command.name) " }
                    }
                    ForEach(session.prefix(30)) { command in
                        SuggestionRow(title: "/\(command.name)", detail: command.description) { text = "/\(command.name) " }
                    }
                }
            }
        } else if mentionQuery != nil, !fileMatches.isEmpty {
            SuggestionList {
                ForEach(fileMatches, id: \.self) { path in
                    SuggestionRow(title: path, detail: nil) { completeMention(path) }
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
        let matches = try? await api.findFiles(model.project(sessionId), query: query, limit: 20)
        fileMatches = matches?.files ?? []
    }

    // MARK: Sending

    /// A screenshot is the fastest way to show the agent something, and on a
    /// phone the clipboard is often the only path to one.
    private func pasteImage() {
        for image in UIPasteboard.general.images ?? [] {
            if let data = image.pngData(), let encoded = encodeForPrompt(data) { images.append(encoded) }
        }
    }

    private func attach(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = encodeForPrompt(data) else { continue }
            images.append(image)
        }
        picked = []
    }

    private func send(behavior: StreamingBehavior?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }

        if images.isEmpty, runNative(trimmed) {
            text = ""
            return
        }
        // `!` runs a shell command into the conversation, `!!` for the reader
        // alone. Never queued: replayed later it would hit a tree that moved.
        if trimmed.hasPrefix("!"), images.isEmpty {
            guard !isDraft else {
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

        model.send(sessionId: sessionId, text: trimmed, images: images, behavior: view.running ? (behavior ?? self.behavior) : nil)
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
            onAllModels()
        case "thinking":
            guard !args.isEmpty else { return false }
            client.setThinkingLevel(sessionId, args)
        case "compact":
            client.compact(sessionId, instructions: args)
        case "autocompact":
            let current = summary?.autoCompaction ?? true
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
            onInfo()
        case "export":
            client.exportSession(sessionId, path: args)
        case "reload":
            client.reload(sessionId)
        case "new":
            model.pickerStart = model.cwd(sessionId) ?? ""
        case "settings":
            model.showSettings = true
        case "sessions":
            model.open(nil)
        case "trust":
            client.setSessionTrust(sessionId, true)
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
                .padding(4)
        }
        .frame(maxHeight: 260)
        .fixedSize(horizontal: false, vertical: true)
        .glassSurface(cornerRadius: 16)
    }
}

struct SuggestionRow: View {
    let title: String
    let detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.mono(13)).foregroundStyle(Theme.text).lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The system camera, returning the photo's bytes.
struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) { parent.onPick(data) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
