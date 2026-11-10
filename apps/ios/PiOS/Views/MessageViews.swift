import PiOSCore
import SwiftUI
import UIKit

/// One row of the transcript.
struct TranscriptItem: View {
    let item: ViewItem
    let view: SessionView
    let sessionId: String
    let cwd: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        switch item {
        case let .message(_, message, entryId, failedAttempts):
            MessageView(message: message, tools: view.tools, cwd: cwd, failedAttempts: failedAttempts, blocked: !view.dialogs.isEmpty)
                .contextMenu { menu(message: message, entryId: entryId) }
        case let .compaction(_, tokens):
            TextDivider(text: tokens.map { "Context compacted from \(compactNumber($0)) tokens" } ?? "Context compacted")
        case let .streaming(partial):
            StreamingView(partial: partial, tools: view.tools, cwd: cwd, blocked: !view.dialogs.isEmpty)
        case let .pending(entry):
            PendingView(entry: entry, running: view.running)
        }
    }

    @ViewBuilder
    private func menu(message: AgentMessage, entryId: String?) -> some View {
        let text = message.role == .bashExecution ? (message.output ?? "") : message.text
        if !text.isEmpty {
            Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
        if message.role == .user, let entryId {
            // Branches into a new session; this one is never rewritten.
            Button { model.client.rewind(sessionId, entryId: entryId) } label: {
                Label("Rewind to here", systemImage: "arrow.uturn.backward")
            }
        }
    }
}

/// An assistant turn is the page, not an object on it: no border, no fill.
/// Only the user's own words get a surface.
struct MessageView: View {
    let message: AgentMessage
    let tools: [String: ToolExecution]
    let cwd: String?
    var failedAttempts = 0
    var blocked = false

    var body: some View {
        switch message.role {
        case .user:
            UserBubble(text: message.text, images: message.images)
        case .assistant:
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(message.content.enumerated()), id: \.offset) { _, part in
                    AssistantPart(part: part, tools: tools, cwd: cwd, blocked: blocked)
                }
                if let failure = message.turnFailure {
                    Text(failure)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.error)
                        .textSelection(.enabled)
                }
                if message.stopReason == "aborted" {
                    Text("Stopped").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                if failedAttempts > 0 {
                    Text("Retried after \(failedAttempts) failed attempt\(failedAttempts == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .bashExecution:
            BashEntryView(message: message)
        case .toolResult, .system:
            EmptyView()
        }
    }
}

struct AssistantPart: View {
    let part: ContentPart
    let tools: [String: ToolExecution]
    let cwd: String?
    let blocked: Bool

    var body: some View {
        switch part {
        case let .text(text):
            MarkdownText(text: text)
        case let .thinking(text):
            ThinkingView(text: text)
        case let .image(image):
            ImageContentView(image: image)
        case let .toolCall(call):
            ToolCardView(
                tool: tools[call.id] ?? ToolExecution(toolCallId: call.id, toolName: call.name, args: call.arguments),
                cwd: cwd, blocked: blocked
            )
        }
    }
}

struct StreamingView: View {
    let partial: PartialMessage
    let tools: [String: ToolExecution]
    let cwd: String?
    let blocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(partial.content.enumerated()), id: \.offset) { _, part in
                switch part {
                case let .text(text, _):
                    MarkdownText(text: text)
                case let .thinking(text, _):
                    ThinkingView(text: text)
                case let .toolCall(id, name, argsText, arguments, _):
                    if let id, let tool = tools[id] {
                        ToolCardView(tool: tool, cwd: cwd, blocked: blocked)
                    } else {
                        ToolCardView(
                            tool: ToolExecution(toolCallId: id ?? "pending", toolName: name ?? "tool", args: arguments ?? .string(argsText)),
                            cwd: cwd, blocked: blocked
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UserBubble: View {
    let text: String
    var images: [ImageContent] = []
    /// Edge drawn round the bubble: a failed prompt is outlined in red.
    var outline: Color?

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    ImageContentView(image: image, maxHeight: 220)
                }
                if !text.isEmpty {
                    Text(text)
                        .font(Theme.body)
                        .lineSpacing(Theme.bodySpacing)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.raised))
                        .overlay {
                            if let outline {
                                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(outline)
                            }
                        }
                }
            }
        }
    }
}

