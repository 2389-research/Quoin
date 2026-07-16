import XCTest
@testable import QuoinCore

/// CriticMarkup parsing (suggestions design, S1): the five marks, RDFM id
/// references, byte-exact ranges (accept/reject in S2 splices exactly those
/// bytes), literal-degradation for everything unbalanced, and the opacity
/// guards (code and math never grow marks).
final class SuggestionParsingTests: XCTestCase {

    private func suggestions(in source: String) -> [(kind: SuggestionKind, range: ByteRange, id: String?)] {
        let document = MarkdownConverter.parse(source)
        var found: [(SuggestionKind, ByteRange, String?)] = []
        func walk(_ inlines: [Inline]) {
            for inline in inlines {
                if case .suggestion(let kind, let range, let id) = inline {
                    found.append((kind, range, id))
                }
            }
        }
        for block in document.blocks {
            if case .paragraph(let inlines) = block.kind { walk(inlines) }
        }
        return found
    }

    // MARK: - The five marks

    func testAllFiveMarksParse() throws {
        let source = "Alpha {++added++} beta {--removed--} gamma {~~old~>new~~} " +
                     "delta {>>a note<<} epsilon {==flagged==} omega.\n"
        let found = suggestions(in: source)
        XCTAssertEqual(found.count, 5)

        guard case .insertion(let ins) = found[0].kind else { return XCTFail("insertion") }
        XCTAssertEqual(ins.plainText, "added")
        guard case .deletion(let del) = found[1].kind else { return XCTFail("deletion") }
        XCTAssertEqual(del.plainText, "removed")
        guard case .substitution(let old, let new) = found[2].kind else { return XCTFail("substitution") }
        XCTAssertEqual(old.plainText, "old")
        XCTAssertEqual(new.plainText, "new")
        guard case .comment(let comment) = found[3].kind else { return XCTFail("comment") }
        XCTAssertEqual(comment, "a note")
        guard case .highlight(let hl) = found[4].kind else { return XCTFail("highlight") }
        XCTAssertEqual(hl.plainText, "flagged")

        // Stats count them.
        XCTAssertEqual(MarkdownConverter.parse(source).stats.suggestionCount, 5)
    }

    func testByteRangesAreAbsoluteAndExact() throws {
        let source = "Lead paragraph.\n\nAlpha {++added++} tail.\n"
        let found = suggestions(in: source)
        XCTAssertEqual(found.count, 1)
        let range = found[0].range
        let bytes = Array(source.utf8)
        let mark = String(decoding: bytes[range.offset..<(range.offset + range.length)], as: UTF8.self)
        XCTAssertEqual(mark, "{++added++}", "the range must cover the whole mark, absolutely positioned")
    }

    func testRDFMIdReferenceAttachesAndIsInsideTheRange() throws {
        let source = "See {==this sentence==}{>>Needs a source.<<}{#c1} here.\n"
        let found = suggestions(in: source)
        XCTAssertEqual(found.count, 2)
        guard case .highlight = found[0].kind else { return XCTFail("highlight first") }
        XCTAssertNil(found[0].id)
        guard case .comment = found[1].kind else { return XCTFail("comment second") }
        XCTAssertEqual(found[1].id, "c1")
        // The id reference is part of the comment mark's byte range.
        let bytes = Array(source.utf8)
        let r = found[1].range
        XCTAssertTrue(String(decoding: bytes[r.offset..<(r.offset + r.length)], as: UTF8.self)
            .hasSuffix("{#c1}"))
    }

    func testMarkChildrenParseAsMarkdown() throws {
        let found = suggestions(in: "X {++has **bold** inside++} y.\n")
        guard case .insertion(let children) = found[0].kind else { return XCTFail() }
        XCTAssertTrue(children.contains { if case .strong = $0 { return true }; return false },
                      "mark bodies re-parse as inline markdown")
    }

    // MARK: - Degradation & opacity (never half-eat)

    func testUnbalancedMarksStayLiteral() throws {
        for source in ["An {++unclosed insertion.\n",
                       "A {~~substitution without arrow~~} here.\n",
                       "Stray closer ++} alone.\n"] {
            XCTAssertTrue(suggestions(in: source).isEmpty, "must degrade to literal: \(source)")
            // And the text survives as plain text (not swallowed).
            let document = MarkdownConverter.parse(source)
            XCTAssertEqual(document.blocks.count, 1)
        }
    }

    func testMarksInsideInlineCodeStayLiteral() throws {
        XCTAssertTrue(suggestions(in: "Use `{++literal++}` in code.\n").isEmpty)
        // …and a fenced block never reaches the paragraph path at all.
        let fenced = MarkdownConverter.parse("```\n{--not a mark--}\n```\n")
        XCTAssertEqual(fenced.stats.suggestionCount, 0)
    }

    func testMarksInsideMathStayLiteralAndMathSurvivesOutsideMarks() throws {
        // Inside math: opaque.
        XCTAssertTrue(suggestions(in: "Math $a {++b++} c$ here.\n").isEmpty)
        // Outside marks, math still parses on the same routed slice.
        let source = "Formula $x^2$ and {++an edit++} together.\n"
        let document = MarkdownConverter.parse(source)
        XCTAssertEqual(document.stats.suggestionCount, 1)
        XCTAssertEqual(document.stats.mathCount, 1)
    }

