import PiOSCore
import SwiftUI

/// One tool call, correlated on `toolCallId`: a flat row, as in the PWA,
/// with its body under a rule aligned to the row's glyph. Args and result
/// arrive from different events (or from history), so it renders whatever
/// is known rather than waiting for a complete pair.
struct ToolCardView: View {
    let tool: ToolExecution
    let cwd: String?
    var blocked = false
    @AppStorage("pios.expandTools") private var expandDone = false
    @State private var open: Bool?

    var body: some View {
        // A running tool is the live edge of the turn, so its output shows
        // while produced; a manual toggle is the reader's and sticks.
        let isOpen = open ?? (tool.status == .running || expandDone)
        let headline = toolHeadline(tool.args)
        let images = tool.resultImages

        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { open = !isOpen }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: toolSymbol(tool.toolName))
                        .font(.system(size: 13))
                        .foregroundStyle(tool.isError ? Theme.error : Theme.muted)
                        .frame(width: 16)
                    Text(tool.toolName)
                        .font(Theme.mono(13))
                        .foregroundStyle(Theme.text)
                        .fixedSize()
                    Text(shortenPreview(headline, cwd: cwd))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ToolStatus(tool: tool, blocked: blocked)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, -8)

            // Outside the disclosure: when a tool returns an image, the image
            // is the result, not a detail of it.
            if !images.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                        ImageContentView(image: image, maxHeight: 320)
                    }
                }
                .padding(.leading, 12)
            }

            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    // Repeated in full: the row clips it to one line.
                    if !headline.isEmpty { OutputWell(text: headline) }
                    ForEach(Array(editBlocks(tool.args).enumerated()), id: \.offset) { _, edit in
                        if let old = edit.oldText {
                            DiffView(lines: diffLines(old, edit.newText))
                        } else {
                            OutputWell(text: clip(edit.newText))
                        }
                    }
                    let rest = leftoverArgs(tool.args)
                    if !rest.isEmpty { OutputWell(text: rest, color: Theme.muted) }
                    let output = tool.resultText
                    OutputWell(text: output.isEmpty ? placeholder : clip(output), color: tool.isError ? Theme.error : Theme.text)
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 2) }
            }
        }
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
            Text("failed").font(.system(size: 11)).foregroundStyle(Theme.error)
        } else if tool.status == .abandoned {
            Text("no result").font(.system(size: 11)).foregroundStyle(Theme.muted)
        } else if tool.status == .running {
            if blocked {
                Text("waiting for approval").font(.system(size: 11)).foregroundStyle(Theme.warn)
            } else {
                // Counted from the daemon's start time, already in this clock.
                if let startedAt = tool.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        DurationText(ms: nowMs() - startedAt)
                    }
                }
                ProgressView().controlSize(.mini).tint(Theme.muted)
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
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.muted)
        }
    }
}

/// The same block a diff gets everywhere: coloured lines in an output well.
struct DiffView: View {
    let lines: [DiffLine]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(400).enumerated()), id: \.offset) { _, line in
                    Text(prefix(line.kind) + line.text)
                        .foregroundStyle(color(line.kind))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if lines.count > 400 {
                    Text("... \(lines.count - 400) more lines").foregroundStyle(Theme.muted)
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

    private func prefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .add: return "+"
        case .remove: return "-"
        case .same: return " "
        }
    }

    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .add: return Theme.ok
        case .remove: return Theme.error
        case .same: return Theme.muted
        }
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
