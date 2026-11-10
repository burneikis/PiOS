import BackgroundTasks
import PiOSCore
import UIKit
import UserNotifications

/// Settle notifications without APNs.
///
/// A sideloaded build cannot carry the push entitlement, so nothing can wake
/// the app. The daemon keeps an inbox per device instead, and the app empties
/// it whenever it reaches the daemon: live while the socket is up (including
/// the half minute the OS grants after leaving the app), on reconnect, and on
/// background refreshes, which iOS schedules at its own discretion. Each
/// item is shown as a local notification, then acknowledged.
@MainActor
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    static let refreshTask = "dev.pios.app.refresh"
    /// iOS treats this as a floor, never a promise.
    private static let refreshInterval: TimeInterval = 15 * 60
    private static let shownKey = "pios.notifications.shown"
    private static let shownLimit = 100

    /// Set by the model; a tap needs it to open the session.
    weak var model: AppModel?
    private let storage: StorageAdapter
    /// Ids already shown, so a redelivery after a lost ack stays silent.
    private var shown: [String]
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(storage: StorageAdapter) {
        self.storage = storage
        shown = readVersioned(storage, Self.shownKey, version: 1, fallback: [String]())
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks once; false when the user said no, now or before.
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    /// Shows one, unless already shown. Returns whether it is safe to ack.
    func show(_ note: DeviceNotification, machineId: String?) async -> Bool {
        if shown.contains(note.id) { return true }
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.sound = .default
        content.threadIdentifier = note.tag
        content.userInfo = ["sessionId": note.sessionId, "machineId": machineId ?? ""]
        // Keyed on the tag: a later settle for the session replaces the
        // earlier one in Notification Center, as the web push does.
        let request = UNNotificationRequest(identifier: note.tag, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            return false
        }
        shown.append(note.id)
        if shown.count > Self.shownLimit { shown.removeFirst(shown.count - Self.shownLimit) }
        writeVersioned(storage, Self.shownKey, version: 1, shown)
        return true
    }

    /// Clears what is about a session the user is now reading.
    func clear(sessionId: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["session:\(sessionId)"])
    }

    // MARK: Lifecycle

    /// Keeps the socket for the time the OS allows after leaving the app, so
    /// a turn that settles right after the user switched away still arrives.
    func enteredBackground() {
        scheduleRefresh()
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "pios.settle") { [weak self] in
            // Called on the main thread, and must end the task before returning.
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
    }

    func enteredForeground() {
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func scheduleRefresh() {
        guard model?.notificationsEnabled == true else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTask)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let sessionId = notification.request.content.userInfo["sessionId"] as? String
        return await MainActor.run {
            // Nothing to announce about the conversation on screen.
            guard let model, model.isReading(sessionId) else { return [.banner, .list, .sound] }
            return []
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let sessionId = info["sessionId"] as? String else { return }
        let machineId = info["machineId"] as? String
        await MainActor.run { model?.openFromNotification(sessionId: sessionId, machineId: machineId) }
    }
}