    func testSubstitutionOldMayContainBareGreaterThan() throws {
        // The reference toolkit's regex bug (a bare `>` in the old half
        // fails to parse) is deliberately NOT reproduced.
        let found = suggestions(in: "Check {~~a > b~>a ≥ b~~} please.\n")
        XCTAssertEqual(found.count, 1)
        guard case .substitution(let old, let new) = found[0].kind else { return XCTFail() }
        XCTAssertEqual(old.plainText, "a > b")
        XCTAssertEqual(new.plainText, "a ≥ b")
    }

    // MARK: - Losslessness & search

    func testParseNeverRewritesTheSource() throws {
        let source = "A {++b++} c {--d--} e {~~f~>g~~} h {>>i<<} j {==k==}.\n"
        XCTAssertEqual(MarkdownConverter.parse(source).source, source)
    }

    func testPlainTextProjectionFindsBothSubstitutionHalves() throws {
        let document = MarkdownConverter.parse("We {~~cannot~>can~~} ship.\n")
        guard case .paragraph(let inlines) = document.blocks[0].kind else { return XCTFail() }
        let plain = inlines.plainText
        XCTAssertTrue(plain.contains("cannot") && plain.contains("can"),
                      "search must find both halves")
        // Comments are annotations, not document text.
        let commented = MarkdownConverter.parse("Text {>>secret note<<} here.\n")
        guard case .paragraph(let inlines2) = commented.blocks[0].kind else { return XCTFail() }
        XCTAssertFalse(inlines2.plainText.contains("secret"))
    }

    // MARK: - Pathology (the torture philosophy)

    func testMarkBombParsesToSomething() throws {
        let bomb = String(repeating: "{++x++} ", count: 2000) + "\n"
        let document = MarkdownConverter.parse(bomb)
        XCTAssertEqual(document.stats.suggestionCount, 2000)
        let openerBomb = String(repeating: "{++", count: 2000) + "\n"
        XCTAssertFalse(MarkdownConverter.parse(openerBomb).blocks.isEmpty)
    }
}

// MARK: - Boundary whitespace (live redline, 2026-07-14 screenshots)

extension SuggestionParsingTests {
    /// The glue bug: segment re-parsing trimmed boundary spaces, rendering
    /// "a plain {++portable++} markdown" as "a plainportablemarkdown".
    func testWhitespaceAroundMarksSurvives() throws {
        let document = MarkdownConverter.parse("a plain {++portable++} markdown file\n")
        guard case .paragraph(let inlines) = document.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(inlines.plainText, "a plain portable markdown file")
    }

    /// Same mechanism, pre-existing on the MATH path: "We $x$ promise".
    func testWhitespaceAroundInlineMathSurvives() throws {
        let document = MarkdownConverter.parse("We $x^2$ promise results\n")
        guard case .paragraph(let inlines) = document.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(inlines.plainText, "We x^2 promise results")
    }

    /// A mark at line end: the newline boundary is a soft break, not glue.
    func testNewlineBoundaryBecomesSoftBreak() throws {
        let document = MarkdownConverter.parse("start {++x++}\nnext line\n")
        guard case .paragraph(let inlines) = document.blocks[0].kind else { return XCTFail() }
        XCTAssertEqual(inlines.plainText, "start x next line")
    }

    // MARK: - Dollar amounts vs math opacity (panel review, HIGH)

    func testMarkBetweenTwoDollarAmountsIsParsed() throws {
        // The naive $-to-$ skip treated "$5 … $10" as one opaque math span
        // and swallowed the mark between the amounts. MathScanner's rules
        // (closer can't follow whitespace / precede a digit) say this is
        // currency — the critic scanner must agree.
        let source = "It costs $5 and {++definitely++} later $10 total.\n"
        let document = MarkdownConverter.parse(source)
        let marks = SuggestionResolver.marks(in: document)
        XCTAssertEqual(marks.count, 1, "the mark must survive the dollar amounts")
        XCTAssertEqual(document.stats.mathCount, 0, "and no phantom math span")
    }

    func testMarkAfterASingleDollarAmountIsParsed() throws {
        let source = "Pay $20 then {--remove me--} please.\n"
        let marks = SuggestionResolver.marks(in: MarkdownConverter.parse(source))
        XCTAssertEqual(marks.count, 1)
    }

    func testMarkInsideRealInlineMathStaysOpaque() throws {
        // A genuine $a … b$ span: marks inside stay literal (RDFM rule).
        let source = "Real math $a {++x++} b$ here.\n"
        let document = MarkdownConverter.parse(source)
        XCTAssertTrue(SuggestionResolver.marks(in: document).isEmpty,
                      "mark inside a real math span is opaque")
        XCTAssertEqual(document.stats.mathCount, 1)
    }

    func testMarkAfterUnclosedDisplayDollarsIsParsed() throws {
        let source = "Costs $$ literally, and {++yes++} indeed.\n"
        let marks = SuggestionResolver.marks(in: MarkdownConverter.parse(source))
        XCTAssertEqual(marks.count, 1)
    }

}
