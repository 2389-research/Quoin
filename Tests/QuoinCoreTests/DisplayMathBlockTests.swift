import XCTest
@testable import QuoinCore

/// Standalone display-math spans (`\[…\]` / `$$…$$`, delimiters alone on
/// their own lines) must survive setext-lookalike interior lines. cmark has
/// no math extension: a bare `=` (or `---`) inside the span re-parses the
/// lines above it as a setext heading / thematic break BEFORE the math pass
/// runs — paragraph + phantom H1 (it even entered the outline) + orphaned
/// tail. `DisplayMathPrescan` claims confirmed spans from the raw source
/// pre-cmark; these tests pin the claim, its conservatism, and the
/// incremental fast paths around it.
final class DisplayMathBlockTests: XCTestCase {

    /// The canonical repro from the report, verbatim.
    private let matrixSource = """
    Intro.

    \\[
    \\begin{bmatrix}
    2 & -1 & 0 \\\\
    -1 & 2 & -1 \\\\
    0 & -1 & 2
    \\end{bmatrix}
    \\begin{bmatrix}
    x_1\\\\x_2\\\\x_3
    \\end{bmatrix}
    =
    \\begin{bmatrix}
    1\\\\0\\\\1
    \\end{bmatrix}
    \\]

    Tail.
    """

    private func assertMatrixShape(
        _ doc: QuoinDocument, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(doc.blocks.count, 3, "expected [p, math, p], got \(doc.blocks.map(\.kind))",
                       file: file, line: line)
        guard doc.blocks.count == 3 else { return }
        guard case .paragraph(let intro) = doc.blocks[0].kind else {
            return XCTFail("expected intro paragraph", file: file, line: line)
        }
        XCTAssertEqual(intro.plainText, "Intro.", file: file, line: line)
        guard case .mathBlock(let latex) = doc.blocks[1].kind else {
            return XCTFail("expected math block, got \(doc.blocks[1].kind)", file: file, line: line)
        }
        XCTAssertTrue(latex.contains("\\begin{bmatrix}"), file: file, line: line)
        XCTAssertTrue(latex.contains("="), file: file, line: line)
        guard case .paragraph(let tail) = doc.blocks[2].kind else {
            return XCTFail("expected tail paragraph", file: file, line: line)
        }
        XCTAssertEqual(tail.plainText, "Tail.", file: file, line: line)
        XCTAssertTrue(doc.outline.isEmpty, "phantom heading in outline: \(doc.outline)",
                      file: file, line: line)
        XCTAssertEqual(doc.stats.mathCount, 1, file: file, line: line)
    }

    private func assertEquivalentToFullParse(
        _ document: QuoinDocument, file: StaticString = #filePath, line: UInt = #line
    ) {
        let full = MarkdownConverter.parse(document.source)
        XCTAssertEqual(document.blocks, full.blocks, file: file, line: line)
        XCTAssertEqual(document.outline, full.outline, file: file, line: line)
        XCTAssertEqual(document.footnotes, full.footnotes, file: file, line: line)
        XCTAssertEqual(document.stats, full.stats, file: file, line: line)
        XCTAssertEqual(document.reviewMetadata, full.reviewMetadata, file: file, line: line)
    }

    // MARK: - The canonical repro

    func testMatrixWithBareEqualsLineIsOneMathBlock() {
        let doc = MarkdownConverter.parse(matrixSource)
        assertMatrixShape(doc)
        // Byte-lossless: the document IS the file, and the math block's
        // range maps back to the exact span bytes.
        XCTAssertEqual(doc.source, matrixSource)
        let span = matrixSource.substring(in: doc.blocks[1].range)
        XCTAssertEqual(span?.hasPrefix("\\[\n"), true)
        XCTAssertEqual(span?.hasSuffix("\n\\]"), true)
    }

    func testMatrixWithBareEqualsLineCRLF() {
        let crlf = matrixSource.replacingOccurrences(of: "\n", with: "\r\n")
        let doc = MarkdownConverter.parse(crlf)
        assertMatrixShape(doc)
        XCTAssertEqual(doc.source, crlf)
        let span = crlf.substring(in: doc.blocks[1].range)
        XCTAssertEqual(span?.hasPrefix("\\[\r\n"), true)
        XCTAssertEqual(span?.hasSuffix("\r\n\\]"), true)
    }

    func testBlockRangesCoverSource() {
        let doc = MarkdownConverter.parse(matrixSource)
        XCTAssertEqual(matrixSource.substring(in: doc.blocks[0].range), "Intro.")
        XCTAssertEqual(matrixSource.substring(in: doc.blocks[2].range), "Tail.")
        // Everything between consecutive block ranges is blank-line glue —
        // no content byte is orphaned by the pre-cmark split.
        var covered = doc.blocks[0].range
        for block in doc.blocks.dropFirst() {
            let gap = ByteRange(offset: covered.upperBound,
                                length: block.range.offset - covered.upperBound)
            let glue = matrixSource.substring(in: gap) ?? "?"
            XCTAssertTrue(glue.allSatisfy(\.isNewline), "unclaimed content between blocks: \(glue)")
            covered = block.range
        }
        XCTAssertEqual(covered.upperBound, matrixSource.utf8.count)
    }

