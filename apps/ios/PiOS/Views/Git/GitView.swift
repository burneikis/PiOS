import PiOSCore
import SwiftUI

/// The chat header's git affordance: counts and any operation in progress.
/// Always present: a chip that comes and goes reads as a bug.
struct GitChip: View {
    let git: GitModel
    let open: () -> Void

    var body: some View {
        let chip = git.status?.chip
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 12))
                if let op = chip?.operation {
                    Text(op).foregroundStyle(Theme.warn)
                }
                if let counts = chip?.counts, !counts.isEmpty {
                    Text(counts).monospacedDigit()
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            .opacity(git.stale ? 0.55 : 1)
        }
        .accessibilityLabel(git.status?.branch.map { "git, on \($0)" } ?? "git")
    }
}

enum GitTab: String, CaseIterable, Identifiable {
    case changes, history, branches, stashes
    var id: String { rawValue }
}

/// Asks before anything destructive, then runs it.
struct GitConfirmation: ViewModifier {
    @Binding var action: GitAction?
    let git: GitModel
    var onDone: (GitAction, Bool) -> Void = { _, _ in }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            action?.confirmation ?? "",
            isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }),
            titleVisibility: .visible,
            presenting: action
        ) { pending in
            Button(pending.confirmLabel, role: .destructive) { run(pending) }
            if case let .deleteBranch(branch, false) = pending {
                Button("Force delete", role: .destructive) { run(.deleteBranch(branch: branch, force: true)) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func run(_ pending: GitAction) {
        Task { onDone(pending, await git.perform(pending)) }
    }
}

extension View {
    func gitConfirmation(_ action: Binding<GitAction?>, git: GitModel, onDone: @escaping (GitAction, Bool) -> Void = { _, _ in }) -> some View {
        modifier(GitConfirmation(action: action, git: git, onDone: onDone))
    }
}

/// Git's refusal and its output, as status lines, with the one action that
/// would clear a refusal when there is one.
struct GitMessages: View {
    let git: GitModel
    var run: (GitAction) -> Void

    var body: some View {
        if let error = git.error {
            StatusLine(text: error, tone: .error) {
                if let recovery = GitAction.recovery(for: error) {
                    Button(recovery.label) { run(recovery.action) }.disabled(git.busy)
                }
                Button { git.error = nil } label: { Image(systemName: "xmark") }
            }
        }
        if let notice = git.notice {
            StatusLine(text: notice) {
                Button { git.notice = nil } label: { Image(systemName: "xmark") }
            }
        }
    }
}

/// The whole git surface for the session's directory: working tree, history,
/// branches, stashes and the remote. A screen of its own, as in the PWA: a
/// diff needs the width, a commit message the keyboard.
struct GitView: View {
    let git: GitModel
    @State private var tab: GitTab = .changes
    @State private var confirming: GitAction? = nil

    var body: some View {
        Group {
            if let status = git.status {
                VStack(spacing: 8) {
                    VStack(spacing: 8) {
                        SyncBar(status: status, git: git, run: run)
                        if let operation = status.operation {
                            StatusLine(
                                text: "A \(operation) is in progress." + (status.conflicted > 0
                                    ? " Resolve the conflicts, stage them, then continue."
                                    : " Continue it or throw it away."),
                                tone: .warn
                            ) {
                                Button("Abort") { run(.abort) }.disabled(git.busy)
                                Button("Continue") { run(.continue) }.disabled(git.busy || status.conflicted > 0)
                            }
                        }
                        GitMessages(git: git, run: run)
                        Picker("Section", selection: $tab) {
                            ForEach(GitTab.allCases) { tab in Text(label(tab, status)).tag(tab) }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.horizontal, 16)

                    switch tab {
                    case .changes: ChangesTab(git: git, status: status, run: run)
                    case .history: HistoryTab(git: git)
                    case .branches: BranchesTab(git: git, run: run)
                    case .stashes: StashesTab(git: git, run: run)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    GitMessages(git: git, run: run)
                    Text(git.loading ? "Reading..." : "This directory is not a git repository.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                    if !git.loading, git.missing {
                        Button("Initialize repository") { run(.initialize) }
                            .primaryButton()
                            .disabled(git.busy)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bg)
        .navigationTitle(git.status.map { $0.branch ?? "detached at \($0.head ?? "?")" } ?? "Git")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if git.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await git.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .gitConfirmation($confirming, git: git)
        .task { await git.refresh() }
    }

    /// Everything the tabs trigger comes through here, so a confirmation
    /// cannot be skipped.
    private func run(_ action: GitAction) {
        if action.confirmation != nil {
            confirming = action
            return
        }
        Task { await git.perform(action) }
    }

    private func label(_ tab: GitTab, _ status: GitStatus) -> String {
        let name = tab.rawValue.capitalized
        let count = tab == .changes ? status.changedCount : tab == .stashes ? status.stashes : 0
        return count > 0 ? "\(name) \(count)" : name
    }
}

/// Fetch, pull and push, and what each would do. Counts come from local
/// refs, so fetch sits beside them; the variants are one tap away in a menu
/// because the plain form is right nearly always.
struct SyncBar: View {
    let status: GitStatus
    let git: GitModel
    let run: (GitAction) -> Void

    var body: some View {
        if status.remotes.isEmpty {
            Text("No remote configured.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let ahead = status.upstream?.ahead ?? 0
            let behind = status.upstream?.behind ?? 0
            let publish = status.upstream == nil
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    syncButton(pendingKind("fetch") ? "Fetching..." : "Fetch", "arrow.clockwise") { run(.fetch(prune: false)) }
                    syncButton(pendingKind("pull") ? "Pulling..." : behind > 0 ? "Pull \(behind)" : "Pull", "arrow.down") {
                        run(.pull(rebase: false))
                    }
                    .disabled(publish || behind == 0)
                    syncButton(pendingKind("push") ? "Pushing..." : publish ? "Publish" : "Push \(ahead)", "arrow.up") {
                        run(.push(force: false, setUpstream: publish))
                    }
                    .disabled(!publish && ahead == 0)
                    Menu {
                        Button { run(.fetch(prune: true)) } label: { Label("Fetch and prune", systemImage: "scissors") }
                        Button { run(.pull(rebase: true)) } label: { Label("Pull with rebase", systemImage: "arrow.triangle.merge") }
                            .disabled(publish)
                        Button(role: .destructive) { run(.push(force: true, setUpstream: false)) } label: {
                            Label("Force push", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        }
                        .disabled(publish)
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 32, height: 32)
                    }
                    .foregroundStyle(Theme.muted)
                }
                .disabled(git.busy)
                Text(status.upstream.map { "\($0.name) \u{00B7} \u{2191}\(ahead) \u{2193}\(behind)" }
                    ?? "No upstream \u{00B7} publishing goes to \(status.defaultRemote ?? "the remote")")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
    }

    private func pendingKind(_ kind: String) -> Bool { git.pending?.kind == kind }

    private func syncButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .glassButton()
    }
}

/// A unified diff, as the transcript draws one: coloured lines in a well,
/// scrolling sideways rather than folding.
struct PatchView: View {
    let patch: String

    var body: some View {
        let lines = patchLines(patch)
        if lines.isEmpty {
            Text("No changes to show.").font(.system(size: 13)).foregroundStyle(Theme.muted)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                // Not lazy: a lazy stack offers each line the visible width,
                // which wraps it instead of scrolling it.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(color(line.kind))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .font(Theme.mono(11.5))
                .lineSpacing(2)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
        }
    }

    private func color(_ kind: PatchLine.Kind) -> Color {
        switch kind {
        case .add: return Theme.ok
        case .remove: return Theme.error
        case .meta: return Theme.muted
        case .same: return Theme.text
        }
    }
}

/// One patch, full width: a file's carries the verb that moves it between
/// tree and index; a stash's carries pop, apply and drop.
struct GitDetailView: View {
    enum Subject: Hashable {
        case file(path: String, staged: Bool)
        case commit(GitLogEntry)
        case stash(GitStash)
    }

    let git: GitModel
    let subject: Subject
    @Environment(\.dismiss) private var dismiss
    @State private var patch: String? = nil
    @State private var error: String? = nil
    @State private var confirming: GitAction? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                GitMessages(git: git, run: run)
                Text(summary).font(.system(size: 12.5)).foregroundStyle(Theme.muted).textSelection(.enabled)
                if let error {
                    Text(error).font(.system(size: 13)).foregroundStyle(Theme.error)
                } else if let patch {
                    PatchView(patch: patch)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .gitConfirmation($confirming, git: git) { _, ok in if ok { dismiss() } }
        .task(id: subject) { await load() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            switch subject {
            case let .file(path, staged):
                Button(staged ? "Unstage" : "Stage") { run(staged ? .unstage([path]) : .stage([path])) }
                    .disabled(git.busy)
            case let .stash(stash):
                Menu {
                    Button { run(.stashPop(ref: stash.ref)) } label: { Label("Pop", systemImage: "tray.and.arrow.up") }
                    Button { run(.stashApply(ref: stash.ref)) } label: { Label("Apply", systemImage: "doc.on.doc") }
                    Button(role: .destructive) { run(.stashDrop(ref: stash.ref)) } label: { Label("Drop", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .disabled(git.busy)
            case .commit:
                EmptyView()
            }
        }
    }

    private var title: String {
        switch subject {
        case let .file(path, _): return (path as NSString).lastPathComponent
        case let .commit(commit): return commit.subject
        case let .stash(stash): return stash.title
        }
    }

    private var summary: String {
        switch subject {
        case let .file(path, staged): return "\(path) \u{00B7} \(staged ? "staged changes" : "working tree changes")"
        case let .commit(commit): return "\(commit.sha) \u{00B7} \(commit.author) \u{00B7} \(listTime(commit.at))"
        case let .stash(stash): return stash.branch.map { "\(stash.ref) \u{00B7} on \($0)" } ?? stash.ref
        }
    }

    private func load() async {
        let diff: MachineAPI.DiffSubject
        switch subject {
        case let .file(path, staged): diff = .file(path: path, staged: staged)
        case let .commit(commit): diff = .commit(commit.sha)
        case let .stash(stash): diff = .stash(stash.ref)
        }
        do {
            patch = try await git.diff(diff)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func run(_ action: GitAction) {
        if action.confirmation != nil {
            confirming = action
            return
        }
        Task { if await git.perform(action) { dismiss() } }
    }
}
