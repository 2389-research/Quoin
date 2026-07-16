import XCTest
@testable import QuoinCore

final class MarkdownConverterTests: XCTestCase {

    // MARK: - Basic structure

    func testHeadingsAndOutline() {
        let doc = MarkdownConverter.parse("""
        # Title

        ## Section One

        Body text.

        ## Section One

        ### Deep
        """)

        XCTAssertEqual(doc.outline.count, 4)
        XCTAssertEqual(doc.outline[0].level, 1)
        XCTAssertEqual(doc.outline[0].title, "Title")
        XCTAssertEqual(doc.outline[0].slug, "title")
        XCTAssertEqual(doc.outline[1].slug, "section-one")
        // GitHub-style dedupe for repeated headings.
        XCTAssertEqual(doc.outline[2].slug, "section-one-1")
        XCTAssertEqual(doc.stats.headingCount, 4)
    }

    func testParagraphInlines() {
        let doc = MarkdownConverter.parse("Some **bold** and *italic* and `code` and [a link](https://example.com).")
        guard case .paragraph(let inlines) = doc.blocks[0].kind else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(inlines.plainText, "Some bold and italic and code and a link.")
        XCTAssertEqual(doc.stats.linkCount, 1)
    }

    func testTable() {
        let doc = MarkdownConverter.parse("""
        | Name | Value |
        |:-----|------:|
        | a    | 1     |
        | b    | 2     |
        """)
        guard case .table(let header, let rows, let alignments) = doc.blocks[0].kind else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(header.count, 2)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(header[0].inlines.plainText, "Name")
        XCTAssertEqual(rows[1][1].inlines.plainText, "2")
        XCTAssertEqual(alignments, [.left, .right])
        XCTAssertEqual(doc.stats.tableCount, 1)
    }

