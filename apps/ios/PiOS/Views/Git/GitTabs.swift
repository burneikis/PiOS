import PiOSCore
import SwiftUI

/// The working tree: the commit that ends it, then what is staged and what
/// is not. The message sits above the list because it is what Commit acts
/// on, and a long list must not push the two apart.
struct ChangesTab: View {
    @Bindable var git: GitModel
    let status: GitStatus
    let run: (GitAction) -> Void

    var body: some View {
        let staged = status.files.filter(\.isStaged)
        let changed = status.files.filter { !$0.isStaged }
        let canCommit = (status.staged > 0 || git.amend) && (!git.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || git.amend)

        List {
            Section {
                TextField(git.amend ? "Amend message (blank keeps the old one)" : "Commit message", text: $git.commitMessage, axis: .vertical)
                    .lineLimit(2 ... 6)
                    .font(.system(size: 14))
                HStack {
                    Toggle("Amend", isOn: $git.amend).toggleStyle(.button).font(.system(size: 13))
                    Spacer()
                    Button("Stage all") { run(.stageAll) }
                        .glassButton()
                        .disabled(git.busy || status.staged + status.unstaged + status.untracked == 0)
                    Button(git.pending?.kind == "commit" ? "Committing..." : "Commit") {
                        run(.commit(message: git.commitMessage, amend: git.amend))
                    }
                    .primaryButton()
                    .disabled(git.busy || !canCommit)
                }
                .font(.system(size: 13))
            } footer: {
                Text(status.summary)
            }
            .listRowBackground(Theme.panel)

            Section {
                if staged.isEmpty { empty("Nothing staged.") }
                ForEach(staged, id: \.path) { file in
                    NavigationLink(value: GitDetailView.Subject.file(path: file.path, staged: true)) { FileRowView(file: file) }
                        .swipeActions {
                            Button("Unstage") { run(.unstage([file.path])) }.tint(Theme.muted)
                        }
                }
            } header: {
                sectionHeader("Staged (\(staged.count))", action: staged.isEmpty ? nil : ("Unstage all", { run(.unstageAll) }))
            }
            .listRowBackground(Theme.panel)

            Section {
                if changed.isEmpty { empty("Working tree clean.") }
                ForEach(changed, id: \.path) { file in
                    NavigationLink(value: GitDetailView.Subject.file(path: file.path, staged: false)) { FileRowView(file: file) }
                        .swipeActions {
                            Button("Stage") { run(.stage([file.path])) }.tint(Theme.ok)
                            if file.unmerged != true {
                                Button("Discard", role: .destructive) { run(.discard([file.path])) }
                            }
                        }
                        .contextMenu {
                            Button { run(.stage([file.path])) } label: { Label("Stage", systemImage: "plus") }
                            if file.unmerged != true {
                                Button(role: .destructive) { run(.discard([file.path])) } label: { Label("Discard", systemImage: "trash") }
                            }
                        }
                }
                if status.truncated { empty("Too many changes to list; the counts are exact.") }
            } header: {
                sectionHeader(
                    "Changes (\(changed.count))",
                    action: changed.isEmpty || status.operation != nil ? nil : ("Stash all", { run(.stash(message: nil)) })
                )
            }
            .listRowBackground(Theme.panel)
        }
        .themedList()
        .disabled(git.busy && git.pending?.isRemote == false)
    }
}

/// A file in the working tree: the one-letter mark, then the path.
struct FileRowView: View {
    let file: GitFile

    var body: some View {
        let mark = file.mark
        HStack(spacing: 10) {
            Text(mark.mark)
                .font(Theme.mono(13).weight(.semibold))
                .foregroundStyle(color(mark.tone))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text((file.path as NSString).lastPathComponent).font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(1)
                let dir = (file.path as NSString).deletingLastPathComponent
                if !dir.isEmpty || file.from != nil {
                    Text(file.from.map { "from \($0)" } ?? dir)
                        .font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.head)
                }
            }
        }
    }

    private func color(_ tone: GitFile.Tone) -> Color {
        switch tone {
        case .add: return Theme.ok
        case .remove, .warn: return Theme.error
        case .muted: return Theme.muted
        }
    }
}

/// Commits, newest first, paged as they scroll into view.
struct HistoryTab: View {
    let git: GitModel
    @State private var commits: [GitLogEntry] = []
    @State private var done = false
    @State private var error: String? = nil
    @State private var loading = false

