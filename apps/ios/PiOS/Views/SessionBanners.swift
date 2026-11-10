import PiOSCore
import SwiftUI

/// Conditions the user has to be told about, not just logged: retries,
/// compaction, extension failures, trust, and what extensions asked to show.
struct SessionBanners: View {
    let sessionId: String
    let view: SessionView
    let summary: SessionSummary?
    @Environment(AppModel.self) private var model
    @State private var trustDismissed = false
    @State private var errorsDismissed = 0

    var body: some View {
        VStack(spacing: 6) {
            if model.connection.transport != .connected {
                ConnectionBanner()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            if let retry = view.status.retry {
                Banner(icon: "arrow.clockwise", tint: .orange, text: retryText("Retrying", retry)) {
                    Button("Stop") { model.client.interrupt(sessionId) }
                }
            }
            if let retry = view.status.summarizationRetry {
                Banner(icon: "arrow.clockwise", tint: .orange, text: retryText("Summary retrying", retry)) {
                    Button("Stop") { model.client.interrupt(sessionId) }
                }
            }
            if let reason = view.status.compaction {
                Banner(icon: "rectangle.compress.vertical", tint: .blue, text: "Compacting context (\(reason))") {
                    Button("Stop") { model.client.interrupt(sessionId) }
                }
            }
            if summary?.status == .crashed {
                Banner(icon: "exclamationmark.octagon", tint: .red, text: "The agent crashed. Sending a prompt restarts it.") { EmptyView() }
            }
            // Surfaced, never swallowed: a silently broken extension is worse.
            let errors = Array(view.status.extensionErrors.dropFirst(errorsDismissed).suffix(3))
            ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                Banner(icon: "puzzlepiece.extension", tint: .red, text: extensionErrorText(error)) {
                    Button("Hide") { errorsDismissed = view.status.extensionErrors.count }
                }
            }
            if let summary, !summary.trusted, !trustDismissed {
                Banner(icon: "lock.shield", tint: .yellow, text: "Project not trusted: its extensions and settings do not load.") {
                    HStack {
                        Button("Trust") { model.client.setSessionTrust(sessionId, true) }
                        Button { trustDismissed = true } label: { Image(systemName: "xmark") }
                    }
                }
            }
            ForEach(view.notices) { notice in
                Banner(
                    icon: notice.type == "error" ? "xmark.octagon" : notice.type == "warning" ? "exclamationmark.triangle" : "info.circle",
                    tint: notice.type == "error" ? .red : notice.type == "warning" ? .orange : .blue,
                    text: notice.message
                ) {
                    Button { model.client.sessions.dismissNotice(sessionId, notice.id) } label: { Image(systemName: "xmark") }
                }
            }
            if !view.steering.isEmpty || !view.followUp.isEmpty {
                QueueView(steering: view.steering, followUp: view.followUp)
            }
            if !view.presentation.status.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(view.presentation.status, id: \.key) { item in
                            Text(item.text)
                                .font(.caption2)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.thinMaterial, in: Capsule())
                        }
                    }
                }
            }
            ForEach(view.presentation.widgets, id: \.key) { widget in
                Text(widget.lines.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
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

struct Banner<Trailing: View>: View {
    let icon: String
    let tint: Color
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.footnote).lineLimit(4).textSelection(.enabled)
            Spacer(minLength: 4)
            trailing.font(.footnote).buttonStyle(.borderless)
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

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
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
