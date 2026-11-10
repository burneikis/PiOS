import PiOSCore
import SwiftUI

/// Every session in pi's store, the TUI's included, newest user activity
/// first. Paged and searched on the daemon: past the first page the rows are
/// not on this phone to filter.
struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var picking = false
    @State private var settings = false

    private static let page = 50

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ConnectionBanner()

            let drafts = model.drafts.values.sorted { $0.sessionId < $1.sessionId }
            if !drafts.isEmpty, query.isEmpty {
                Section("Drafts") {
                    ForEach(drafts, id: \.sessionId) { draft in
                        DraftRow(draft: draft)
                            .tag(draft.sessionId)
                            .swipeActions { Button("Discard", role: .destructive) { model.discardDraft(draft.sessionId) } }
                    }
                }
            }

            Section {
                ForEach(model.sessionList) { session in
                    SessionRow(session: session)
                        .tag(session.sessionId)
                        .onAppear { loadMoreIfLast(session) }
                }
                if model.connection.hasMoreSessions {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .onAppear { loadMore() }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(model.activeMachine?.label ?? "Sessions")
        .searchable(text: $query, prompt: "Path, name or first message")
        .task(id: query) {
            // Debounced: a keystroke per round trip over a relay is wasteful.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            model.client.listSessions(ListQuery(query: query.isEmpty ? nil : query, limit: Self.page))
        }
        .refreshable { model.client.refreshSessions() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { settings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { picking = true } label: { Image(systemName: "square.and.pencil") }
            }
        }
        .sheet(isPresented: $picking) {
            NavigationStack { DirectoryPicker() }
        }
        .sheet(isPresented: $settings) {
            NavigationStack { SettingsView() }
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

struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(status: session.status, awaitingInput: session.awaitingInput)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.body)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(collapseHome(session.cwd))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 4)
                    Text(relativeTime(session.sortKey))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct DraftRow: View {
    let draft: Draft

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("New session").italic()
            Text(collapseHome(draft.cwd)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct StatusDot: View {
    let status: SessionSummary.Status?
    var awaitingInput = false

    var body: some View {
        Group {
            if awaitingInput {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
            } else {
                switch status {
                case .running: ProgressView().controlSize(.mini)
                case .crashed: Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                case .idle: Circle().fill(.green).frame(width: 8, height: 8)
                default: Circle().strokeBorder(.secondary.opacity(0.5)).frame(width: 8, height: 8)
                }
            }
        }
        .font(.caption)
        .frame(width: 14, height: 14)
    }
}

/// Transport health, said out loud. Never inferred from cached rows.
struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.connection
        if let info = describe(state) {
            HStack(spacing: 8) {
                Image(systemName: info.icon).foregroundStyle(info.tint)
                Text(info.text).font(.footnote)
                Spacer()
                if state.transport == .blocked {
                    Button("Pair") { model.showPairing = true }.font(.footnote)
                } else if state.transport == .waiting {
                    Button("Retry") { model.client.supervisor.wake("manual retry") }.font(.footnote)
                }
            }
        }
    }

    private func describe(_ state: SupervisorState) -> (text: String, icon: String, tint: Color)? {
        switch state.transport {
        case .connected:
            return state.sync == .error ? ("Connected, out of sync", "arrow.triangle.2.circlepath", .orange) : nil
        case .offline: return ("Offline. Prompts wait in the outbox.", "wifi.slash", .secondary)
        case .connecting: return ("Connecting...", "antenna.radiowaves.left.and.right", .secondary)
        case .waiting:
            return state.hostOffline
                ? ("Machine offline", "desktopcomputer.trianglebadge.exclamationmark", .orange)
                : ("Reconnecting (\(state.reason ?? "lost"))", "arrow.clockwise", .orange)
        case .blocked: return ("Blocked: \(state.reason ?? "unknown")", "lock.slash", .red)
        case .idle: return nil
        }
    }
}

func relativeTime(_ ms: Double) -> String {
    guard ms > 0 else { return "" }
    let date = Date(timeIntervalSince1970: ms / 1000)
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}
