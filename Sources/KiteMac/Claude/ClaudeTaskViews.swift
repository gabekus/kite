import KiteCore
import SwiftUI

struct ClaudeTaskEntryView: View {
    let entry: ClaudeTask.Entry

    var body: some View {
        switch entry.kind {
        case .user:
            Text(entry.text)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        case .assistant:
            ClaudeMarkdown(text: entry.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Label(entry.text, systemImage: "globe")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .toolError:
            Label(entry.text, systemImage: "hand.raised")
                .font(.caption).foregroundStyle(.orange).lineLimit(2)
        case .note:
            Text(entry.text).font(.caption).foregroundStyle(.secondary)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

}

/// Claude's replies: paragraphs, lists, headings, code and tables (SwiftUI's own
/// Markdown only does inline styles).
struct ClaudeMarkdown: View {
    let text: String

    enum Block {
        case paragraph(String)
        case heading(String)
        case bullet(marker: String, text: String)
        case code(String)
        case table([[String]])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(Self.inline(text))
                case .heading(let text):
                    Text(Self.inline(text)).font(.headline)
                case let .bullet(marker, text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary)
                        Text(Self.inline(text))
                    }
                    .padding(.leading, 4)
                case .code(let text):
                    Text(text).font(.system(.body, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                case .table(let rows):
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            GridRow(alignment: .top) {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(Self.inline(cell)).fontWeight(index == 0 ? .semibold : .regular)
                                }
                            }
                            if index == 0 { Divider() }
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var table: [[String]] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
            if !table.isEmpty { blocks.append(.table(table)) }
            table = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            if line.hasPrefix("|") {
                if !paragraph.isEmpty { flush() }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|:--:| row under the header.
                if !cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
                continue
            }
            if !table.isEmpty { flush() }
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                blocks.append(.bullet(marker: "•", text: String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.bullet(marker: String(line[...dot]), text: String(line[line.index(dot, offsetBy: 2)...])))
            } else {
                paragraph.append(line)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
