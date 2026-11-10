import PiOSCore
import SwiftUI

/// One tool call, correlated on `toolCallId`. Args and result arrive from
/// different events (or from history instead), so it renders whatever is
/// known rather than waiting for a complete pair.
struct ToolCardView: View {
    let tool: ToolExecution
    let cwd: String?
    var blocked = false
    @AppStorage("pios.expandTools") private var expandDone = false
    @State private var open: Bool? = nil

    var body: some View {
        // A running tool is the live edge of the turn, so its output shows
        // while produced; a manual toggle is the reader's and sticks.
        let isOpen = open ?? (tool.status == .running || expandDone)
        let headline = toolHeadline(tool.args)
        let images = tool.resultImages

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { open = !isOpen }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: toolSymbol(tool.toolName))
                        .font(.footnote)
                        .foregroundStyle(tool.isError ? Color.red : Color.secondary)
                        .frame(width: 18)
                    Text(tool.toolName).font(.footnote.weight(.semibold))
                    Text(shortenPreview(headline, cwd: cwd))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    ToolStatus(tool: tool, blocked: blocked)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Outside the disclosure: when a tool returns an image, the image
            // is the result, not a detail of it.
            if !images.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                        ImageContentView(image: image, maxHeight: 260)
                    }
                }
                .padding([.horizontal, .bottom], 10)
            }

            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    if !headline.isEmpty, headline.count > 40 || headline.contains("\n") {
                        CodeBlock(code: headline, language: nil)
                    }
                    ForEach(Array(editBlocks(tool.args).enumerated()), id: \.offset) { _, edit in
                        if let old = edit.oldText {
                            DiffView(lines: diffLines(old, edit.newText))
                        } else {
                            CodeBlock(code: clip(edit.newText), language: nil)
                        }
                    }
                    let rest = leftoverArgs(tool.args)
                    if !rest.isEmpty {
                        Text(rest).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    let output = tool.resultText
                    CodeBlock(
                        code: output.isEmpty ? placeholder : clip(output),
                        language: nil,
                        tint: tool.isError ? .red : nil
                    )
                }
                .padding([.horizontal, .bottom], 10)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tool.isError ? Color.red.opacity(0.4) : Color.clear)
        )
    }

    private var placeholder: String {
        tool.status == .abandoned ? "(no result: the run ended first)" : tool.status == .running ? "(no output yet)" : "(no output)"
    }
}

struct ToolStatus: View {
    let tool: ToolExecution
    let blocked: Bool

    var body: some View {
        if tool.isError {
            Text("failed").font(.caption2).foregroundStyle(.red)
        } else if tool.status == .abandoned {
            Text("no result").font(.caption2).foregroundStyle(.secondary)
        } else if tool.status == .running {
            if blocked {
                Text("waiting for approval").font(.caption2).foregroundStyle(.orange)
            } else {
                // Counted locally from the daemon's start time, already moved
                // into this clock by the store.
                if let startedAt = tool.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        DurationText(ms: nowMs() - startedAt)
                    }
                }
                ProgressView().controlSize(.mini)
            }
        } else if let duration = tool.durationMs {
            DurationText(ms: duration)
        }
    }
}

struct DurationText: View {
    let ms: Double

    var body: some View {
        // Below a second the number is noise.
        if ms >= 1000 {
            let seconds = Int((ms / 1000).rounded())
            Text(seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct DiffView: View {
    let lines: [DiffLine]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(400).enumerated()), id: \.offset) { _, line in
                    Text(prefix(line.kind) + line.text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .background(background(line.kind))
                        .foregroundStyle(foreground(line.kind))
                }
                if lines.count > 400 {
                    Text("... \(lines.count - 400) more lines").font(.caption2).foregroundStyle(.secondary).padding(6)
                }
            }
            .textSelection(.enabled)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func prefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .add: return "+ "
        case .remove: return "- "
        case .same: return "  "
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .add: return .green.opacity(0.15)
        case .remove: return .red.opacity(0.15)
        case .same: return .clear
        }
    }

    private func foreground(_ kind: DiffLine.Kind) -> Color {
        kind == .same ? .secondary : .primary
    }
}

func toolSymbol(_ name: String) -> String {
    switch name.lowercased() {
    case "bash", "shell", "exec": return "terminal"
    case "read", "view", "cat": return "doc.text"
    case "edit", "multiedit", "str_replace": return "pencil"
    case "write", "create": return "square.and.pencil"
    case "grep", "find", "glob", "search", "rg": return "magnifyingglass"
    case "ls", "list": return "folder"
    case "fetch", "web_fetch", "webfetch", "web_search", "websearch": return "globe"
    case "todo", "todowrite": return "checklist"
    default: return "wrench.and.screwdriver"
    }
}
