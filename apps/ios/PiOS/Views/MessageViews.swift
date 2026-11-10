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
            CompactionMarker(tokensBefore: tokens)
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
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(message.content.enumerated()), id: \.offset) { _, part in
                    AssistantPart(part: part, tools: tools, cwd: cwd, blocked: blocked)
                }
                if let failure = message.turnFailure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if message.stopReason == "aborted" {
                    Text("Stopped").font(.caption).foregroundStyle(.secondary)
                }
                if failedAttempts > 0 {
                    Text("Retried after \(failedAttempts) failed attempt\(failedAttempts == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
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
            ThinkingView(text: text, done: true)
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
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(partial.content.enumerated()), id: \.offset) { _, part in
                switch part {
                case let .text(text, _):
                    MarkdownText(text: text)
                case let .thinking(text, done):
                    ThinkingView(text: text, done: done)
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
    }
}

struct UserBubble: View {
    let text: String
    var images: [ImageContent] = []

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    ImageContentView(image: image, maxHeight: 220)
                }
                if !text.isEmpty {
                    Text(text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }
}

struct ThinkingView: View {
    let text: String
    let done: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain").font(.caption)
                    Text(done ? "Thought" : "Thinking...").font(.caption.weight(.medium))
                    if !done { ProgressView().controlSize(.mini) }
                    Image(systemName: "chevron.right").font(.caption2).rotationEffect(.degrees(open ? 90 : 0))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if open {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
            }
        }
    }
}

struct CompactionMarker: View {
    let tokensBefore: Double?

    var body: some View {
        HStack {
            VStack { Divider() }
            Text(tokensBefore.map { "Compacted (\(compactNumber($0)) tokens before)" } ?? "Compacted")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
            VStack { Divider() }
        }
    }
}

/// A prompt the daemon has not acknowledged yet.
struct PendingView: View {
    let entry: OutboxEntry
    let running: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            UserBubble(text: entry.text, images: entry.images).opacity(0.6)
            HStack(spacing: 6) {
                switch entry.status {
                case .queued:
                    Image(systemName: "clock")
                    Text("Queued")
                case .sending:
                    ProgressView().controlSize(.mini)
                    Text(entry.streamingBehavior.map { $0 == .steer ? "Steering" : "Follow-up" } ?? "Sending")
                case .failed:
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    Text(entry.lastError ?? "Failed").foregroundStyle(.red).lineLimit(2)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if entry.status == .failed {
                HStack {
                    if running {
                        Button("Steer") { model.client.outbox.requeue(entry.commandId, streamingBehavior: .steer) }
                        Button("Follow up") { model.client.outbox.requeue(entry.commandId, streamingBehavior: .followUp) }
                    } else {
                        Button("Retry") { model.client.outbox.requeue(entry.commandId) }
                    }
                    Button("Discard", role: .destructive) { model.client.outbox.discard(entry.commandId) }
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A persisted `!` command.
struct BashEntryView: View {
    let message: AgentMessage

    var body: some View {
        BashCard(
            command: message.command ?? "",
            output: message.output ?? "",
            running: false,
            exitCode: message.exitCode,
            cancelled: message.cancelled,
            truncated: message.truncated,
            excluded: message.excludeFromContext,
            onAbort: nil
        )
    }
}

/// The live `!` command, until pi's own entry for it lands.
struct BashRunView: View {
    let run: BashRun
    let onAbort: () -> Void

    var body: some View {
        BashCard(
            command: run.command,
            output: run.output,
            running: run.running,
            exitCode: run.result?.exitCode,
            cancelled: run.result?.cancelled ?? false,
            truncated: run.result?.truncated ?? false,
            excluded: run.excludeFromContext,
            onAbort: run.running ? onAbort : nil
        )
    }
}

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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(excluded ? "!!" : "!").font(.system(.footnote, design: .monospaced).bold()).foregroundStyle(.orange)
                Text(command).font(.system(.footnote, design: .monospaced)).lineLimit(3)
                Spacer()
                if running {
                    ProgressView().controlSize(.mini)
                    if let onAbort { Button("Stop", action: onAbort).font(.caption).buttonStyle(.bordered) }
                } else if cancelled {
                    Text("cancelled").font(.caption2).foregroundStyle(.secondary)
                } else if let exitCode {
                    Text("exit \(exitCode)").font(.caption2).foregroundStyle(exitCode == 0 ? Color.secondary : Color.red)
                }
            }
            if !output.isEmpty {
                CodeBlock(code: clip(output), language: nil)
            }
            if truncated {
                Text("Output truncated").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Long output costs layout time on every frame of a stream.
func clip(_ text: String, limit: Int = 6_000) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + "\n... (\(text.count - limit) more characters)"
}
