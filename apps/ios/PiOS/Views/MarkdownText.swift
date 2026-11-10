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
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .code(code, language):
                    CodeBlock(code: code, language: language)
                case let .heading(level, content):
                    Text(inline(content))
                        .font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                        .padding(.top, 4)
                case let .quote(content):
                    Text(inline(content))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
                case let .table(content):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(content).font(.system(.caption, design: .monospaced))
                    }
                case .rule:
                    Divider()
                case let .paragraph(content):
                    Text(inline(content))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ content: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: content, options: options)) ?? AttributedString(content)
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

struct CodeBlock: View {
    let code: String
    let language: String?
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language {
                HStack {
                    Text(language).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        Image(systemName: "doc.on.doc").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(tint ?? .primary)
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