    func testTaskListWithMarkerRanges() throws {
        let source = """
        - [ ] first
        - [x] second
        - plain item
        """
        let doc = MarkdownConverter.parse(source)
        guard case .list(let items, let ordered, _) = doc.blocks[0].kind else {
            return XCTFail("expected list")
        }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].task, .unchecked)
        XCTAssertEqual(items[1].task, .checked)
        XCTAssertNil(items[2].task)

        // Marker ranges must point at the exact `[ ]` / `[x]` bytes.
        let firstMarker = try XCTUnwrap(items[0].taskMarkerRange)
        XCTAssertEqual(source.substring(in: firstMarker), "[ ]")
        let secondMarker = try XCTUnwrap(items[1].taskMarkerRange)
        XCTAssertEqual(source.substring(in: secondMarker), "[x]")

        XCTAssertEqual(doc.stats.taskTotal, 2)
        XCTAssertEqual(doc.stats.taskDone, 1)
    }

    func testNestedBlockQuote() {
        let doc = MarkdownConverter.parse("> quoted text\n>\n> more")
        guard case .blockQuote(let children) = doc.blocks[0].kind else {
            return XCTFail("expected block quote")
        }
        XCTAssertEqual(children.count, 2)
    }

    // MARK: - Fences

    func testMermaidFence() {
        let doc = MarkdownConverter.parse("```mermaid\ngraph TD\n  A --> B\n```")
        guard case .mermaid(let source) = doc.blocks[0].kind else {
            return XCTFail("expected mermaid block")
        }
        XCTAssertEqual(source, "graph TD\n  A --> B")
        XCTAssertEqual(doc.stats.diagramCount, 1)
        XCTAssertEqual(doc.stats.codeBlockCount, 0)
    }

    func testMathFence() {
        let doc = MarkdownConverter.parse("```math\n\\frac{a}{b}\n```")
        guard case .mathBlock(let latex) = doc.blocks[0].kind else {
            return XCTFail("expected math block")
        }
        XCTAssertEqual(latex, "\\frac{a}{b}")
    }

    func testRegularCodeBlockKeepsLanguage() {
        let doc = MarkdownConverter.parse("```swift\nlet x = 1\n```")
        guard case .codeBlock(let language, let code) = doc.blocks[0].kind else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let x = 1")
    }

    // MARK: - Math

    func testInlineMath() {
        let doc = MarkdownConverter.parse("Euler says $e^{i\\pi} + 1 = 0$ famously.")
        guard case .paragraph(let inlines) = doc.blocks[0].kind else {
            return XCTFail("expected paragraph")
        }
        XCTAssertTrue(inlines.contains(.math(latex: "e^{i\\pi} + 1 = 0")))
        XCTAssertEqual(doc.stats.mathCount, 1)
    }

    func testInlineMathWithUnderscoresSurvivesEmphasisParsing() {
        // cmark would parse a_b + c_d as emphasis; the slice-based math pass
        // must keep the span intact.
        let doc = MarkdownConverter.parse("Value $a_b + c_d$ here.")
        guard case .paragraph(let inlines) = doc.blocks[0].kind else {
            return XCTFail("expected paragraph")
        }
        XCTAssertTrue(inlines.contains(.math(latex: "a_b + c_d")))
    }

    func testDisplayMathBecomesBlock() {
        let doc = MarkdownConverter.parse("$$\n\\int_0^1 x\\,dx = \\tfrac12\n$$")
        guard case .mathBlock(let latex) = doc.blocks[0].kind else {
            return XCTFail("expected math block, got \(doc.blocks[0].kind)")
        }
        XCTAssertEqual(latex, "\\int_0^1 x\\,dx = \\tfrac12")
    }

    func testDollarAmountsAreNotMath() {
        let doc = MarkdownConverter.parse("It costs $5 and later $10 total.")
        guard case .paragraph(let inlines) = doc.blocks[0].kind else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(doc.stats.mathCount, 0)
        XCTAssertEqual(inlines.plainText, "It costs $5 and later $10 total.")
    }

    func testEscapedDollarIsLiteral() {
        let doc = MarkdownConverter.parse("Escaped \\$x\\$ is not math.")
        XCTAssertEqual(doc.stats.mathCount, 0)
    }

    func testMathInHeading() {
        let doc = MarkdownConverter.parse("## The $O(n^2)$ problem")
        guard case .heading(_, let inlines, _) = doc.blocks[0].kind else {
            return XCTFail("expected heading")
        }
        XCTAssertTrue(inlines.contains(.math(latex: "O(n^2)")))
    }

    // MARK: - Source map

    func testBlockRangesCoverSource() {
        let source = "# Title\n\nParagraph one.\n\nParagraph two."
        let doc = MarkdownConverter.parse(source)
        XCTAssertEqual(doc.blocks.count, 3)
        XCTAssertEqual(source.substring(in: doc.blocks[0].range), "# Title")
        XCTAssertEqual(source.substring(in: doc.blocks[1].range), "Paragraph one.")
        XCTAssertEqual(source.substring(in: doc.blocks[2].range), "Paragraph two.")
    }

    func testUnicodeSourceRanges() {
        let source = "# Café ☕️\n\nZürich naïveté — emoji 🎉 text."
        let doc = MarkdownConverter.parse(source)
        XCTAssertEqual(source.substring(in: doc.blocks[0].range), "# Café ☕️")
        XCTAssertEqual(doc.outline[0].title, "Café ☕️")
    }

    // MARK: - Incremental parsing

    func testPlainParagraphEditFastPathMatchesFullParse() throws {
        let source = """
        # Title

        Alpha beta gamma.

        ## Later

        Tail paragraph.
        """
        let previous = MarkdownConverter.parse(source)
        let paragraph = try XCTUnwrap(previous.blocks.first { block in
            if case .paragraph = block.kind { return true }
            return false
        })
        let insertionOffset = paragraph.range.offset + "Alpha ".utf8.count
        let edit = SourceEdit(range: ByteRange(offset: insertionOffset, length: 0), replacement: "brave ")

        let incremental = try MarkdownConverter.parseAfterEdit(previous: previous, edit: edit)
        XCTAssertEqual(incremental.strategy, .plainParagraphFastPath)
        assertEquivalentToFullParse(incremental.document)
    }

    func testPlainParagraphFastPathFallsBackForMarkdownSyntax() throws {
        let source = "Alpha beta gamma.\n\nTail paragraph."
        let previous = MarkdownConverter.parse(source)
        let edit = SourceEdit(range: ByteRange(offset: "Alpha ".utf8.count, length: 0), replacement: "**bold** ")

        let incremental = try MarkdownConverter.parseAfterEdit(previous: previous, edit: edit)
        XCTAssertEqual(incremental.strategy, .full)
        assertEquivalentToFullParse(incremental.document)
    }

    private func assertEquivalentToFullParse(_ document: QuoinDocument, file: StaticString = #filePath, line: UInt = #line) {
        let full = MarkdownConverter.parse(document.source)
        XCTAssertEqual(document.blocks, full.blocks, file: file, line: line)
        XCTAssertEqual(document.outline, full.outline, file: file, line: line)
        XCTAssertEqual(document.footnotes, full.footnotes, file: file, line: line)
        XCTAssertEqual(document.stats, full.stats, file: file, line: line)
        XCTAssertEqual(document.sourceHash, full.sourceHash, file: file, line: line)
        XCTAssertEqual(document.reviewMetadata, full.reviewMetadata, file: file, line: line)
    }

    func testLiveMarksForceTheFullParse() throws {
        // Marks carry ABSOLUTE byte ranges inside their inlines; the fast
        // path's block-range shifting can't reach them, so an edit before a
        // mark left its stored range (and content hash) stale — panel
        // actions then hit the drift refusal and silently no-op'd. Any live
        // mark must take the full parse (found by scratch probe I).
        let source = """
        Plain lead here.

        Body {++x++}{#s1} here.

        ---
        suggestions:
          s1: { by: AI, at: "2026-01-01T00:00:00Z" }

        """
        let previous = MarkdownConverter.parse(source)
        XCTAssertNotNil(previous.reviewMetadata)
        let edit = SourceEdit(range: ByteRange(offset: 3, length: 0), replacement: "q")

        let incremental = try MarkdownConverter.parseAfterEdit(previous: previous, edit: edit)
        XCTAssertEqual(incremental.strategy, .full)
        assertEquivalentToFullParse(incremental.document)
    }

    func testTypingAMarkIntoAPlainParagraphTakesTheFullParse() throws {
        // The slice re-parse would stamp a NEW mark's inline range
        // slice-relative, not document-absolute — resolving it would then
        // splice the wrong bytes (panel review, HIGH).
        let source = "Lead paragraph.\n\nAlpha beta gamma.\n"
        let previous = MarkdownConverter.parse(source)
        let offset = "Lead paragraph.\n\nAlpha ".utf8.count
        let edit = SourceEdit(range: ByteRange(offset: offset, length: 0),
                              replacement: "{++new++} ")
        let incremental = try MarkdownConverter.parseAfterEdit(previous: previous, edit: edit)
        XCTAssertEqual(incremental.strategy, .full)
        assertEquivalentToFullParse(incremental.document)
        let marks = SuggestionResolver.marks(in: incremental.document)
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks[0].range.offset, offset, "range is document-absolute")
    }

    func testFastPathCarriesReviewMetadataWhenOnlyHistoryRemains() throws {
        // Endmatter with resolved records but no live marks: the fast path
        // fires (nothing to re-anchor) and must carry reviewMetadata — it
        // once rebuilt the document without it, so one keystroke made the
        // Review panel's history vanish.
        let source = """
        Plain lead here.

        Body all done here.

        ---
        suggestions:
          s1:
            by: AI
            status: resolved
            resolved: "accepted · x"

        """
        let previous = MarkdownConverter.parse(source)
        XCTAssertNotNil(previous.reviewMetadata)
        XCTAssertEqual(previous.stats.suggestionCount, 0)
        let edit = SourceEdit(range: ByteRange(offset: 3, length: 0), replacement: "q")

        let incremental = try MarkdownConverter.parseAfterEdit(previous: previous, edit: edit)
        XCTAssertEqual(incremental.strategy, .plainParagraphFastPath)
        assertEquivalentToFullParse(incremental.document)
    }

    // MARK: - Stats

    func testStats() {
        let doc = MarkdownConverter.parse("""
        # Title

        One two three four five.

        ![alt](img.png) and [link](https://x.y).
        """)
        XCTAssertEqual(doc.stats.headingCount, 1)
        XCTAssertEqual(doc.stats.imageCount, 1)
        XCTAssertEqual(doc.stats.linkCount, 1)
        XCTAssertGreaterThanOrEqual(doc.stats.wordCount, 7)
        XCTAssertGreaterThanOrEqual(doc.stats.readingTimeMinutes, 1)
    }

    // MARK: - Identity & diff

    func testUnchangedBlocksKeepIdentityAcrossReparse() {
        let a = MarkdownConverter.parse("# Title\n\nStable paragraph.\n\nChanging paragraph.")
        let b = MarkdownConverter.parse("# Title\n\nStable paragraph.\n\nChanged text!")
        let diff = BlockDiff.between(old: a.blocks, new: b.blocks)
        XCTAssertEqual(diff.unchanged.count, 2)
        XCTAssertEqual(diff.inserted.count, 1)
        XCTAssertEqual(diff.removed.count, 1)
    }

    func testRepeatedIdenticalBlocksGetDistinctIdentity() {
        let doc = MarkdownConverter.parse("Same.\n\nSame.\n\nSame.")
        let ids = Set(doc.blocks.map(\.id))
        XCTAssertEqual(ids.count, 3)
    }

    // MARK: - Robustness

    func testEmptyDocument() {
        let doc = MarkdownConverter.parse("")
        XCTAssertTrue(doc.blocks.isEmpty)
        XCTAssertTrue(doc.outline.isEmpty)
    }

    func testHTMLBlockPreservedAsLiteral() {
        let doc = MarkdownConverter.parse("<div>\nraw\n</div>")
        guard case .htmlBlock = doc.blocks[0].kind else {
            return XCTFail("expected html block")
        }
    }

    /// cmark reports a comment block's end one LINE short when `-->` sits
    /// on its own line — the block's slice lost its closing marker, so the
    /// reveal showed `<!--` but never `-->` (task #71). The converter
    /// repairs the range against rawHTML; the slice must be the FULL
    /// comment for every shape of the bug.
    func testHTMLCommentBlockRangeIncludesClosingMarkerLine() throws {
        let cases: [(source: String, expectedSlice: String)] = [
            // The stress doc's header shape: multi-line body.
            ("<!--\nsection_id: abc-123\nnote: stress header\n-->\n\ntail",
             "<!--\nsection_id: abc-123\nnote: stress header\n-->"),
            // Degenerate two-line comment.
            ("<!--\n-->\n\ntail", "<!--\n-->"),
            // Last block, file without a trailing newline.
            ("tail\n\n<!--\nlast\n-->", "<!--\nlast\n-->"),
        ]
        for (source, expectedSlice) in cases {
            let doc = MarkdownConverter.parse(source)
            let block = try XCTUnwrap(doc.blocks.first {
                if case .htmlBlock = $0.kind { return true }
                return false
            })
            XCTAssertEqual(source.substring(in: block.range), expectedSlice,
                           "comment slice lost its closing line in \(source.debugDescription)")
        }
    }

    /// Ranges that were already correct must stay byte-identical: the
    /// repair only fires when cmark's range verifiably dropped bytes.
    func testHTMLBlockRangeRepairLeavesCorrectRangesAlone() throws {
        let cases: [(source: String, expectedSlice: String)] = [
            ("<!-- one line -->\n\ntail", "<!-- one line -->"),
            ("<div>\nfoo\n</div>\n\ntail", "<div>\nfoo\n</div>"),
        ]
        for (source, expectedSlice) in cases {
            let doc = MarkdownConverter.parse(source)
            let block = try XCTUnwrap(doc.blocks.first {
                if case .htmlBlock = $0.kind { return true }
                return false
            })
            XCTAssertEqual(source.substring(in: block.range), expectedSlice)
        }
    }
}
