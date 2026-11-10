import Foundation
import Network
import Observation
import PiOSCore
import SwiftUI

/// A session that exists only on this phone: a composer with no prompt sent.
/// Its id is the one the first prompt will create the session under.
struct Draft: Codable, Hashable {
    var sessionId: String
    var cwd: String
    var trustProject: Bool
}

/// The one object views observe.
///
/// It owns the single `PiosClient` for the app's lifetime, because the client
/// owns the only retry ladder and the outbox; rebuilding it on a machine
/// switch would drop queued prompts. Views read state here and call intents
/// on the client; they never see a socket.
@Observable
@MainActor
final class AppModel {
    let client: PiosClient
    @ObservationIgnored let storage: FileStorage

    private(set) var machines: MachineStore
    private(set) var connection: SupervisorState
    private(set) var outbox: [OutboxEntry]
    /// Bumped per session on any change; views read it to depend on it.
    private(set) var revisions: [String: Int] = [:]
    /// Models, commands and stats arrived.
    private(set) var metadataRevision = 0
    private(set) var drafts: [String: Draft] = [:]
    private(set) var selection: String?
    /// Screens pushed over the open chat. One typed path for the whole
    /// stack: mixing item-bound and value-bound destinations leaves SwiftUI
    /// popping the wrong screen. Belongs to the selection, so it resets
    /// with it.
    var path: [ChatRoute] = []
    /// The session list over the chat, on a narrow screen.
    var drawerOpen = false
    /// The docked list beside the chat, on a wide one.
    var sidebarVisible = true
    var showSettings = false
    /// Where the directory picker starts; non-nil shows it.
    var pickerStart: String?
    /// Last `updatedAt` seen per session, for the unread mark.
    private(set) var seen: [String: Double] = [:]
    var toast: String?
    /// A file fetched from the machine, waiting for the share sheet.
    var sharedFile: SharedFile?
    var showPairing = false
    var pairingNotice: String?
    /// A link that opened the app, waiting for the pairing sheet to claim it.
    var pendingPairingLink: String?
    /// Settle notifications through the daemon's inbox, for this device.
    private(set) var notificationsEnabled: Bool
    @ObservationIgnored let notifications: Notifications

    @ObservationIgnored private var gitModels: [Project: GitModel] = [:]
    @ObservationIgnored private var pendingRevisions: Set<String> = []
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var subscriptions: [Cancel] = []
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var composerTexts: [String: String]
    @ObservationIgnored private var scenePhase: ScenePhase = .active