    var body: some View {
        List {
            if let error { empty(error, color: Theme.error) }
            ForEach(commits) { commit in
                NavigationLink(value: GitDetailView.Subject.commit(commit)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(commit.subject.isEmpty ? "(no subject)" : commit.subject)
                            .font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(2)
                        HStack(spacing: 6) {
                            Text(String(commit.sha.prefix(7))).font(Theme.mono(11))
                            Text("\(commit.author) \u{00B7} \(listTime(commit.at))").lineLimit(1)
                        }
                        .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        if !commit.refs.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(commit.refs, id: \.self) { ref in
                                    Text(ref)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.muted)
                                        .padding(.horizontal, 6)
                                        .overlay(Capsule().strokeBorder(Theme.line))
                                }
                            }
                        }
                    }
                }
                .onAppear { if commit.id == commits.last?.id { Task { await more() } } }
            }
            if loading { HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear) }
            if done, commits.isEmpty { empty("No commits yet.") }
        }
        .listRowBackground(Theme.panel)
        .themedList()
        .task(id: git.status?.head) {
            commits = []
            done = false
            await more()
        }
        .refreshable {
            commits = []
            done = false
            await more()
        }
    }

    private func more() async {
        guard !done, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await git.log(skip: commits.count)
            commits += page
            done = page.isEmpty
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Branches, local first. A tap opens a native menu of verbs rather than
/// switching at once: a checkout is one mis-tap from moving the agent's
/// tree under it.
struct BranchesTab: View {
    let git: GitModel
    let run: (GitAction) -> Void
    @State private var data: GitBranches? = nil
    @State private var error: String? = nil
    @State private var filter = ""
    @State private var creating = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("New branch from HEAD", text: $creating)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(create)
                    Button(action: create) { Image(systemName: "plus") }
                        .disabled(git.busy || creating.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .listRowBackground(Theme.panel)

            if let error { empty(error, color: Theme.error) }
            if let data {
                let local = match(data.local)
                let remote = match(data.remote)
                Section("Local (\(local.count))") {
                    ForEach(local) { branch in row(branch, data: data) }
                }
                .listRowBackground(Theme.panel)
                if !data.remote.isEmpty {
                    Section("Remote (\(remote.count))") {
                        ForEach(remote) { branch in row(branch, data: data) }
                    }
                    .listRowBackground(Theme.panel)
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .themedList()
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter branches")
        .task(id: "\(git.status?.branch ?? ""):\(git.status?.head ?? "")") { await load() }
        .refreshable { await load() }
    }

    private func match(_ list: [GitBranch]) -> [GitBranch] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? list : list.filter { $0.name.lowercased().contains(needle) }
    }

    private func row(_ branch: GitBranch, data: GitBranches) -> some View {
        Menu {
            if !branch.current {
                Button { checkout(branch, data: data) } label: { Label("Checkout", systemImage: "arrow.uturn.right") }
                Button { run(.merge(branch: branch.name)) } label: {
                    Label("Merge into \(data.current ?? "HEAD")", systemImage: "arrow.triangle.merge")
                }
                if !branch.remote {
                    Button(role: .destructive) { run(.deleteBranch(branch: branch.name, force: false)) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } else {
                Text("Current branch")
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if branch.current { Circle().fill(Theme.ok).frame(width: 6, height: 6) }
                    Text(branch.name).font(.system(size: 14)).foregroundStyle(branch.current ? Theme.text : Theme.text.opacity(0.9)).lineLimit(1)
                    if branch.behind > 0 { Text("\u{2193}\(branch.behind)").foregroundStyle(Theme.muted) }
                    if branch.ahead > 0 { Text("\u{2191}\(branch.ahead)").foregroundStyle(Theme.muted) }
                    if branch.gone { Text("gone").foregroundStyle(Theme.warn) }
                }
                .font(.system(size: 11).monospacedDigit())
                HStack(spacing: 6) {
                    Text(String(branch.sha.prefix(7))).font(Theme.mono(11))
                    Text("\(branch.subject.isEmpty ? "no subject" : branch.subject) \u{00B7} \(listTime(branch.at))").lineLimit(1)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(git.busy)
    }

    /// A remote branch is checked out as a local one that tracks it.
    private func checkout(_ branch: GitBranch, data: GitBranches) {
        guard branch.remote else { return run(.checkout(branch: branch.name, create: false, from: nil)) }
        let short = branch.name.split(separator: "/").dropFirst().joined(separator: "/")
        let exists = data.local.contains { $0.name == short }
        run(exists ? .checkout(branch: short, create: false, from: nil) : .checkout(branch: short, create: true, from: branch.name))
    }

    private func create() {
        let name = creating.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        run(.checkout(branch: name, create: true, from: nil))
        creating = ""
    }

    private func load() async {
        do {
            data = try await git.branches()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct StashesTab: View {
    let git: GitModel
    let run: (GitAction) -> Void
    @State private var stashes: [GitStash]? = nil
    @State private var error: String? = nil

    var body: some View {
        List {
            if let error { empty(error, color: Theme.error) }
            if let stashes {
                if stashes.isEmpty { empty("No stashes.") }
                ForEach(stashes) { stash in
                    NavigationLink(value: GitDetailView.Subject.stash(stash)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(stash.title).font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(2)
                            Text("\(stash.ref)\(stash.branch.map { " \u{00B7} on \($0)" } ?? "") \u{00B7} \(listTime(stash.at))")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    .swipeActions {
                        Button("Drop", role: .destructive) { run(.stashDrop(ref: stash.ref)) }
                        Button("Pop") { run(.stashPop(ref: stash.ref)) }.tint(Theme.ok)
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .listRowBackground(Theme.panel)
        .themedList()
        .task(id: git.status?.stashes) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            stashes = try await git.stashes()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Muted copy where a list has nothing to show.
func empty(_ text: String, color: Color = Theme.muted) -> some View {
    Text(text)
        .font(.system(size: 12.5))
        .foregroundStyle(color)
        .listRowBackground(Color.clear)
}

/// A section title with its secondary verb on the trailing edge.
func sectionHeader(_ title: String, action: (String, () -> Void)?) -> some View {
    HStack {
        Text(title)
        Spacer()
        if let action {
            Button(action.0, action: action.1)
                .font(.system(size: 12))
                .textCase(nil)
                .foregroundStyle(Theme.text)
        }
    }
}
