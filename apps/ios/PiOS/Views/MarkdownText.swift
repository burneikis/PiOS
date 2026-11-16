import PiOSCore
import SwiftUI
import UIKit

/// Assistant markdown, block by block.
///
/// Foundation's parser handles inline syntax well and block syntax not at
/// all, so blocks (fences, headings, quotes, tables) are split here and each
/// paragraph's inline markup is left to `AttributedString`.
struct MarkdownText: View {
    let text: String

    var body: some View {
        let blocks = markdownBlocks(text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .code(code, language):
                    CodeBlock(code: code, language: language)
                case let .heading(_, content):
                    // Sized off the body: a heading marks a section of one
                    // answer, not a level of the page.
                    SelectableText(text: inline(content, font: .systemFont(ofSize: 15, weight: .semibold)))
                        .padding(.top, 4)
                case let .quote(content):
                    SelectableText(text: inline(content, color: UIColor(Theme.muted)))
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.15)).frame(width: 2) }
                case let .table(content):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(content).font(Theme.mono(12.5)).lineSpacing(3)
                    }
                case .rule:
                    Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1).padding(.vertical, 4)
                case let .paragraph(content):
                    SelectableText(text: inline(content))
                }
            }
        }
        .font(Theme.body)
        .lineSpacing(Theme.bodySpacing)
        .foregroundStyle(Theme.text)
        .tint(Theme.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline markdown in UIKit attributes, with code spans drawn as in the
    /// PWA: monospaced on a dark well. Links take the text colour and an
    /// underline from `SelectableText`.
    private func inline(
        _ content: String,
        font: UIFont = .systemFont(ofSize: 15),
        color: UIColor = UIColor(Theme.text)
    ) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible
        )
        let parsed = (try? AttributedString(markdown: content, options: options)) ?? AttributedString(content)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Theme.bodySpacing
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            if intent.contains(.code) {
                attributes[.font] = UIFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
                attributes[.backgroundColor] = UIColor(Theme.well)
            } else {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if !traits.isEmpty,
                   let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) {
                    attributes[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
                }
            }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}

enum MarkdownBlock: Hashable {
    case code(String, String?)
    case heading(Int, String)
    case quote(String)
    case table(String)
    case rule
    case paragraph(String)
}

/// Splits on fences first (an unclosed one while streaming still renders as
/// code), then groups the remaining lines by kind.
func markdownBlocks(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var quote: [String] = []
    var table: [String] = []
    var code: [String]?
    var language: String?

    func flush() {
        if !paragraph.isEmpty {
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        if !quote.isEmpty {
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote = []
        }
        if !table.isEmpty {
            blocks.append(.table(table.joined(separator: "\n")))
            table = []
        }
    }

    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if code != nil {
            if trimmed.hasPrefix("```") {
                blocks.append(.code(code!.joined(separator: "\n"), language))
                code = nil
            } else {
                code!.append(line)
            }
            continue
        }
        if trimmed.hasPrefix("```") {
            flush()
            code = []
            let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            language = tag.isEmpty ? nil : tag
            continue
        }
        if trimmed.isEmpty {
            flush()
            continue
        }
        if trimmed.hasPrefix("#"), let space = trimmed.firstIndex(of: " "), trimmed[..<space].allSatisfy({ $0 == "#" }) {
            flush()
            blocks.append(.heading(min(trimmed.distance(from: trimmed.startIndex, to: space), 3), String(trimmed[space...]).trimmingCharacters(in: .whitespaces)))
            continue
        }
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            flush()
            blocks.append(.rule)
            continue
        }
        if trimmed.hasPrefix(">") {
            if !paragraph.isEmpty || !table.isEmpty { flush() }
            quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            continue
        }
        if trimmed.hasPrefix("|") {
            if !paragraph.isEmpty || !quote.isEmpty { flush() }
            // The separator row is layout, not content.
            if trimmed.allSatisfy({ "|-: ".contains($0) }) { continue }
            table.append(trimmed)
            continue
        }
        if !quote.isEmpty || !table.isEmpty { flush() }
        paragraph.append(listMarker(line))
    }
    if let code { blocks.append(.code(code.joined(separator: "\n"), language)) }
    flush()
    return blocks
}

/// `- item` and `* item` read better as bullets; numbered items stay as typed.
private func listMarker(_ line: String) -> String {
    let indent = line.prefix { $0 == " " }
    let rest = line.dropFirst(indent.count)
    if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") {
        return String(indent) + "\u{2022} " + String(rest.dropFirst(2))
    }
    return line
}

/// Code scrolls sideways rather than wrapping into a different program.
/// The copy button sits outside the scroller so it never moves.
struct CodeBlock: View {
    let code: String
    let language: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(Theme.mono(12.5))
                .lineSpacing(4)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .padding(.trailing, 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well))
        .overlay(alignment: .topTrailing) {
            Button {
                UIPasteboard.general.string = code
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 12)).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .padding(4)
        }
    }
}
