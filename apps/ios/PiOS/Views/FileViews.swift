import PiOSCore
import SwiftUI
import UIKit

/// The project's files: the tree when the search is empty, the daemon's
/// gitignore-aware fuzzy search when it is not. Browsing is explicit intent
/// and shows what git hides; searching is for finding, and does not.
struct FilesView: View {
    let project: Project
    let root: String
    /// Nil is the project root.
    var path: String? = nil
    @Environment(AppModel.self) private var model
    @State private var listing: DirectoryListing? = nil
    @State private var query = ""
    @State private var matches: [String] = []
    @State private var error: String? = nil

    var body: some View {
        List {
            if let error { empty(error, color: Theme.error) }
            if !query.isEmpty {
                ForEach(matches, id: \.self) { match in
                    NavigationLink(value: FileRoute.file(absolute(match))) {
                        fileRow(name: (match as NSString).lastPathComponent, detail: (match as NSString).deletingLastPathComponent, dir: false)
                    }
                }
                if matches.isEmpty { empty("No matching files.") }
            } else if let listing {
                ForEach(listing.entries) { entry in
                    NavigationLink(value: entry.dir == true ? FileRoute.directory(entry.path) : FileRoute.file(entry.path)) {
                        fileRow(name: entry.name, detail: nil, dir: entry.dir == true)
                    }
                }
                if listing.entries.isEmpty { empty("Empty directory.") }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .listRowBackground(Theme.panel)
        .themedList()
        .navigationTitle(path.map { ($0 as NSString).lastPathComponent } ?? "Files")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search files")
        .task(id: path) { await load() }
        .task(id: query) { await search() }
        .refreshable { await load() }
    }

    private func fileRow(name: String, detail: String?, dir: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: dir ? "folder" : fileSymbol(name))
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
                }
            }
        }
    }

    /// Search results are relative to the project root.
    private func absolute(_ match: String) -> String {
        match.hasPrefix("/") ? match : (root as NSString).appendingPathComponent(match)
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            listing = try await api.tree(project, path: path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func search() async {
        guard !query.isEmpty, let api = model.api else {
            matches = []
            return
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard !Task.isCancelled else { return }
        matches = (try? await api.findFiles(project, query: query, limit: 60).files) ?? []
    }
}

enum FileRoute: Hashable {
    case directory(String)
    case file(String)
}

func fileSymbol(_ name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp": return "photo"
    case "md", "txt", "rst": return "doc.plaintext"
    case "json", "yml", "yaml", "toml": return "curlybraces"
    default: return "doc.text"
    }
}

private let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp"]

/// One file: read by default, edited on request, saved against the etag it
/// was loaded with. Unsaved text is kept on the device, so leaving is safe.
struct FileEditorView: View {
    let project: Project
    let path: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("pios.editorFontSize") private var fontSize = 12.0
    @AppStorage("pios.editor.wrap") private var wrap = true
    @State private var file: TextFile? = nil
    @State private var text = ""
    @State private var dirty = false
    @State private var editing = false
    @State private var restored = false
    @State private var conflict = false
    @State private var saving = false
    @State private var error: String? = nil
    @State private var image: UIImage? = nil
    @State private var confirmLeave = false

    private var isImage: Bool { imageExtensions.contains((path as NSString).pathExtension.lowercased()) }

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 6) {
                if let error { StatusLine(text: error, tone: .error) }
                if let refusal = file?.refusal { StatusLine(text: refusal, tone: .warn) }
                if restored { StatusLine(text: "Restored unsaved changes from this device.") {
                    Button("Discard") { Task { await reload() } }
                } }
                if conflict {
                    StatusLine(text: "The file changed on the machine since it was opened.", tone: .warn) {
                        Button("Reload") { Task { await reload() } }
                        Button("Overwrite") { Task { await save(force: true) } }
                    }
                }
            }
            .padding(.horizontal, 12)

            if isImage {
                if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                    }
                } else {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if file != nil {
                CodeTextView(
                    text: $text,
                    editable: editing && file?.editable == true,
                    wrap: wrap,
                    fontSize: fontSize,
                    onEdit: edited
                )
            } else if error == nil {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
        .background(Theme.bg)
        .navigationTitle((path as NSString).lastPathComponent + (dirty ? " \u{2022}" : ""))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(dirty)
        .toolbar { toolbar }
        .confirmationDialog("Leave with unsaved changes?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave") { dismiss() }
            Button("Stay", role: .cancel) {}
        } message: {
            Text("They are kept on this device as a draft.")
        }
        .task(id: path) { await load() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if dirty {
            ToolbarItem(placement: .topBarLeading) {
                Button { confirmLeave = true } label: { Image(systemName: "chevron.left") }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if file?.editable == true {
                if editing {
                    Button(saving ? "Saving..." : "Save") { Task { await save(force: false) } }
                        .disabled(!dirty || saving)
                } else {
                    Button("Edit") { editing = true }
                }
            }
            Menu {
                Toggle(isOn: $wrap) { Label("Wrap lines", systemImage: "text.word.spacing") }
                Button { UIPasteboard.general.string = text } label: { Label("Copy contents", systemImage: "doc.on.doc") }
                Button { UIPasteboard.general.string = path } label: { Label("Copy path", systemImage: "link") }
                Button { Task { await share() } } label: { Label("Share file", systemImage: "square.and.arrow.up") }
                Button { Task { await reload() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }

    private var draftKey: String { "pios.filedraft.\(project.sessionId).\(path)" }

    private struct FileDraft: Codable {
        var text: String
        var etag: String
    }

    private func load() async {
        guard let api = model.api else { return }
        if isImage {
            do {
                image = UIImage(data: try await api.file(project, path: path))
            } catch {
                self.error = error.localizedDescription
            }
            return
        }
        do {
            let loaded = try await api.textFile(project, path: path)
            let draft = readVersioned(model.storage, draftKey, version: 1, fallback: FileDraft?.none)
            file = loaded
            // A draft from an older version is still the user's work: shown,
            // and the stale etag surfaces as a conflict on save.
            if let draft, loaded.editable {
                text = draft.text
                file?.etag = draft.etag
                dirty = true
                restored = true
                editing = true
            } else {
                text = loaded.text
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func edited() {
        dirty = true
        if let file { writeVersioned(model.storage, draftKey, version: 1, FileDraft(text: text, etag: file.etag)) }
    }

    private func save(force: Bool) async {
        guard let api = model.api, let current = file else { return }
        saving = true
        defer { saving = false }
        error = nil
        do {
            switch try await api.saveText(project, path: path, text: text, file: current, force: force) {
            case let .saved(etag):
                file?.etag = etag
                dirty = false
                restored = false
                conflict = false
                model.storage.remove(draftKey)
            case .conflict:
                conflict = true
            case let .failed(message):
                error = message
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reload() async {
        model.storage.remove(draftKey)
        dirty = false
        restored = false
        conflict = false
        editing = false
        file = nil
        await load()
    }

    private func share() async {
        guard let api = model.api, let data = try? await api.file(project, path: path) else { return }
        model.share(data: data, named: (path as NSString).lastPathComponent)
    }
}

/// A plain-text code view: monospaced, no autocorrect or smart punctuation,
/// optional wrapping, and the keys a phone keyboard lacks on the row above it.
struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    let editable: Bool
    let wrap: Bool
    let fontSize: Double
    let onEdit: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = UIColor(Theme.bg)
        view.textColor = UIColor(Theme.text)
        view.tintColor = UIColor(Theme.accent)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardAppearance = .dark
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 24, right: 12)
        view.keyboardDismissMode = .interactive
        view.inputAccessoryView = context.coordinator.keyRow(for: view)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        view.isEditable = editable
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // Unwrapped, the container is wider than any line and the view
        // scrolls sideways: code is columnar.
        view.textContainer.widthTracksTextView = wrap
        if !wrap { view.textContainer.size = CGSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude) }
        view.alwaysBounceHorizontal = !wrap
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeTextView
        private weak var view: UITextView?

        init(parent: CodeTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.onEdit()
        }

        func keyRow(for view: UITextView) -> UIView {
            self.view = view
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            bar.barStyle = .black
            bar.items = [
                UIBarButtonItem(image: UIImage(systemName: "increase.indent"), style: .plain, target: self, action: #selector(indent)),
                UIBarButtonItem(image: UIImage(systemName: "decrease.indent"), style: .plain, target: self, action: #selector(outdent)),
                UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.backward"), style: .plain, target: self, action: #selector(undo)),
                UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.forward"), style: .plain, target: self, action: #selector(redo)),
                UIBarButtonItem(systemItem: .flexibleSpace),
                UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"), style: .plain, target: self, action: #selector(done)),
            ]
            bar.tintColor = UIColor(Theme.text)
            return bar
        }

        @objc private func indent() { shiftLines(by: 1) }
        @objc private func outdent() { shiftLines(by: -1) }
        @objc private func undo() { view?.undoManager?.undo() }
        @objc private func redo() { view?.undoManager?.redo() }
        @objc private func done() { view?.resignFirstResponder() }

        /// Indents or outdents every line the selection touches, two spaces
        /// at a time, through the text view so undo covers it.
        private func shiftLines(by direction: Int) {
            guard let view, view.isEditable else { return }
            let text = view.text as NSString
            let lines = text.lineRange(for: view.selectedRange)
            let block = text.substring(with: lines)
            let shifted = block.components(separatedBy: "\n").enumerated().map { index, line -> String in
                // The last element after a trailing newline is not a line.
                if index > 0, line.isEmpty, block.hasSuffix("\n") { return line }
                if direction > 0 { return "  " + line }
                let spaces = line.prefix(2).prefix { $0 == " " }.count
                return String(line.dropFirst(spaces))
            }.joined(separator: "\n")
            guard let start = view.position(from: view.beginningOfDocument, offset: lines.location),
                  let end = view.position(from: start, offset: lines.length),
                  let range = view.textRange(from: start, to: end)
            else { return }
            view.replace(range, withText: shifted)
            view.selectedRange = NSRange(location: lines.location, length: (shifted as NSString).length)
        }
    }
}