    // MARK: - Delimiter and interior variants

    func testDollarFenceWithBareEqualsLine() {
        let source = "Intro.\n\n$$\na\n=\nb\n$$\n\nTail."
        let doc = MarkdownConverter.parse(source)
        XCTAssertEqual(doc.blocks.count, 3)
        guard case .mathBlock(let latex) = doc.blocks[1].kind else {
            return XCTFail("expected math block, got \(doc.blocks[1].kind)")
        }
        XCTAssertEqual(latex, "a\n=\nb")
        XCTAssertTrue(doc.outline.isEmpty)
        XCTAssertEqual(source.substring(in: doc.blocks[1].range), "$$\na\n=\nb\n$$")
    }

    func testEqualsLineWithTrailingSpaces() {
        // Setext underlines tolerate trailing whitespace, so `=  ` tears
        // exactly like a bare `=`.
        let source = "Intro.\n\n\\[\nx\n=  \ny\n\\]\n\nTail."
        let doc = MarkdownConverter.parse(source)
        XCTAssertEqual(doc.blocks.count, 3)
        guard case .mathBlock = doc.blocks[1].kind else {
            return XCTFail("expected math block, got \(doc.blocks[1].kind)")
        }
        XCTAssertTrue(doc.outline.isEmpty)
    }

    func testThematicBreakLookalikeInterior() {
        let source = "Intro.\n\n\\[\na\n---\nb\n\\]\n\nTail."
        let doc = MarkdownConverter.parse(source)
        XCTAssertEqual(doc.blocks.count, 3)
        guard case .mathBlock(let latex) = doc.blocks[1].kind else {
            return XCTFail("expected math block, got \(doc.blocks[1].kind)")
        }
        XCTAssertEqual(latex, "a\n---\nb")
        XCTAssertTrue(doc.outline.isEmpty)
    }

    func testMultipleSpansInOneDocument() {
        let source = "Intro.\n\n\\[\na\n=\nb\n\\]\n\nMiddle.\n\n$$\nc\n=\nd\n$$\n\nTail."
        let doc = MarkdownConverter.parse(source)
        XCTAssertEqual(doc.blocks.count, 5)
        guard case .mathBlock(let first) = doc.blocks[1].kind,
              case .mathBlock(let second) = doc.blocks[3].kind else {
            return XCTFail("expected two math blocks, got \(doc.blocks.map(\.kind))")
        }
        XCTAssertEqual(first, "a\n=\nb")
        XCTAssertEqual(second, "c\n=\nd")
        XCTAssertEqual(doc.stats.mathCount, 2)
        XCTAssertTrue(doc.outline.isEmpty)
        XCTAssertEqual(source.substring(in: doc.blocks[1].range), "\\[\na\n=\nb\n\\]")
        XCTAssertEqual(source.substring(in: doc.blocks[3].range), "$$\nc\n=\nd\n$$")
    }

    func testSpanAfterFrontMatterKeepsAbsoluteRanges() {
        let source = "---\ntitle: Doc\n---\n\n\\[\na\n=\nb\n\\]\n\nTail."
        let doc = MarkdownConverter.parse(source)
        guard case .frontMatter = doc.blocks[0].kind,
              case .mathBlock(let latex) = doc.blocks[1].kind else {
            return XCTFail("expected [frontMatter, math, …], got \(doc.blocks.map(\.kind))")
        }
        XCTAssertEqual(latex, "a\n=\nb")
        XCTAssertEqual(source.substring(in: doc.blocks[1].range), "\\[\na\n=\nb\n\\]")
        XCTAssertEqual(source.substring(in: doc.blocks[2].range), "Tail.")
        XCTAssertTrue(doc.outline.isEmpty)
    }

    // MARK: - Conservatism (never swallow prose)

    func testStrayUnclosedOpenerIsNotClaimed() {
        let source = "Intro.\n\n\\[\nnot math, just prose\n\nTail."
        let doc = MarkdownConverter.parse(source)
        XCTAssertFalse(doc.blocks.contains { if case .mathBlock = $0.kind { return true }; return false })
        XCTAssertEqual(doc.stats.mathCount, 0)
        // The stray delimiter stays literal, byte-lossless.
        XCTAssertEqual(doc.source, source)
    }

    func testCloserWithTrailingTextIsNotClaimed() {
        // Closer must be a line by itself; the prescan leaves this to the
        // existing paragraph-slice pass (inline math, not a block).
        let source = "\\[\nx = y\n\\] trailing prose"
        let doc = MarkdownConverter.parse(source)
        XCTAssertFalse(doc.blocks.contains { if case .mathBlock = $0.kind { return true }; return false })
    }