/// Reasoning reads as an aside: a rule in the margin, dimmer than the
/// answer. Shown by default; a tap folds it to a one-line trace.
struct ThinkingView: View {
    let text: String
    @AppStorage("pios.showThinking") private var showByDefault = true
    @State private var shown: Bool?

    var body: some View {
        let isShown = shown ?? showByDefault
        VStack(alignment: .leading, spacing: 4) {
            Text(isShown ? "Thinking:" : "Thinking\u{2026}")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
            if isShown {
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14)
        .overlay(alignment: .leading) {
            Rectangle().fill(isShown ? Theme.line : .clear).frame(width: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { shown = !isShown } }
    }
}

/// A line with words in it, for boundaries in the history.
struct TextDivider: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.line).frame(height: 1)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize()
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

/// A prompt the daemon has not acknowledged yet.
struct PendingView: View {
    let entry: OutboxEntry
    let running: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let failed = entry.status == .failed
        VStack(alignment: .trailing, spacing: 6) {
            UserBubble(text: entry.text, images: entry.images, outline: failed ? Theme.error : nil)
                .opacity(failed ? 1 : 0.6)
            Text(statusText)
                .font(.system(size: 13))
                .foregroundStyle(failed ? Theme.error : Theme.muted)
                .lineLimit(3)
            if failed {
                HStack(spacing: 6) {
                    if running {
                        Button("Steer") { model.client.outbox.requeue(entry.commandId, streamingBehavior: .steer) }
                        Button("Follow up") { model.client.outbox.requeue(entry.commandId, streamingBehavior: .followUp) }
                    } else {
                        Button("Retry") { model.client.outbox.requeue(entry.commandId) }
                    }
                    Button("Discard", role: .destructive) { model.client.outbox.discard(entry.commandId) }
                }
                .font(.system(size: 13))
                .glassButton()
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var statusText: String {
        switch entry.status {
        case .queued: return "queued"
        case .sending: return entry.streamingBehavior.map { $0 == .steer ? "steering" : "follow-up" } ?? "sending"
        case .failed: return entry.lastError ?? "failed"
        }
    }
}

/// A persisted `!` command.
struct BashEntryView: View {
    let message: AgentMessage

    var body: some View {
        BashCard(
            command: message.command ?? "", output: message.output ?? "", running: false,
            exitCode: message.exitCode, cancelled: message.cancelled, truncated: message.truncated,
            excluded: message.excludeFromContext, onAbort: nil
        )
    }
}

/// The live `!` command, until pi's own entry for it lands.
struct BashRunView: View {
    let run: BashRun
    let onAbort: () -> Void

    var body: some View {
        BashCard(
            command: run.command, output: run.output, running: run.running,
            exitCode: run.result?.exitCode, cancelled: run.result?.cancelled ?? false,
            truncated: run.result?.truncated ?? false, excluded: run.excludeFromContext,
            onAbort: run.running ? onAbort : nil
        )
    }
}

/// A `!` run is the user's own command, so it sits on their side; `!!`
/// never reaches the model, and the dashed edge says so without a label.
struct BashCard: View {
    let command: String
    let output: String
    let running: Bool
    let exitCode: Int?
    let cancelled: Bool
    let truncated: Bool
    let excluded: Bool
    let onAbort: (() -> Void)?

    var body: some View {
        HStack {
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("$ \(command)")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(3)
                    Spacer(minLength: 4)
                    if running {
                        ProgressView().controlSize(.mini).tint(Theme.muted)
                        if let onAbort { Button("Stop", action: onAbort).font(.system(size: 13)).buttonStyle(GhostButtonStyle()) }
                    } else if cancelled {
                        Text("cancelled").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    } else if let exitCode, exitCode != 0 {
                        Text("exit \(exitCode)").font(.system(size: 11)).foregroundStyle(Theme.error)
                    }
                }
                if !output.isEmpty { OutputWell(text: clip(output)) }
                if truncated {
                    Text("Output truncated").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: excluded ? [4, 3] : []))
            )
            .opacity(excluded ? 0.75 : 1)
        }
    }
}

/// Program output: columnar, so it scrolls sideways instead of wrapping.
struct OutputWell: View {
    let text: String
    var color: Color = Theme.text

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(Theme.mono(11.5))
                .lineSpacing(2)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
    }
}

/// Long output costs layout time on every frame of a stream.
func clip(_ text: String, limit: Int = 6_000) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + "\n... (\(text.count - limit) more characters)"
}
