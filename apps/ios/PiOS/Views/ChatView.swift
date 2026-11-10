import PiOSCore
import SwiftUI
import UIKit

/// One session's transcript, banners and composer.
///
/// Renders `client.view(sessionId)`, which already merges cached entries,
/// live events and the outbox; nothing here decides freshness or talks to a
/// socket.
struct ChatView: View {
    let sessionId: String
    /// Beside the list rather than under a drawer.
    let docked: Bool
    @Environment(AppModel.self) private var model
    @AppStorage("pios.showStats") private var showStats = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var compacting = false
    @State private var compactNote = ""
    @State private var allModels = false
    @State private var showInfo = false
    @FocusState private var composing: Bool

    var body: some View {
        let view = model.view(sessionId)
        let summary = model.summary(sessionId)
        let cwd = model.cwd(sessionId)
        let isDraft = model.draft(sessionId) != nil && summary == nil
        let named = sessionTitle(name: summary?.name, cwd: cwd)
        let title: (String, Bool) = view.presentation.title.map { ($0, false) } ?? (named.text, named.isPath)
        let state = SessionState.of(summary, running: view.running, interrupting: view.interrupting, blocked: !view.dialogs.isEmpty)

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.turnGap) {
                    if view.hasOlder {
                        Button("Load earlier messages") { model.client.loadOlderEntries(sessionId) }
                            .buttonStyle(GhostButtonStyle())
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(view.items) { item in
                        TranscriptItem(item: item, view: view, sessionId: sessionId, cwd: cwd)
                    }
                    if let bash = view.bash {
                        BashRunView(run: bash) { model.client.abortBash(sessionId) }
                    }
                    if view.running, view.items.last.map({ isIdleTail($0) }) ?? true {
                        WorkingIndicator(interrupting: view.interrupting, blocked: !view.dialogs.isEmpty)
                    }
                    if showStats, !view.running, let stats = model.statsFor(sessionId) {
                        StatsFooter(stats: stats)
                    }
                    Color.clear.frame(height: 1).id(bottomId)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg)
            // The dock floats over the transcript, which reads through it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Dock(
                    sessionId: sessionId, view: view, summary: summary, isDraft: isDraft, composing: $composing,
                    onAllModels: { allModels = true },
                    onInfo: { showInfo = true },
                    onSent: { withAnimation { proxy.scrollTo(bottomId, anchor: .bottom) } }
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(view: view, summary: summary, isDraft: isDraft, title: title, state: state) }
        // Every pushed screen is declared here, at the stack's root, so no
        // destination depends on a pushed view staying alive.
        .navigationDestination(for: ChatRoute.self) { route in
            switch route {
            case .git:
                GitView(git: model.git(sessionId))
            case let .gitDetail(subject):
                GitDetailView(git: model.git(sessionId), subject: subject)
            case let .files(path):
                FilesView(project: model.project(sessionId), root: cwd ?? "", path: path)
            case let .file(path):
                FileEditorView(project: model.project(sessionId), path: path)
            case .terminal:
                // One shell per session, shared by every device.
                TerminalScreen(terminalId: sessionId, cwd: cwd ?? "")
            }
        }
        .task(id: view.running) {
            // A turn that settled has stopped writing files.
            if !view.running { await model.git(sessionId).refresh(fresh: false) }
        }
        .sheet(item: dialogBinding(view)) { request in
            DialogSheet(request: request) { answer in
                model.client.answerDialog(
                    sessionId, requestId: request.id, value: answer.value, confirmed: answer.confirmed,
                    cancelled: answer.cancelled
                )
            }
        }
        .sheet(isPresented: $allModels) {
            NavigationStack { ModelPicker(sessionId: sessionId) }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showInfo) {
            NavigationStack { SessionInfoView(sessionId: sessionId) }.presentationDetents([.medium, .large])
        }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.client.setSessionName(sessionId, name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Compact context", isPresented: $compacting) {
            TextField("Optional instructions", text: $compactNote)
            Button("Compact") { model.client.compact(sessionId, instructions: compactNote) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Summarises the history for the model. The transcript keeps everything.")
        }
        .task(id: isDraft) {
            // A draft has no session to subscribe to until its first prompt.
            guard !isDraft else { return }
            model.client.watch(sessionId)
            model.client.listCommands(sessionId)
            // The composer's model menu reads this; a draft asks on demand,
            // because asking starts its agent.
            model.client.listModels(sessionId)
            if showStats { model.client.requestStats(sessionId) }
        }
        .onDisappear {
            // A screen pushed over the chat hides it without leaving the
            // session; only a new selection ends the subscription.
            if !isDraft, model.selection != sessionId { model.client.unwatch(sessionId) }
        }
        .onChange(of: view.running) { _, running in
            if !running, showStats, !isDraft { model.client.requestStats(sessionId) }
        }
    }

    private let bottomId = "bottom"

    private func isIdleTail(_ item: ViewItem) -> Bool {
        if case .streaming = item { return false }
        return true
    }

    private func dialogBinding(_ view: SessionView) -> Binding<ExtensionUiRequest?> {
        Binding(
            get: { view.dialogs.first },
            // Read live, not from the snapshot: an answered dialog is already
            // closed and must not be cancelled on the way out.
            set: { value in
                if value == nil, let open = model.client.sessions.openDialogs(sessionId).first {
                    model.client.answerDialog(sessionId, requestId: open.id, cancelled: true)
                }
            }
        )
    }

