import PiOSCore
import SwiftUI

/// Everything the user has to know that is not a message, as status lines
/// above the composer. Nothing is swallowed: a failed extension, a retry or
/// a compaction all change what the agent does next.
struct SessionBanners: View {
    let sessionId: String
    let view: SessionView
    let summary: SessionSummary?
    @Environment(AppModel.self) private var model
    @State private var errorsDismissed = 0

    var body: some View {
        VStack(spacing: 6) {
            ConnectionBanner()
            if let summary, !summary.trusted {
                StatusLine(text: "Untrusted directory: project extensions and settings are not loaded.", tone: .warn) {
                    Button("Trust") { model.client.setSessionTrust(sessionId, true) }
                }
            }
            if let retry = view.status.retry {
                StatusLine(text: retryText("Provider error, retrying", retry), tone: .warn) {
                    Button("Stop") { model.client.interrupt(sessionId) }
                }
            }
            if let retry = view.status.summarizationRetry {
                StatusLine(text: retryText("Summary failed, retrying", retry), tone: .warn) {
                    Button("Stop") { model.client.interrupt(sessionId) }
                }
            }
            if let reason = view.status.compaction {
                StatusLine(text: "Compacting context (\(reason))...") {
                    Button("Stop") { model.client.interrupt(sessionId) }
                }
            }
            if summary?.status == .crashed {
                StatusLine(text: "The agent crashed. The next prompt restarts it.", tone: .error)
            }
            let errors = Array(view.status.extensionErrors.dropFirst(errorsDismissed).suffix(3))
            ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                StatusLine(text: extensionErrorText(error), tone: .error) {
                    Button { errorsDismissed = view.status.extensionErrors.count } label: { Image(systemName: "xmark") }
                }
            }
            ForEach(view.notices) { notice in
                StatusLine(text: notice.message, tone: notice.type == "error" ? .error : notice.type == "warning" ? .warn : .muted) {
                    Button { model.client.sessions.dismissNotice(sessionId, notice.id) } label: { Image(systemName: "xmark") }
                }
            }
            if !view.steering.isEmpty || !view.followUp.isEmpty {
                QueueView(steering: view.steering, followUp: view.followUp)
            }
        }
        .animation(.snappy, value: view.status)
    }

    private func retryText(_ prefix: String, _ retry: RetryStatus) -> String {
        let attempt = retry.maxAttempts.map { "\(retry.attempt)/\($0)" } ?? "\(retry.attempt)"
        let reason = retry.error.map { ": \(readableError($0))" } ?? ""
        return "\(prefix) (attempt \(attempt))\(reason)"
    }

    private func extensionErrorText(_ error: ExtensionError) -> String {
        let source = error.extensionPath.map { ($0 as NSString).lastPathComponent } ?? error.event ?? "extension"
        return "\(source): \(error.error)"
    }
}

/// Pending steering and follow-ups, quiet and in order.
struct QueueView: View {
    let steering: [String]
    let followUp: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steering.enumerated()), id: \.offset) { _, text in
                Label(text, systemImage: "arrow.turn.down.right").lineLimit(1)
            }
            ForEach(Array(followUp.enumerated()), id: \.offset) { _, text in
                Label(text, systemImage: "text.append").lineLimit(1)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassSurface(cornerRadius: 10)
    }
}
