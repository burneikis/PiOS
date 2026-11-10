import Foundation
import Observation
import PiOSCore

/// Git state for one session's working directory.
///
/// Polled on demand rather than pushed: it is ambient state of a directory,
/// not conversation state, so it must not ride the entry stream whose ids
/// are the resync cursor. The chat re-reads it when a turn settles, which is
/// when the agent has stopped writing files.
@Observable
@MainActor
final class GitModel {
    /// Last status read, kept across a failed refresh so the chip never blanks.
    private(set) var status: GitStatus?
    /// The daemon answered, and the directory is not a repository.
    private(set) var missing = false
    /// Showing an older read because the last one failed.
    private(set) var stale = false
    private(set) var loading = true
    var error: String?
    /// Git's own output from the last remote operation.
    var notice: String?
    /// The running action, so a button can show where the wait is.
    private(set) var pending: GitAction?
    /// The commit being written, kept across tabs, diffs and leaving the view.
    var commitMessage = ""
    var amend = false

    @ObservationIgnored private let api: () -> MachineAPI?
    @ObservationIgnored let project: Project
    /// Reads started before a refresh must not overwrite the newer answer.
    @ObservationIgnored private var generation = 0

    init(project: Project, api: @escaping () -> MachineAPI?) {
        self.project = project
        self.api = api
    }

    var busy: Bool { pending != nil }

    func refresh(fresh: Bool = true) async {
        guard let api = api() else { return }
        generation += 1
        let mine = generation
        loading = true
        defer { if generation == mine { loading = false } }
        do {
            let next = try await api.gitStatus(project, fresh: fresh)
            guard generation == mine else { return }
            status = next
            missing = next == nil
            stale = false
            error = nil
        } catch {
            guard generation == mine else { return }
            // A dropped request says nothing about the tree; keep the counts.
            stale = true
            self.error = error.localizedDescription
        }
    }

    /// Runs an action without asking. Callers go through the view's `run`,
    /// which asks first for anything destructive.
    @discardableResult
    func perform(_ action: GitAction) async -> Bool {
        guard let api = api() else { return false }
        pending = action
        error = nil
        notice = nil
        defer { pending = nil }
        do {
            let result = try await api.gitAction(project, action)
            generation += 1
            status = result.status
            missing = result.status == nil
            stale = false
            if action.isRemote, !result.output.isEmpty { notice = result.output }
            if case .commit = action {
                commitMessage = ""
                amend = false
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func diff(_ subject: MachineAPI.DiffSubject) async throws -> String {
        guard let api = api() else { return "" }
        return try await api.gitDiff(project, subject)
    }

    func log(skip: Int) async throws -> [GitLogEntry] {
        guard let api = api() else { return [] }
        return try await api.gitLog(project, skip: skip)
    }

    func branches() async throws -> GitBranches? {
        guard let api = api() else { return nil }
        return try await api.gitBranches(project)
    }

    func stashes() async throws -> [GitStash] {
        guard let api = api() else { return [] }
        return try await api.gitStashes(project)
    }
}
