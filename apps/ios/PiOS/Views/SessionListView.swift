import PiOSCore
import SwiftUI
import UIKit

/// Every session in pi's store, the TUI's included, newest user activity
/// first. Paged and searched on the daemon: past the first page the rows are
/// not on this phone to filter.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var renaming: SessionSummary?
    @State private var newName = ""

    private static let page = 50

    var body: some View {
        NavigationStack {
            List {
                let drafts = model.drafts.values.sorted { $0.sessionId > $1.sessionId }
                if query.isEmpty {
                    ForEach(drafts, id: \.sessionId) { draft in
                        row(id: draft.sessionId) {
                            SessionRow(title: "New session", subtitle: shortPath(draft.cwd), state: SessionState(tone: .cold, label: "draft"))
                        }
                        .swipeActions { Button("Discard", role: .destructive) { model.discardDraft(draft.sessionId) } }
                    }
                }

                ForEach(model.sessionList) { session in
                    row(id: session.sessionId) {
                        SessionRow(
                            title: session.name ?? session.preview.map(previewText) ?? shortPath(session.cwd),
                            subtitle: "\(shortPath(session.cwd)) · \(listTime(session.sortKey))",
                            state: .of(session, unseen: model.isUnseen(session))
                        )
                    }
                    .contextMenu {
                        Button { newName = session.name ?? ""; renaming = session } label: { Label("Rename", systemImage: "pencil") }
                        Button { model.pickerStart = session.cwd } label: { Label("New session here", systemImage: "plus") }
                        Button { UIPasteboard.general.string = session.cwd } label: { Label("Copy path", systemImage: "doc.on.doc") }
                    }
                    .onAppear { loadMoreIfLast(session) }
                }

                if model.connection.hasMoreSessions {
                    Text("Loading more...")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .onAppear { loadMore() }
                } else if model.sessionList.isEmpty, model.drafts.isEmpty {
                    Text(model.connection.transport == .connected ? "No sessions yet." : "Loading sessions...")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .themedList()
            .navigationTitle("Sessions")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search sessions")
            .refreshable { model.client.refreshSessions() }
            .task(id: query) {
                // Debounced: a keystroke per round trip over a relay is wasteful.
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                model.client.listSessions(ListQuery(query: query.isEmpty ? nil : query, limit: Self.page))
            }
            .toolbar {
                // Machine and link state are one subject, so one control.
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.showSettings = true } label: {
                        HStack(spacing: 8) {
                            Circle().fill(dotColor).frame(width: 9, height: 9)
                            Text(model.activeMachine?.label ?? "PiOS")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                        }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { model.showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    Button { model.pickerStart = "" } label: { Image(systemName: "plus") }
                }
            }
            .alert("Rename session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    if let session = renaming, !name.isEmpty { model.client.setSessionName(session.sessionId, name) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    private func row<Content: View>(id: String, @ViewBuilder content: () -> Content) -> some View {
        let active = model.selection == id
        return Button { model.open(id) } label: { content() }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? Theme.raised : .clear)
                    .padding(.horizontal, 6)
            )
    }

    private var dotColor: Color {
        switch model.connection.transport {
        case .connected: return Theme.ok
        case .connecting, .waiting: return Theme.warn
        case .blocked, .offline: return Theme.error
        case .idle: return Theme.muted
        }
    }

    private func loadMoreIfLast(_ session: SessionSummary) {
        if session.sessionId == model.sessionList.last?.sessionId { loadMore() }
    }

    private func loadMore() {
        guard model.connection.hasMoreSessions else { return }
        model.client.listSessions(
            ListQuery(query: query.isEmpty ? nil : query, limit: Self.page, offset: model.connection.sessions.count)
        )
    }
}

/// Two lines and a badge in the corner, so no row grows a third line.
struct SessionRow: View {
    let title: String
    let subtitle: String
    let state: SessionState

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            Badge(state: state).padding(.top, 2)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

/// Transport health as a status line. Never inferred from cached rows.
struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.connection
        if let info = describe(state) {
            StatusLine(text: info.text, tone: info.tone) {
                if state.transport == .blocked {
                    Button("Pair") { model.showPairing = true }
                } else if state.transport == .waiting {
                    Button("Retry") { model.client.supervisor.wake("manual retry") }
                }
            }
        }
    }

    private func describe(_ state: SupervisorState) -> (text: String, tone: StatusLine.Tone)? {
        switch state.transport {
        case .connected: return state.sync == .error ? ("Connected, but out of sync.", .warn) : nil
        case .offline: return ("Offline. Prompts wait in the outbox.", .warn)
        case .connecting: return ("Connecting...", .muted)
        case .waiting:
            return state.hostOffline ? ("Machine offline.", .warn) : ("Reconnecting (\(state.reason ?? "lost")).", .warn)
        case .blocked: return ("Blocked: \(state.reason ?? "unknown").", .error)
        case .idle: return nil
        }
    }
}

/// The PWA's `.banner`: a status line, not a panel. The tone is in the text.
struct StatusLine<Actions: View>: View {
    enum Tone { case muted, warn, error }
    let text: String
    var tone: Tone = .muted
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
                .font(.system(size: 13))
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassSurface(cornerRadius: 10)
    }

    private var color: Color {
        switch tone {
        case .muted: return Theme.muted
        case .warn: return Theme.warn
        case .error: return Theme.error
        }
    }
}

extension StatusLine where Actions == EmptyView {
    init(text: String, tone: Tone = .muted) {
        self.init(text: text, tone: tone) { EmptyView() }
    }
}