    func testBlankLineInsideSpanIsNotClaimed() {
        let source = "\\[\na\n\nb\n\\]"
        let doc = MarkdownConverter.parse(source)
        XCTAssertFalse(doc.blocks.contains { if case .mathBlock = $0.kind { return true }; return false })
    }

    func testIndentedOpenerIsNotClaimed() {
        let source = "Intro.\n\n  \\[\nx\n=\ny\n\\]\n\nTail."
        let doc = MarkdownConverter.parse(source)
        // Not at column 0 → prescan stays out (cmark still tears it; that
        // is the pre-existing behavior for decorated spans).
        XCTAssertEqual(DisplayMathPrescan.spans(in: source), [])
    }

    // MARK: - Incremental fast paths

    func testEditInsideClaimedBlockTakesFencedFastPath() throws {
        let previous = MarkdownConverter.parse(matrixSource)
        guard case .mathBlock = previous.blocks[1].kind else {
            return XCTFail("expected math block")
        }
        // Insert strictly inside the interior (after "\\[\n").
        let offset = previous.blocks[1].range.offset + "\\[\n".utf8.count
        let edit = SourceEdit(range: ByteRange(offset: offset, length: 0), replacement: "% note\n")
        let incremental = try MarkdownConverter.parseAfterEdit(previous: previous, edit: edit)
        XCTAssertEqual(incremental.strategy, .fencedBlockFastPath)
        assertEquivalentToFullParse(incremental.document)
        XCTAssertTrue(incremental.document.outline.isEmpty)
    }

    func testBlankLineTypedInsideClaimedBlockFallsBackToFullParse() throws {
        let previous = MarkdownConverter.parse(matrixSource)
        let offset = previous.blocks[1].range.offset + "\\[\n".utf8.count
        // A blank line breaks the span: the slice re-parse no longer
        // reproduces one math block, so the fast path must bail.
        let edit = SourceEdit(range: ByteRange(offset: offset, length: 0), replacement: "\n")
        let incremental = try MarkdownConverter.parseAfterEdit(previous: previous, edit: edit)
        XCTAssertEqual(incremental.strategy, .full)
        assertEquivalentToFullParse(incremental.document)
    }

    func testTypingDisplayOpenerIntoParagraphTakesFullParse() throws {
        // `\[` contains a backslash, which the plain-paragraph fast path's
        // safety charset forbids — the opener must never slip through a
        // slice-local re-parse that cannot see the span forming.
        let previous = MarkdownConverter.parse("Alpha beta gamma.\n\nTail paragraph.")
        let edit = SourceEdit(range: ByteRange(offset: "Alpha ".utf8.count, length: 0), replacement: "\\[")
        let incremental = try MarkdownConverter.parseAfterEdit(previous: previous, edit: edit)
        XCTAssertEqual(incremental.strategy, .full)
        assertEquivalentToFullParse(incremental.document)
    }

    // MARK: - Fenced code blocks are not math (review HIGH)

    func testDollarSpanInsideCodeFenceIsNotClaimed() {
        let source = "```text\n\n$$\nx\n$$\n\n```\n"
        let doc = MarkdownConverter.parse(source)
        XCTAssertEqual(doc.blocks.count, 1, "one code block, not code+math+code: \(doc.blocks.map(\.kind))")
        guard case .codeBlock(_, let code) = doc.blocks[0].kind else {
            return XCTFail("expected a code block, got \(doc.blocks[0].kind)")
        }
        XCTAssertTrue(code.contains("$$\nx\n$$"), "the $$ stays literal inside the fence")
        XCTAssertEqual(doc.stats.mathCount, 0)
        XCTAssertEqual(doc.source, source, "byte-lossless")
    }

    func testBracketSpanInsideMarkdownFenceIsNotClaimed() {
        let source = "How to write display math:\n\n```markdown\n\n\\[\n\\int_0^1 x\n\\]\n\n```\n\nThat's it.\n"
        let doc = MarkdownConverter.parse(source)
        let mathBlocks = doc.blocks.filter { if case .mathBlock = $0.kind { return true }; return false }
        XCTAssertTrue(mathBlocks.isEmpty, "no math claimed from inside the fence: \(doc.blocks.map(\.kind))")
        XCTAssertEqual(doc.source, source, "byte-lossless")
    }

    func testRealDisplayMathAfterACodeFenceStillClaimed() {
        // The fence must not poison a genuine span that follows it.
        let source = "```\ncode\n```\n\n$$\nx = 1\n$$\n\nDone.\n"
        let doc = MarkdownConverter.parse(source)
        let mathBlocks = doc.blocks.filter { if case .mathBlock = $0.kind { return true }; return false }
        XCTAssertEqual(mathBlocks.count, 1, "the post-fence span is still claimed")
    }

}
