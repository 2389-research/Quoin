import XCTest
@testable import QuoinCore

final class FrontMatterTests: XCTestCase {

    func testFrontMatterExtracted() {
        let source = """
        ---
        title: Test Doc
        tags: [a, b]
        ---

        # Heading

        Body.
        """
        let doc = MarkdownConverter.parse(source)
        guard case .frontMatter(let yaml) = doc.blocks[0].kind else {
            return XCTFail("expected front matter, got \(doc.blocks[0].kind)")
        }
        XCTAssertTrue(yaml.contains("title: Test Doc"))
        XCTAssertEqual(doc.outline.first?.title, "Heading")
    }

    func testRangesStayAbsoluteAfterFrontMatter() {
        let source = "---\nkey: value\n---\n\n# Title\n\n- [ ] task"
        let doc = MarkdownConverter.parse(source)
        // The heading's range must point at "# Title" in the FULL source.
        XCTAssertEqual(source.substring(in: doc.blocks[1].range), "# Title")
        // Task write-back depends on absolute marker offsets.
        guard case .list(let items, _, _) = doc.blocks[2].kind,
              let marker = items[0].taskMarkerRange else {
            return XCTFail("expected task list")
        }
        XCTAssertEqual(source.substring(in: marker), "[ ]")
    }

    func testSubstringRejectsRangesSplittingMultibyteScalars() {
        // "é" is 2 UTF-8 bytes, "☕️" is 6, "😀" is 4. A range must land on
        // scalar boundaries or the helper returns nil rather than a lossy
        // string full of replacement characters.
        let source = "aé😀b"                     // bytes: a | éé | 😀😀😀😀 | b
        let bytes = Array(source.utf8)
        XCTAssertEqual(bytes.count, 8)

        // Whole string and clean boundaries round-trip.
        XCTAssertEqual(source.substring(in: ByteRange(offset: 0, length: 8)), "aé😀b")
        XCTAssertEqual(source.substring(in: ByteRange(offset: 1, length: 2)), "é")
        XCTAssertEqual(source.substring(in: ByteRange(offset: 3, length: 4)), "😀")

        // Splitting the middle of "é" (offset 1, len 2) or "😀" must fail.
        XCTAssertNil(source.substring(in: ByteRange(offset: 0, length: 2)), "splits é")
        XCTAssertNil(source.substring(in: ByteRange(offset: 2, length: 2)), "starts mid-é")
        XCTAssertNil(source.substring(in: ByteRange(offset: 3, length: 2)), "splits 😀")
        XCTAssertNil(source.substring(in: ByteRange(offset: 5, length: 3)), "starts mid-😀")

        // Out-of-bounds and negative ranges stay nil.
        XCTAssertNil(source.substring(in: ByteRange(offset: 6, length: 5)))
        XCTAssertNil(source.substring(in: ByteRange(offset: -1, length: 2)))
    }

    func testNoFrontMatterWithoutClosingDelimiter() {
        let doc = MarkdownConverter.parse("---\nnot closed\n\ntext")
        if case .frontMatter = doc.blocks.first?.kind {
            XCTFail("unterminated front matter must parse as content")
        }
    }

    func testPlainLeadingThematicBreakIsNotFrontMatter() {
        let doc = MarkdownConverter.parse("regular paragraph\n\n---\n\nmore")
        if case .frontMatter = doc.blocks.first?.kind {
            XCTFail("mid-document --- is not front matter")
        }
    }
}

final class HighlightTests: XCTestCase {

    func testSimpleHighlight() {
        let doc = MarkdownConverter.parse("This is ==important== text.")
        guard case .paragraph(let inlines) = doc.blocks[0].kind else {
            return XCTFail("expected paragraph")
        }
        XCTAssertTrue(inlines.contains(.highlight([.text("important")], .lime)))
        XCTAssertEqual(doc.stats.highlightCount, 1)
    }

    func testHighlightSpanningFormatting() {
        let doc = MarkdownConverter.parse("a ==with **bold** inside== b")
        guard case .paragraph(let inlines) = doc.blocks[0].kind else {
            return XCTFail("expected paragraph")
        }
        let highlighted = inlines.compactMap { inline -> [Inline]? in
            if case .highlight(let children, _) = inline { return children }
            return nil
        }
        XCTAssertEqual(highlighted.count, 1)
        XCTAssertEqual(highlighted[0].plainText, "with bold inside")
    }

    func testUnclosedHighlightStaysLiteral() {
        let doc = MarkdownConverter.parse("this ==never closes")
        guard case .paragraph(let inlines) = doc.blocks[0].kind else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(doc.stats.highlightCount, 0)
        XCTAssertEqual(inlines.plainText, "this ==never closes")
    }

    func testEqualsWithSpacesIsNotHighlight() {
        let doc = MarkdownConverter.parse("a == b == c")
        XCTAssertEqual(doc.stats.highlightCount, 0)
    }
}

final class CalloutTests: XCTestCase {

    func testNoteCallout() {
        let doc = MarkdownConverter.parse("> [!NOTE]\n> Something worth knowing.")
        guard case .callout(let kind, let children) = doc.blocks[0].kind else {
            return XCTFail("expected callout, got \(doc.blocks[0].kind)")
        }
        XCTAssertEqual(kind, .note)
        XCTAssertEqual(children.count, 1)
        guard case .paragraph(let inlines) = children[0].kind else {
            return XCTFail("expected paragraph in callout")
        }
        XCTAssertEqual(inlines.plainText.trimmingCharacters(in: .whitespaces), "Something worth knowing.")
    }