    @ToolbarContentBuilder
    private func toolbar(view: SessionView, summary: SessionSummary?, isDraft: Bool, title: (String, Bool), state: SessionState) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if docked {
                Button { model.sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
            } else {
                // Not a pop: the list slides over the chat, which stays put.
                Button { model.drawerOpen = true } label: { Image(systemName: "chevron.left") }
            }
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 6) {
                Text(title.0)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    // A path is cut at the front: its end tells two apart.
                    .truncationMode(title.1 ? .head : .tail)
                StatusMark(state: state).font(.system(size: 13))
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            GitChip(git: model.git(sessionId)) { model.path.append(.git) }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section {
                    Button { model.path.append(.files(nil)) } label: { Label("Files", systemImage: "doc") }
                    if model.cwd(sessionId) != nil {
                        Button { model.path.append(.terminal) } label: { Label("Terminal", systemImage: "terminal") }
                    }
                    Button { model.pickerStart = model.cwd(sessionId) ?? "" } label: {
                        Label("New session", systemImage: "plus")
                    }
                }
                if !isDraft {
                    Section {
                        Button { newName = summary?.name ?? ""; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                        Button { compactNote = ""; compacting = true } label: {
                            Label("Compact", systemImage: "rectangle.compress.vertical")
                        }
                        Button { model.client.reload(sessionId) } label: {
                            Label("Reload", systemImage: "arrow.clockwise")
                        }
                        .disabled(view.running)
                        Button { model.client.exportSession(sessionId) } label: {
                            Label("Export HTML", systemImage: "square.and.arrow.up")
                        }
                    }
                    Section {
                        if let text = view.lastAssistantText {
                            Button { UIPasteboard.general.string = text; model.toast = "Copied last reply" } label: {
                                Label("Copy last reply", systemImage: "doc.on.doc")
                            }
                        }
                        Button { showInfo = true } label: { Label("Session info", systemImage: "info.circle") }
                        if let summary, !summary.trusted {
                            Button { model.client.setSessionTrust(sessionId, true) } label: {
                                Label("Trust this directory", systemImage: "checkmark.shield")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }
}

/// A screen over the chat. `files(nil)` is the project root.
enum ChatRoute: Hashable {
    case git
    case gitDetail(GitDetailView.Subject)
    case files(String?)
    case file(String)
    case terminal
}

extension AppModel {
    func statsFor(_ sessionId: String) -> SessionStats? {
        _ = metadataRevision
        return client.stats(sessionId)
    }

    func modelsFor(_ sessionId: String) -> ModelListing {
        _ = metadataRevision
        return client.models(sessionId)
    }

    func commandsFor(_ sessionId: String) -> [CommandOption] {
        _ = metadataRevision
        return client.commands(sessionId)
    }
}

/// Everything that floats over the bottom of the transcript: status lines,
/// extension chips and widgets, and the composer. Ambient parts fold away
/// while typing, as in the PWA.
struct Dock: View {
    let sessionId: String
    let view: SessionView
    let summary: SessionSummary?
    let isDraft: Bool
    var composing: FocusState<Bool>.Binding
    var onAllModels: () -> Void
    var onInfo: () -> Void
    var onSent: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            SessionBanners(sessionId: sessionId, view: view, summary: summary)
            if !composing.wrappedValue {
                ExtensionStatus(presentation: view.presentation, placement: "aboveEditor")
            }
            ComposerView(
                sessionId: sessionId, view: view, summary: summary, isDraft: isDraft, focused: composing,
                onAllModels: onAllModels, onInfo: onInfo, onSent: onSent
            )
            if !composing.wrappedValue {
                ExtensionStatus(presentation: view.presentation, placement: "belowEditor", chips: false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.18), value: composing.wrappedValue)
    }
}

/// Extension status chips and widgets for one slot. pi defaults an unplaced
/// widget above the editor.
struct ExtensionStatus: View {
    let presentation: SessionPresentation
    let placement: String
    var chips = true

    var body: some View {
        let widgets = presentation.widgets.filter { ($0.placement ?? "aboveEditor") == placement }
        if chips, !presentation.status.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(presentation.status, id: \.key) { item in
                        Text(item.text)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .glassSurface(cornerRadius: 999)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        ForEach(widgets, id: \.key) { widget in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(widget.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).lineLimit(1)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .glassSurface(cornerRadius: Theme.radius)
        }
    }
}

struct WorkingIndicator: View {
    let interrupting: Bool
    let blocked: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini).tint(Theme.muted)
            Text(blocked ? "Waiting for your answer" : interrupting ? "Stopping..." : "Working...")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
        }
    }
}

/// Accounting, not conversation: it sits under the last turn and stays quiet.
struct StatsFooter: View {
    let stats: SessionStats

    var body: some View {
        HStack(spacing: 12) {
            if let percent = stats.contextPercent { Text("\(Int(percent.rounded()))% context") }
            if let total = stats.tokensTotal { Text("\(compactNumber(total)) tokens") }
            if let cost = stats.cost, cost > 0 { Text(String(format: "$%.2f", cost)) }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
