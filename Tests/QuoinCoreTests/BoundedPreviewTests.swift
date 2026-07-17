import XCTest
@testable import QuoinCore

/// Tests for the Quick Look "fast/bounded" projection (issue #8). The pure
/// reduction logic lives in QuoinCore precisely so it can be exercised here
/// without any Quick Look / AppKit host.
final class BoundedPreviewTests: XCTestCase {

    // MARK: - Recursive inspectors

    /// Collects every inline reached from a block tree (depth-first).
    private func allInlines(_ blocks: [Block]) -> [Inline] {
        var out: [Inline] = []
        func walkInline(_ inline: Inline) {
            out.append(inline)
            switch inline {
            case .emphasis(let c), .strong(let c), .strikethrough(let c),
                 .highlight(let c, _), .link(_, let c):
                c.forEach(walkInline)
            default:
                break
            }
        }
        func walk(_ blocks: [Block]) {
            for block in blocks {
                switch block.kind {
                case .heading(_, let i, _), .paragraph(let i):
                    i.forEach(walkInline)
                case .table(let header, let rows, _):
                    header.forEach { $0.inlines.forEach(walkInline) }
                    rows.forEach { $0.forEach { $0.inlines.forEach(walkInline) } }
                case .list(let items, _, _):
                    items.forEach { walk($0.blocks) }
                case .blockQuote(let c), .callout(_, let c):
                    walk(c)
                default:
                    break
                }
            }
        }
        walk(blocks)
        return out
    }

    /// True if any block in the tree matches the predicate (recursing into
    /// containers and list items).
    private func containsBlock(_ blocks: [Block], where predicate: (BlockKind) -> Bool) -> Bool {
        for block in blocks {
            if predicate(block.kind) { return true }
            switch block.kind {
            case .blockQuote(let c), .callout(_, let c):
                if containsBlock(c, where: predicate) { return true }
            case .list(let items, _, _):
                for item in items where containsBlock(item.blocks, where: predicate) { return true }
            default:
                break
            }
        }
        return false
    }

    // MARK: - Source truncation

    func testSourceTruncationBelowBudgetIsUntouched() {
        let (out, truncated) = BoundedPreview.truncatedSource("hello", maxBytes: 1024)
        XCTAssertEqual(out, "hello")
        XCTAssertFalse(truncated)
    }

    func testSourceTruncationCapsBytesAndFlags() {
        let source = String(repeating: "a", count: 5000)
        let (out, truncated) = BoundedPreview.truncatedSource(source, maxBytes: 100)
        XCTAssertTrue(truncated)
        XCTAssertEqual(out.utf8.count, 100)
    }

    func testSourceTruncationNeverSplitsAMultibyteScalar() {
        // "é" is 2 UTF-8 bytes. A cut at an odd byte would split it; the
        // truncator must back up to a scalar boundary and never emit U+FFFD.
        let source = String(repeating: "é", count: 100)   // 200 bytes
        let (out, truncated) = BoundedPreview.truncatedSource(source, maxBytes: 101)
        XCTAssertTrue(truncated)
        XCTAssertFalse(out.unicodeScalars.contains("\u{FFFD}"))
        XCTAssertLessThanOrEqual(out.utf8.count, 101)
        // Every surviving character is a whole "é".
        XCTAssertTrue(out.allSatisfy { $0 == "é" })
    }

    // MARK: - Block capping

    func testBlockCapDropsTailAndFlags() {
        let source = (1...50).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        let bounds = PreviewBounds(maxInputBytes: 1_000_000, maxBlocks: 10,
                                   maxCodeLines: 100, maxRows: 100, includeFootnotes: false)
        let bounded = BoundedPreview.make(fromSource: source, bounds: bounds)
        XCTAssertEqual(bounded.document.blocks.count, 10)
        XCTAssertTrue(bounded.blocksTruncated)
        // Order preserved: the first block is still paragraph 1.
        if case .paragraph(let inlines) = bounded.document.blocks[0].kind {
            XCTAssertEqual(inlines.plainText, "Paragraph 1.")
        } else {
            XCTFail("expected first block to survive as a paragraph")
        }
    }

    func testUnderBudgetIsNotFlaggedTruncated() {
        let bounded = BoundedPreview.make(fromSource: "# Hi\n\nBody.", bounds: .preview)
        XCTAssertFalse(bounded.blocksTruncated)
        XCTAssertFalse(bounded.inputTruncated)
    }

    // MARK: - Placeholder substitution

    func testMermaidBecomesPlaceholderNotDiagram() {
        let source = "```mermaid\ngraph TD; A-->B;\n```"
        let bounded = BoundedPreview.make(fromSource: source, bounds: .preview)
        XCTAssertFalse(containsBlock(bounded.document.blocks) {
            if case .mermaid = $0 { return true } else { return false }
        }, "no raw mermaid block should survive into the bounded model")
        // It renders as a labelled code placeholder.
        let hasLabel = containsBlock(bounded.document.blocks) {
            if case .codeBlock(_, let code) = $0 { return code == PreviewPlaceholder.mermaid }
            return false
        }
        XCTAssertTrue(hasLabel)
    }