    static let clientVersion: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return "ios-\(version)"
    }()

    init() {
        let storage = FileStorage()
        self.storage = storage
        client = PiosClient(createTransport: WebSocketTransport.factory, storage: storage, clientVersion: Self.clientVersion)
        machines = readVersioned(storage, MachineStore.key, version: MachineStore.version, fallback: MachineStore())
        drafts = readVersioned(storage, "pios.drafts", version: 1, fallback: [String: Draft]())
        composerTexts = readVersioned(storage, "pios.composer", version: 1, fallback: [String: String]())
        connection = client.supervisor.state
        outbox = client.outbox.entries
        notifications = Notifications(storage: storage)
        notificationsEnabled = readVersioned(storage, Self.notificationsKey, version: 1, fallback: false)
        notifications.model = self
        // Remembered by the client and re-sent on every connect.
        if notificationsEnabled { client.setNotifications(true) }

        subscriptions.append(client.supervisor.stateChanged.add { [weak self] state in self?.onConnection(state) })
        subscriptions.append(client.outbox.changed.add { [weak self] entries in self?.outbox = entries })
        subscriptions.append(client.sessions.changed.add { [weak self] sessionId in self?.markChanged(sessionId) })
        subscriptions.append(client.metadataChanged.add { [weak self] _ in self?.metadataRevision += 1 })
        subscriptions.append(client.notices.add { [weak self] notice in self?.onNotice(notice) })

        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.client.supervisor.setOnline(online) }
        }
        monitor.start(queue: DispatchQueue(label: "pios.network"))

        seen = readVersioned(storage, seenKey, version: 1, fallback: [String: Double]())
        connectActiveMachine()
        startActivityReports()
    }

    // MARK: Machines

    var activeMachine: Machine? { machines.active }

    var api: MachineAPI? {
        guard let machine = activeMachine else { return nil }
        return MachineAPI(base: machine.url, token: Keychain.token(for: machine.id))
    }

    var isPaired: Bool { activeMachine != nil }

    func pair(url: URL, pairingToken: String, label: String) async throws {
        let result = try await MachineAPI(base: url, token: nil).pair(pairingToken: pairingToken, label: label)
        Keychain.setToken(result.deviceToken, for: result.deviceId)
        let machine = Machine(id: result.deviceId, label: url.host ?? url.absoluteString, url: url)
        machines.machines.removeAll { $0.url == url }
        machines.machines.append(machine)
        machines.activeId = machine.id
        saveMachines()
        pairingNotice = nil
        showPairing = false
        connectActiveMachine()
    }

    func activate(_ machine: Machine) {
        machines.activeId = machine.id
        saveMachines()
        selection = nil
        path = []
        seen = readVersioned(storage, seenKey, version: 1, fallback: [String: Double]())
        connectActiveMachine()
    }

    /// Forgets a machine on this phone. The daemon keeps its device record
    /// until `pios-server revoke`, which is the side that matters.
    func forget(_ machine: Machine) {
        Keychain.removeToken(for: machine.id)
        machines.machines.removeAll { $0.id == machine.id }
        if machines.activeId == machine.id { machines.activeId = machines.machines.first?.id }
        saveMachines()
        selection = nil
        path = []
        connectActiveMachine()
    }

    private func saveMachines() {
        writeVersioned(storage, MachineStore.key, version: MachineStore.version, machines)
    }

    private func connectActiveMachine() {
        guard let machine = activeMachine, let url = machine.socketURL, let token = Keychain.token(for: machine.id) else {
            client.supervisor.setCredentials(nil)
            return
        }
        client.start(Credentials(url: url, deviceToken: token))
    }

    // MARK: Sessions

    /// Newest user activity first.
    var sessionList: [SessionSummary] {
        connection.sessions.sorted { $0.sortKey > $1.sortKey }
    }

    func summary(_ sessionId: String) -> SessionSummary? {
        connection.sessions.first { $0.sessionId == sessionId }
    }

    func revision(_ sessionId: String) -> Int { revisions[sessionId] ?? 0 }

    func view(_ sessionId: String) -> SessionView {
        _ = revision(sessionId)
        _ = outbox
        return client.view(sessionId)
    }

    func newDraft(cwd: String, trustProject: Bool) {
        let id = client.newSessionId()
        drafts[id] = Draft(sessionId: id, cwd: cwd, trustProject: trustProject)
        saveDrafts()
        open(id)
    }

    /// Opens a session; on a phone that also puts the list away.
    func open(_ sessionId: String?) {
        if sessionId != selection { path = [] }
        selection = sessionId
        drawerOpen = false
        if let sessionId { notifications.clear(sessionId: sessionId) }
        if let sessionId, let summary = summary(sessionId) { markSeen(summary) }
        reportActivity()
    }

    // MARK: Unread

    private var seenKey: String { "pios.seen.\(activeMachine?.id ?? "none")" }

    /// Finished while the user was elsewhere. A session never seen on this
    /// device is not unread: the first sync seeds every row as read.
    func isUnseen(_ summary: SessionSummary) -> Bool {
        guard let at = seen[summary.sessionId] else { return false }
        return at < summary.updatedAt
    }

    private func markSeen(_ summary: SessionSummary) {
        guard seen[summary.sessionId] != summary.updatedAt else { return }
        seen[summary.sessionId] = summary.updatedAt
        writeVersioned(storage, seenKey, version: 1, seen)
    }

    private func seedSeen(_ sessions: [SessionSummary]) {
        var changed = false
        for summary in sessions where seen[summary.sessionId] == nil {
            seen[summary.sessionId] = summary.updatedAt
            changed = true
        }
        if changed { writeVersioned(storage, seenKey, version: 1, seen) }
    }

    func draft(_ sessionId: String) -> Draft? { drafts[sessionId] }

    /// The draft's first prompt carries `create`; after that it is a session.
    func create(for sessionId: String) -> SessionCreate? {
        guard let draft = drafts[sessionId], summary(sessionId) == nil else { return nil }
        return SessionCreate(cwd: draft.cwd, trustProject: draft.trustProject)
    }

    func discardDraft(_ sessionId: String) {
        drafts[sessionId] = nil
        saveDrafts()
    }

    private func saveDrafts() {
        writeVersioned(storage, "pios.drafts", version: 1, drafts)
    }

    func composerText(_ sessionId: String) -> String { composerTexts[sessionId] ?? "" }

    func setComposerText(_ sessionId: String, _ text: String) {
        composerTexts[sessionId] = text.isEmpty ? nil : text
        writeVersioned(storage, "pios.composer", version: 1, composerTexts)
    }

    func send(sessionId: String, text: String, images: [ImageContent], behavior: StreamingBehavior?) {
        // The draft stays until the daemon lists the session: subscribing
        // before the outbox has delivered the creating prompt would fail.
        client.prompt(sessionId: sessionId, text: text, images: images, streamingBehavior: behavior, create: create(for: sessionId))
    }

    func cwd(_ sessionId: String) -> String? {
        summary(sessionId)?.cwd ?? drafts[sessionId]?.cwd
    }

    /// How HTTP routes address a session. A draft has no session the daemon
    /// knows yet, so it names its directory instead.
    func project(_ sessionId: String) -> Project {
        let isDraft = summary(sessionId) == nil && drafts[sessionId] != nil
        return Project(sessionId: sessionId, cwd: isDraft ? drafts[sessionId]?.cwd : nil)
    }

    /// Git state per project, kept while the app runs so the chip does not
    /// blank on every visit.
    func git(_ sessionId: String) -> GitModel {
        let key = project(sessionId)
        if let existing = gitModels[key] { return existing }
        let created = GitModel(project: key) { [weak self] in self?.api }
        gitModels[key] = created
        return created
    }

    /// Hands bytes from the machine to the system share sheet.
    func share(data: Data, named name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name.isEmpty ? "download" : name)
        do {
            try data.write(to: url, options: .atomic)
            sharedFile = SharedFile(url: url)
        } catch {
            toast = "Could not save \(name): \(error.localizedDescription)"
        }
    }

    /// pi wrote an export on the machine; one inside the project is fetched
    /// to this device, since this device asked for it.
    private func fetchExport(sessionId: String, path: String) {
        guard let cwd = cwd(sessionId), path.hasPrefix(cwd + "/"), let api else { return }
        Task {
            do {
                share(data: try await api.file(project(sessionId), path: path), named: (path as NSString).lastPathComponent)
            } catch {
                toast = "The export could not be downloaded: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Notifications

    private static let notificationsKey = "pios.notifications"

    /// Turning it on asks iOS first; a refusal leaves it off and says where
    /// to change that.
    func setNotificationsEnabled(_ enabled: Bool) async {
        if enabled, !(await notifications.requestAuthorization()) {
            toast = "Notifications are off for PiOS. Allow them in iOS Settings."
            return
        }
        notificationsEnabled = enabled
        writeVersioned(storage, Self.notificationsKey, version: 1, enabled)
        client.setNotifications(enabled)
        notifications.scheduleRefresh()
    }

    /// The session is on screen, so a notification about it says nothing.
    func isReading(_ sessionId: String?) -> Bool {
        scenePhase == .active && sessionId != nil && selection == sessionId
    }

    func openFromNotification(sessionId: String, machineId: String?) {
        if let machineId, !machineId.isEmpty, machineId != activeMachine?.id,
           let machine = machines.machines.first(where: { $0.id == machineId }) {
            activate(machine)
        }
        open(sessionId)
    }

    private func deliver(_ note: DeviceNotification) {
        let machineId = activeMachine?.id
        Task {
            if await notifications.show(note, machineId: machineId) { client.acknowledgeNotifications([note.id]) }
        }
    }

    /// A slot iOS granted while the app was away: reconnect, let the daemon
    /// hand over its inbox, and give the acks time to leave.
    func backgroundRefresh() async {
        notifications.scheduleRefresh()
        guard notificationsEnabled, isPaired else { return }
        client.supervisor.wake("background-refresh")
        var waited = 0
        while connection.transport != .connected, waited < 60 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            waited += 1
        }
        guard connection.transport == .connected else { return }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    // MARK: Lifecycle

    func setScenePhase(_ phase: ScenePhase) {
        scenePhase = phase
        switch phase {
        case .active:
            client.appState.set(.active)
            notifications.enteredForeground()
        case .inactive: client.appState.set(.inactive)
        case .background:
            client.appState.set(.background)
            notifications.enteredBackground()
        @unknown default: break
        }
        reportActivity()
    }

    func reportActivity() {
        let appState: AppState = scenePhase == .active ? .active : scenePhase == .inactive ? .inactive : .background
        client.reportActivity(
            visible: scenePhase != .background, focused: scenePhase == .active, appState: appState,
            sessionIds: selection.map { [$0] } ?? []
        )
    }

    /// The daemon skips a push for a session someone is already watching,
    /// which it learns from these. 25s against its 45s lease.
    private func startActivityReports() {
        activityTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                self?.reportActivity()
            }
        }
    }

    // MARK: Events

    private func onConnection(_ state: SupervisorState) {
        let wasConnected = connection.transport == .connected
        connection = state
        let created = drafts.keys.filter { id in state.sessions.contains { $0.sessionId == id } }
        if !created.isEmpty {
            for id in created { drafts[id] = nil }
            saveDrafts()
        }
        if state.transport == .connected, !wasConnected { reportActivity() }
        if state.transport == .connected, state.sync != .syncing { seedSeen(state.sessions) }
        // The open session is being read, so whatever it did is seen.
        if let selection, let open = state.sessions.first(where: { $0.sessionId == selection }) { markSeen(open) }
        if state.transport == .blocked, state.reason == "unauthorized" { Task { await checkRevoked() } }
    }

    /// A refused socket alone does not prove revocation; an authenticated
    /// HTTP route answering 401 does.
    private func checkRevoked() async {
        guard let api, await api.isRevoked() else { return }
        pairingNotice = "This machine no longer accepts this device. Pair it again."
        showPairing = true
    }

    private func onNotice(_ notice: ClientNotice) {
        switch notice {
        case let .commandError(message):
            toast = message
        case let .rewound(branch, _):
            open(branch)
            client.refreshSessions()
        case let .exported(sessionId, path):
            toast = "Exported to \(collapseHome(path))"
            fetchExport(sessionId: sessionId, path: path)
        case .sessionsChanged:
            client.refreshSessions()
        case let .notification(note):
            deliver(note)
        }
    }

    /// Coalesced to one bump per session per frame: opening a running session
    /// replays its whole turn as hundreds of deltas.
    private func markChanged(_ sessionId: String) {
        pendingRevisions.insert(sessionId)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard let self else { return }
            self.flushScheduled = false
            for id in self.pendingRevisions { self.revisions[id, default: 0] += 1 }
            self.pendingRevisions.removeAll()
        }
    }
}

struct SharedFile: Identifiable {
    var url: URL
    var id: URL { url }
}
