import Foundation
import Markdown

/// Exporters are pure functions from a `QuoinDocument`, so macOS and iOS
/// produce identical output. PDF and RTF are rendered from attributed output
/// in QuoinRender (they need a text system); TXT and MD live here in the core.
public enum PlainTextExporter {

    /// Markdown syntax stripped, structure preserved and readable.
    public static func export(_ document: QuoinDocument) -> String {
        var out: [String] = []
        render(document.blocks, indent: "", into: &out)
        if !document.footnotes.isEmpty {
            out.append("———")
            for footnote in document.footnotes {
                var body: [String] = []
                render(footnote.blocks, indent: "", into: &body)
                out.append("[\(footnote.index)] " + body.joined(separator: "\n"))
            }
        }
        return out.joined(separator: "\n\n") + "\n"
    }

    private static func render(_ blocks: [Block], indent: String, into out: inout [String]) {
        for block in blocks {
            switch block.kind {
            case .heading(_, let inlines, _):
                out.append(indent + inlines.plainText.trimmingCharacters(in: .whitespaces))
            case .paragraph(let inlines):
                out.append(indent + inlines.plainText)
            case .codeBlock(_, let code), .diagram(let code, _):
                out.append(code.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { indent + "    " + $0 }
                    .joined(separator: "\n"))
            case .mathBlock(let latex):
                out.append(indent + latex)
            case .table(let header, let rows, _):
                var lines: [String] = []
                lines.append(indent + header.map { $0.inlines.plainText }.joined(separator: " | "))
                for row in rows {
                    lines.append(indent + row.map { $0.inlines.plainText }.joined(separator: " | "))
                }
                out.append(lines.joined(separator: "\n"))
            case .list(let items, let ordered, let start):
                var lines: [String] = []
                for (index, item) in items.enumerated() {
                    let bullet: String
                    if let task = item.task {
                        bullet = task == .checked ? "[✓]" : "[ ]"
                    } else if ordered {
                        bullet = "\(start + index)."
                    } else {
                        bullet = "•"
                    }
                    var itemOut: [String] = []
                    render(item.blocks, indent: indent + "   ", into: &itemOut)
                    let body = itemOut.joined(separator: "\n\n")
                    let trimmed = body.drop(while: { $0 == " " })
                    lines.append(indent + bullet + " " + trimmed)
                }
                out.append(lines.joined(separator: "\n"))
            case .blockQuote(let children):
                var quoted: [String] = []
                render(children, indent: indent + "  ", into: &quoted)
                out.append(quoted.joined(separator: "\n\n"))
            case .callout(let kind, let children):
                var body: [String] = []
                render(children, indent: indent + "  ", into: &body)
                out.append(indent + kind.title.uppercased() + "\n" + body.joined(separator: "\n\n"))
            case .frontMatter(let yaml):
                out.append(yaml.split(separator: "\n").map { indent + $0 }.joined(separator: "\n"))
            case .reviewEndmatter(let yaml):
                out.append(yaml.split(separator: "\n").map { indent + $0 }.joined(separator: "\n"))
            case .tableOfContents:
                break // navigation aid, not content
            case .thematicBreak:
                out.append(indent + "———")
            case .htmlBlock(let html):
                out.append(indent + html)
            }
        }
    }
}

public enum MarkdownExporter {

    /// Normalized, consistently formatted markdown via swift-markdown's
    /// formatter (stable bullets, fences, and table alignment).
    public static func export(_ document: QuoinDocument) -> String {
        Markdown.Document(parsing: document.source).format()
    }
}