    func testAllCalloutKinds() {
        // GitHub's five alert types keep distinct kinds; INFO/HINT/ERROR are
        // accepted aliases.
        let cases: [(String, CalloutKind)] = [
            ("NOTE", .note), ("INFO", .note),
            ("TIP", .tip), ("HINT", .tip),
            ("IMPORTANT", .important),
            ("WARNING", .warning),
            ("CAUTION", .caution),
            ("DANGER", .danger), ("ERROR", .danger),
        ]
        for (marker, expected) in cases {
            let doc = MarkdownConverter.parse("> [!\(marker)]\n> body")
            guard case .callout(let kind, _) = doc.blocks[0].kind else {
                return XCTFail("expected callout for \(marker)")
            }
            XCTAssertEqual(kind, expected, marker)
        }
    }

    func testPlainBlockQuoteUnaffected() {
        let doc = MarkdownConverter.parse("> just a quote")
        guard case .blockQuote = doc.blocks[0].kind else {
            return XCTFail("expected plain block quote")
        }
    }
}

final class FootnoteTests: XCTestCase {

    func testReferenceAndDefinition() {
        let doc = MarkdownConverter.parse("""
        Some claim.[^src]

        [^src]: The source of the claim.
        """)
        guard case .paragraph(let inlines) = doc.blocks[0].kind else {
            return XCTFail("expected paragraph")
        }
        XCTAssertTrue(inlines.contains(.footnoteReference(id: "src", index: 1)))
        // The definition paragraph is removed from the block flow.
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.footnotes.count, 1)
        XCTAssertEqual(doc.footnotes[0].id, "src")
        XCTAssertEqual(doc.footnotes[0].index, 1)
        XCTAssertEqual(doc.footnotes[0].blocks.first.map { block -> String in
            if case .paragraph(let inlines) = block.kind { return inlines.plainText }
            return ""
        }, "The source of the claim.")
        XCTAssertEqual(doc.stats.footnoteCount, 1)
    }

    func testOrdinalsAssignedInReferenceOrder() {
        let doc = MarkdownConverter.parse("""
        First[^b] then[^a] then[^b] again.

        [^a]: Definition A.
        [^b]: Definition B.
        """)
        XCTAssertEqual(doc.footnotes.map(\.id), ["b", "a"])
        XCTAssertEqual(doc.footnotes.map(\.index), [1, 2])
    }

    func testMissingDefinitionGetsPlaceholder() {
        let doc = MarkdownConverter.parse("Claim.[^ghost]")
        XCTAssertEqual(doc.footnotes.count, 1)
        XCTAssertEqual(doc.footnotes[0].id, "ghost")
    }

    /// Adjacent `[^id]:` lines share ONE cmark paragraph; each must still
    /// yield its own definition (the second used to be swallowed into the
    /// first's content and re-spliced as a bogus reference).
    func testAdjacentDefinitionLinesEachKeepTheirContent() {
        let doc = MarkdownConverter.parse("""
        One[^a] and two[^b].

        [^a]: Definition A
        continued on a second line.
        [^b]: Definition B.
        """)
        func body(_ footnote: Footnote) -> String {
            footnote.blocks.compactMap { block -> String? in
                if case .paragraph(let inlines) = block.kind { return inlines.plainText }
                return nil
            }.joined(separator: "\n")
        }
        XCTAssertEqual(doc.footnotes.map(\.id), ["a", "b"])
        XCTAssertEqual(doc.footnotes.first.map(body), "Definition A continued on a second line.")
        XCTAssertEqual(doc.footnotes.last.map(body), "Definition B.")
    }
}

final class TOCBlockTests: XCTestCase {

    func testTOCMarker() {
        let doc = MarkdownConverter.parse("[TOC]\n\n# One\n\n## Two")
        guard case .tableOfContents = doc.blocks[0].kind else {
            return XCTFail("expected TOC block, got \(doc.blocks[0].kind)")
        }
        XCTAssertEqual(doc.outline.count, 2)
    }

    func testInlineTocMentionIsNotABlock() {
        let doc = MarkdownConverter.parse("see the [TOC] for details")
        guard case .paragraph = doc.blocks[0].kind else {
            return XCTFail("expected paragraph")
        }
    }
}

final class SyntaxHighlighterTests: XCTestCase {

    private func kinds(_ code: String, _ language: String, at word: String) -> SyntaxTokenKind? {
        let chars = Array(code)
        guard let range = code.range(of: word) else { return nil }
        let start = code.distance(from: code.startIndex, to: range.lowerBound)
        _ = chars
        return SyntaxHighlighter.highlight(code: code, language: language)
            .first { $0.range.lowerBound == start }?.kind
    }

    func testSwiftTokens() {
        let code = "func greet(name: String) -> String { // say hi\n    return \"hi \\(name)\" }"
        XCTAssertEqual(kinds(code, "swift", at: "func"), .keyword)
        XCTAssertEqual(kinds(code, "swift", at: "greet"), .function)
        XCTAssertEqual(kinds(code, "swift", at: "String"), .type)
        XCTAssertEqual(kinds(code, "swift", at: "// say hi"), .comment)
        XCTAssertEqual(kinds(code, "swift", at: "\"hi \\(name)\""), .string)
    }

    func testPythonComment() {
        XCTAssertEqual(kinds("x = 1 # note", "python", at: "# note"), .comment)
    }

    func testNumbers() {
        let tokens = SyntaxHighlighter.highlight(code: "let x = 42", language: "swift")
        XCTAssertTrue(tokens.contains { $0.kind == .number })
    }

    func testUnknownLanguageStillScansStrings() {
        let tokens = SyntaxHighlighter.highlight(code: "say \"hello\"", language: "klingon")
        XCTAssertTrue(tokens.contains { $0.kind == .string })
    }
}