    func testDisplayMathBecomesPlaceholder() {
        let source = "$$\n\\int_0^1 x^2 dx\n$$"
        let bounded = BoundedPreview.make(fromSource: source, bounds: .preview)
        XCTAssertFalse(containsBlock(bounded.document.blocks) {
            if case .mathBlock = $0 { return true } else { return false }
        })
        let hasMathLabel = containsBlock(bounded.document.blocks) {
            if case .codeBlock(_, let code) = $0 { return code.hasPrefix("∑") }
            return false
        }
        XCTAssertTrue(hasMathLabel)
    }

    func testInlineMathBecomesInlineCode() {
        let bounded = BoundedPreview.make(fromSource: "Energy is $E = mc^2$ today.", bounds: .preview)
        let inlines = allInlines(bounded.document.blocks)
        XCTAssertFalse(inlines.contains { if case .math = $0 { return true }; return false },
                       "inline math must be swapped so no typesetting runs")
        XCTAssertTrue(inlines.contains { if case .code(let s) = $0 { return s.contains("mc^2") }; return false })
    }

    func testInlineImageBecomesTextPlaceholder() {
        let bounded = BoundedPreview.make(fromSource: "See ![a cat](cat.png) here.", bounds: .preview)
        let inlines = allInlines(bounded.document.blocks)
        XCTAssertFalse(inlines.contains { if case .image = $0 { return true }; return false },
                       "images must not survive (no file read in the extension)")
        XCTAssertTrue(inlines.contains { if case .text(let s) = $0 { return s.contains("a cat") }; return false })
    }

    func testEmbedsInsideContainersAreAlsoSubstituted() {
        let source = """
        > Quote with a diagram:
        >
        > ```mermaid
        > graph TD; A-->B;
        > ```

        - item with $x^2$ math
        - ![img](p.png)
        """
        let bounded = BoundedPreview.make(fromSource: source, bounds: .preview)
        XCTAssertFalse(containsBlock(bounded.document.blocks) {
            if case .mermaid = $0 { return true } else { return false }
        }, "nested mermaid must be substituted too")
        let inlines = allInlines(bounded.document.blocks)
        XCTAssertFalse(inlines.contains { if case .math = $0 { return true }; return false })
        XCTAssertFalse(inlines.contains { if case .image = $0 { return true }; return false })
    }

    // MARK: - Length caps

    func testCodeBlockClippedToMaxLines() {
        let body = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let source = "```\n\(body)\n```"
        let bounds = PreviewBounds(maxInputBytes: 1_000_000, maxBlocks: 100,
                                   maxCodeLines: 5, maxRows: 100, includeFootnotes: false)
        let bounded = BoundedPreview.make(fromSource: source, bounds: bounds)
        guard case .codeBlock(_, let code)? = bounded.document.blocks.first?.kind else {
            return XCTFail("expected a code block")
        }
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 6)          // 5 kept + the "…" marker line
        XCTAssertEqual(lines.last, "…")
    }

    func testTableRowsCapped() {
        var source = "| A | B |\n| - | - |\n"
        for i in 1...50 { source += "| \(i) | x |\n" }
        let bounds = PreviewBounds(maxInputBytes: 1_000_000, maxBlocks: 100,
                                   maxCodeLines: 100, maxRows: 8, includeFootnotes: false)
        let bounded = BoundedPreview.make(fromSource: source, bounds: bounds)
        guard case .table(_, let rows, _)? = bounded.document.blocks.first?.kind else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(rows.count, 8)
    }

    func testListItemsCapped() {
        let source = (1...40).map { "- item \($0)" }.joined(separator: "\n")
        let bounds = PreviewBounds(maxInputBytes: 1_000_000, maxBlocks: 100,
                                   maxCodeLines: 100, maxRows: 6, includeFootnotes: false)
        let bounded = BoundedPreview.make(fromSource: source, bounds: bounds)
        guard case .list(let items, _, _)? = bounded.document.blocks.first?.kind else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(items.count, 6)
    }

    // MARK: - Footnotes gate

    func testFootnotesGatedByBounds() {
        let source = "Text with a note.[^1]\n\n[^1]: The note body."
        let thumbnail = BoundedPreview.make(fromSource: source, bounds: .thumbnail)
        XCTAssertTrue(thumbnail.document.footnotes.isEmpty, "thumbnail drops footnotes")
        let preview = BoundedPreview.make(fromSource: source, bounds: .preview)
        XCTAssertEqual(preview.document.footnotes.count, 1, "preview keeps footnotes")
    }

    // MARK: - Downstream HTML never triggers layout markers

    func testBoundedHTMLHasNoDiagramOrMathLayoutClasses() {
        let source = """
        # Title

        ```mermaid
        graph TD; A-->B;
        ```

        $$ x^2 $$

        Inline $y=1$ and ![i](p.png).
        """
        let bounded = BoundedPreview.make(fromSource: source, bounds: .preview)
        let html = HTMLExporter.export(bounded.document, title: "t", baseURL: nil)
        XCTAssertFalse(html.contains("mermaid-source"))
        XCTAssertFalse(html.contains("math-display"))
        XCTAssertFalse(html.contains("math-inline"))
        // No image element either — the placeholder is plain text.
        XCTAssertFalse(html.contains("<img"))
    }

    // MARK: - Robustness

    func testEmptyAndWhitespaceSourceDoesNotCrash() {
        for source in ["", "   ", "\n\n\n"] {
            let bounded = BoundedPreview.make(fromSource: source, bounds: .thumbnail)
            XCTAssertFalse(bounded.blocksTruncated)
        }
    }
}
