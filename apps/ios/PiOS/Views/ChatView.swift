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
    @Environment(AppModel.self) private var model
    @AppStorage("pios.showStats") private var showStats = true
    @State private var renaming = false
    @State private var newName = ""
    @State private var compacting = false
    @State private var compactNote = ""
    @State private var picker: SessionPicker? = nil
    @State private var showInfo = false

    var body: some View {
        let view = model.view(sessionId)
        let summary = model.summary(sessionId)
        let cwd = model.cwd(sessionId)
        let isDraft = model.draft(sessionId) != nil && summary == nil

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if view.hasOlder {
                        Button("Load earlier messages") { model.client.loadOlderEntries(sessionId) }
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                    }
                    if isDraft {
                        DraftIntro(cwd: cwd ?? "")
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
                .padding(.horizontal)
                .padding(.vertical, 12)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) {
                SessionBanners(sessionId: sessionId, view: view, summary: summary)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerView(
                    sessionId: sessionId,
                    view: view,
                    onAction: { action in
                        switch action {
                        case let .picker(kind): picker = kind
                        case .info: showInfo = true
                        }
                    },
                    onSent: { withAnimation { proxy.scrollTo(bottomId, anchor: .bottom) } }
                )
            }
        }
        .navigationTitle(view.presentation.title ?? summary?.title ?? (isDraft ? "New session" : "Session"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(view: view, summary: summary, isDraft: isDraft) }
        .sheet(item: dialogBinding(view)) { request in
            DialogSheet(request: request) { answer in
                model.client.answerDialog(
                    sessionId, requestId: request.id, value: answer.value, confirmed: answer.confirmed,
                    cancelled: answer.cancelled
                )
            }
        }
        .sheet(item: $picker) { picker in
            NavigationStack {
                switch picker {
                case .model: ModelPicker(sessionId: sessionId)
                case .thinking: ThinkingPicker(sessionId: sessionId)
                }
            }
            .presentationDetents([.medium, .large])
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
            if showStats { model.client.requestStats(sessionId) }
            model.reportActivity()
        }
        .onDisappear {
            if !isDraft { model.client.unwatch(sessionId) }
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
            // Dismissing by swipe is an answer too: the agent is blocked.
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
    private func toolbar(view: SessionView, summary: SessionSummary?, isDraft: Bool) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button { picker = .model } label: {
                    Label(summary?.model?.name ?? "Model", systemImage: "cpu")
                }
                if !(summary?.thinkingLevels.isEmpty ?? true) {
                    Button { picker = .thinking } label: {
                        Label("Thinking: \(summary?.thinkingLevel ?? "default")", systemImage: "brain")
                    }
                }
                if !isDraft {
                    Divider()
                    Button { newName = summary?.name ?? ""; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                    Button { compactNote = ""; compacting = true } label: {
                        Label("Compact", systemImage: "rectangle.compress.vertical")
                    }
                    if let text = view.lastAssistantText {
                        Button { UIPasteboard.general.string = text; model.toast = "Copied last reply" } label: {
                            Label("Copy last reply", systemImage: "doc.on.doc")
                        }
                    }
                    Button { showInfo = true } label: { Label("Session info", systemImage: "info.circle") }
                    Button { model.client.reload(sessionId) } label: {
                        Label("Reload extensions", systemImage: "arrow.clockwise")
                    }
                    .disabled(view.running)
                    Button { model.client.exportSession(sessionId) } label: {
                        Label("Export HTML", systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

enum SessionPicker: String, Identifiable {
    case model, thinking
    var id: String { rawValue }
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

struct DraftIntro: View {
    let cwd: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New session").font(.headline)
            Label(collapseHome(cwd), systemImage: "folder").font(.subheadline).foregroundStyle(.secondary)
            Text("The session starts with your first prompt.").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
    }
}

struct WorkingIndicator: View {
    let interrupting: Bool
    let blocked: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(blocked ? "Waiting for your answer" : interrupting ? "Stopping..." : "Working...")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct StatsFooter: View {
    let stats: SessionStats

    var body: some View {
        HStack(spacing: 12) {
            if let percent = stats.contextPercent {
                Label("\(Int(percent.rounded()))% context", systemImage: "gauge.with.dots.needle.33percent")
            }
            if let total = stats.tokensTotal { Label(compactNumber(total), systemImage: "number") }
            if let cost = stats.cost, cost > 0 { Label(String(format: "$%.2f", cost), systemImage: "dollarsign.circle") }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

func compactNumber(_ value: Double) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
    return String(Int(value))
}
