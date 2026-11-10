import PiOSCore
import SwiftUI

/// The PWA's design tokens (`apps/web/src/styles.css`), so both clients read
/// as one product. Dark only, like the web app.
enum Theme {
    static let bg = Color(hex: 0x131313)
    static let panel = Color(hex: 0x1C1C1A)
    static let raised = Color(hex: 0x232320)
    static let line = Color(hex: 0x2E2E2B)
    static let text = Color(hex: 0xEEEEEC)
    static let muted = Color(hex: 0x9B9B93)
    /// Monochrome primary: the one filled control reads as primary by being
    /// the only filled thing on screen, so no hue carries that job.
    static let accent = Color(hex: 0xE8E8E4)
    static let onAccent = Color(hex: 0x1A1A18)
    static let ok = Color(hex: 0x7FC98A)
    static let link = Color(hex: 0x8BB8E8)
    static let warn = Color(hex: 0xD9A441)
    static let error = Color(hex: 0xE5645A)
    static let hover = Color.white.opacity(0.06)
    /// Code and tool output wells.
    static let well = Color.black.opacity(0.35)

    /// One turn to the next, and one block to the next inside a turn.
    static let turnGap: CGFloat = 18
    static let control: CGFloat = 40
    static let radius: CGFloat = 12

    /// 15px/1.6 in the PWA; SF's own leading is ~1.2, the rest is spacing.
    static let body = Font.system(size: 15)
    static let bodySpacing: CGFloat = 5
    static func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension View {
    /// Liquid Glass where the OS has it, the PWA's blurred translucent panel
    /// where it does not. Used for the surfaces that float over the
    /// transcript: the composer, banners, menus.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            fallbackSurface(cornerRadius: cornerRadius)
        }
        #else
        fallbackSurface(cornerRadius: cornerRadius)
        #endif
    }

    private func fallbackSurface(cornerRadius: CGFloat) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Theme.panel.opacity(0.72)))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.line))
        )
    }

    /// The primary action: glass, prominent and tinted with the accent.
    @ViewBuilder
    func primaryButton() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent)
        } else {
            buttonStyle(FilledButtonStyle())
        }
        #else
        buttonStyle(FilledButtonStyle())
        #endif
    }

    /// A secondary icon control: glass where available, ghost otherwise.
    @ViewBuilder
    func glassButton() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            buttonStyle(.glass).tint(Theme.text)
        } else {
            buttonStyle(GhostButtonStyle())
        }
        #else
        buttonStyle(GhostButtonStyle())
        #endif
    }

    /// Rows and forms on the PWA's background instead of grouped grey.
    func themedList() -> some View {
        scrollContentBackground(.hidden).background(Theme.bg)
    }
}

/// The PWA's `.send`: filled accent, dark glyph.
struct FilledButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 12)
            .frame(minWidth: 36, minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

/// The PWA's `.ghost`: no chrome until pressed.
struct GhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Theme.text : Theme.muted)
            .padding(.horizontal, 8)
            .frame(minWidth: 32, minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(configuration.isPressed ? Theme.hover : .clear))
            .opacity(enabled ? 1 : 0.4)
    }
}

/// A session's state as a word and a tone, decided once for both the list
/// badge and the chat header, as `session-status.ts` does on the web.
struct SessionState: Equatable {
    enum Tone { case idle, cold, running, waiting, complete, crashed, untrusted }
    var tone: Tone
    var label: String

    var color: Color {
        switch tone {
        case .running: return Theme.ok
        case .waiting, .complete, .untrusted: return Theme.warn
        case .crashed: return Theme.error
        case .idle, .cold: return Theme.muted
        }
    }

    static func of(_ session: SessionSummary?, running: Bool = false, interrupting: Bool = false, blocked: Bool = false, unseen: Bool = false) -> SessionState {
        // Untrusted first, unless cold: nothing is loaded, so it says nothing yet.
        if let session, !session.trusted, session.status != .cold { return .init(tone: .untrusted, label: "untrusted") }
        // Blocked on a dialog beats running: only "waiting" tells the user to act.
        if blocked || session?.awaitingInput == true { return .init(tone: .waiting, label: "waiting") }
        if interrupting { return .init(tone: .running, label: "stopping") }
        if running { return .init(tone: .running, label: "running") }
        let status = session?.status ?? .idle
        if status == .idle, unseen { return .init(tone: .complete, label: "complete") }
        switch status {
        case .idle: return .init(tone: .idle, label: "idle")
        case .cold: return .init(tone: .cold, label: "cold")
        case .running: return .init(tone: .running, label: "running")
        case .crashed: return .init(tone: .crashed, label: "crashed")
        }
    }
}

/// What to call a session: its name, unless that is really an id, else its
/// directory. Mirrors `sessionTitle` in the web app.
func sessionTitle(name: String?, cwd: String?) -> (text: String, isPath: Bool) {
    if let name, !looksGenerated(name) { return (name, false) }
    if let cwd { return (collapseHome(cwd), true) }
    return ("New session", false)
}

private func looksGenerated(_ name: String) -> Bool {
    let text = name.trimmingCharacters(in: .whitespaces)
    guard !text.contains(where: \.isWhitespace), text.count >= 8 else { return false }
    return text.allSatisfy { $0.isHexDigit || $0 == "-" } && text.contains(where: \.isNumber)
}

/// `.../parent/dir`: the end of a path is what tells two apart.
func shortPath(_ path: String) -> String {
    let parts = path.split(separator: "/")
    return parts.count <= 2 ? path : ".../" + parts.suffix(2).joined(separator: "/")
}

/// Today as a clock time, otherwise a day count: precision decays with age.
func listTime(_ ms: Double) -> String {
    guard ms > 0 else { return "" }
    let date = Date(timeIntervalSince1970: ms / 1000)
    let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date), to: Calendar.current.startOfDay(for: Date())).day ?? 0
    if days <= 0 { return date.formatted(date: .omitted, time: .shortened) }
    if days == 1 { return "yesterday" }
    return "\(days)d ago"
}

/// 1234 as `1.2k`: token counts are read at a glance.
func compactNumber(_ value: Double) -> String {
    if value < 1000 { return String(Int(value)) }
    if value < 1_000_000 { return String(format: value < 10_000 ? "%.1fk" : "%.0fk", value / 1000) }
    return String(format: "%.1fM", value / 1_000_000)
}

/// The small uppercase capsule in a session row's corner.
struct Badge: View {
    let state: SessionState

    var body: some View {
        Text(state.label.uppercased())
            .font(.system(size: 10, weight: .medium))
            .tracking(0.6)
            .lineLimit(1)
            .foregroundStyle(state.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.hover))
    }
}

/// The header's state glyph; nothing for a resting session.
struct StatusMark: View {
    let state: SessionState

    var body: some View {
        switch state.tone {
        case .running: ProgressView().controlSize(.mini).tint(Theme.ok)
        case .waiting: Image(systemName: "pause.circle").foregroundStyle(Theme.warn)
        case .crashed, .untrusted: Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warn)
        default: EmptyView()
        }
    }
}
