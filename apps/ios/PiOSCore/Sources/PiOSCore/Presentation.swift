import Foundation

/// The non-blocking half of extension UI: what an extension asked to be shown.
///
/// Last-value-wins state, as pi keys it: status and widgets replace by key,
/// the title replaces outright. A reconnecting client needs the current
/// values, not the history of how they got there.
public struct SessionPresentation: Hashable, Sendable {
    public struct StatusItem: Hashable, Sendable {
        public var key: String
        public var text: String
    }

    public struct Widget: Hashable, Sendable {
        public var key: String
        public var lines: [String]
        public var placement: String?
    }

    public var title: String?
    /// Insertion-ordered, so chips do not reshuffle on every update.
    public var status: [StatusItem] = []
    public var widgets: [Widget] = []
    /// An extension asked to replace the composer's contents.
    public var editorText: String?

    public init() {}

    init(json: JSON) {
        title = json["title"]?.string
        status = json["status"]?.array?.compactMap { item in
            guard let key = item["key"]?.string, let text = item["text"]?.string else { return nil }
            return StatusItem(key: key, text: text)
        } ?? []
        widgets = json["widgets"]?.array?.compactMap { item in
            guard let key = item["key"]?.string else { return nil }
            return Widget(key: key, lines: item["lines"]?.strings ?? [], placement: item["placement"]?.string)
        } ?? []
        editorText = json["editorText"]?.string
    }
}

private let maxKeys = 16
private let maxText = 500
private let maxWidgetLines = 50

/// Folds one request into the presentation. Same reducer as the daemon's, so
/// the two never drift.
public func applyPresentation(_ state: SessionPresentation, _ request: ExtensionUiRequest) -> SessionPresentation {
    var next = state
    switch request.method {
    case .setTitle:
        next.title = clamp(request.title)
    case .setEditorText:
        next.editorText = clamp(request.text)
    case .setStatus:
        guard let key = request.statusKey else { return state }
        let text = clamp(request.statusText) ?? ""
        // pi clears a status by sending no text; an empty chip is worse than none.
        next.status = upsert(state.status, key: key, value: text.isEmpty ? nil : .init(key: key, text: text))
    case .setWidget:
        guard let key = request.widgetKey else { return state }
        let lines = request.widgetLines.map { Array($0.prefix(maxWidgetLines)).map { clamp($0) ?? "" } }
        next.widgets = upsert(
            state.widgets, key: key,
            value: lines.map { .init(key: key, lines: $0, placement: request.widgetPlacement) }
        )
    default:
        return state
    }
    return next
}

private protocol Keyed { var key: String { get } }
extension SessionPresentation.StatusItem: Keyed {}
extension SessionPresentation.Widget: Keyed {}

private func upsert<T: Keyed>(_ items: [T], key: String, value: T?) -> [T] {
    let index = items.firstIndex { $0.key == key }
    guard let value else { return items.filter { $0.key != key } }
    guard let index else { return items.count >= maxKeys ? items : items + [value] }
    var next = items
    next[index] = value
    return next
}

private func clamp(_ text: String?) -> String? {
    guard let text else { return nil }
    let plain = stripAnsi(text)
    return plain.count > maxText ? String(plain.prefix(maxText)) : plain
}

private let ansi = try! NSRegularExpression(
    pattern: "\u{1B}\\[[0-9;:?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|\u{1B}"
)

/// Removes terminal styling. Extensions colour their TUI status lines and the
/// escapes reach every client verbatim.
public func stripAnsi(_ text: String) -> String {
    guard text.contains("\u{1B}") else { return text }
    let mutable = NSMutableString(string: text)
    _ = ansi.replaceMatches(in: mutable, range: NSRange(location: 0, length: mutable.length), withTemplate: "")
    return mutable as String
}
