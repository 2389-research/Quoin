#if canImport(AppKit) || canImport(UIKit)
import XCTest
@testable import QuoinRender
import QuoinCore

/// Pure-logic coverage for `BlockAccessibility` — the block-kind → VoiceOver
/// announcement mapping and heading-level extraction (accessibility
/// structure, #10). No text system, no AppKit UI: just the derivation.
final class BlockAccessibilityTests: XCTestCase {

    // MARK: - Heading level

    func testHeadingLevelExtractedForHeadings() {
        for level in 1...6 {
            let kind = BlockKind.heading(level: level, inlines: [.text("X")], slug: "x")
            XCTAssertEqual(BlockAccessibility.headingLevel(for: kind), level)
        }
    }

    func testHeadingLevelNilForNonHeadings() {
        XCTAssertNil(BlockAccessibility.headingLevel(for: .paragraph(inlines: [.text("hi")])))
        XCTAssertNil(BlockAccessibility.headingLevel(for: .thematicBreak))
    }

    // MARK: - Heading announcement

    func testHeadingAnnouncementLeadsWithLevelThenTitle() {
        let kind = BlockKind.heading(level: 2, inlines: [.text("Introduction")], slug: "introduction")
        XCTAssertEqual(BlockAccessibility.announcement(for: kind), "Heading level 2, Introduction")
    }

    func testHeadingAnnouncementFlattensInlineFormatting() {
        // A heading with emphasis/code should read its plain text, not markup.
        let kind = BlockKind.heading(
            level: 1,
            inlines: [.text("The "), .strong([.text("big")]), .text(" idea")],
            slug: "the-big-idea")
        XCTAssertEqual(BlockAccessibility.announcement(for: kind), "Heading level 1, The big idea")
    }

    func testEmptyHeadingAnnouncesLevelOnly() {
        XCTAssertEqual(BlockAccessibility.headingAnnouncement(level: 3, title: "   "),
                       "Heading level 3")
        let kind = BlockKind.heading(level: 3, inlines: [], slug: "")
        XCTAssertEqual(BlockAccessibility.announcement(for: kind), "Heading level 3")
    }

    // MARK: - Structured blocks

    func testCodeBlockAnnouncesLanguageAndLineCount() {
        let kind = BlockKind.codeBlock(language: "swift", code: "let a = 1\nlet b = 2\n")
        XCTAssertEqual(BlockAccessibility.announcement(for: kind), "Code block, swift, 2 lines")
    }

    func testCodeBlockWithoutLanguageOrTrailingNewline() {
        let kind = BlockKind.codeBlock(language: nil, code: "one line")
        XCTAssertEqual(BlockAccessibility.announcement(for: kind), "Code block, 1 line")
    }

    func testCodeBlockBlankLanguageTreatedAsNone() {
        let kind = BlockKind.codeBlock(language: "   ", code: "x\n")
        XCTAssertEqual(BlockAccessibility.announcement(for: kind), "Code block, 1 line")
    }

    func testCodeBlockCRLFCountedAsOneLine() {
        // A line-walker that ignores \r\n would double-count; verify the
        // CRLF-normalizing count (project pitfall).
        let kind = BlockKind.codeBlock(language: "text", code: "a\r\nb\r\n")
        XCTAssertEqual(BlockAccessibility.announcement(for: kind), "Code block, text, 2 lines")
    }

    func testTableAnnouncesColumnsAndRows() {
        let header = [TableCell(inlines: [.text("A")]), TableCell(inlines: [.text("B")])]
        let rows = [
            [TableCell(inlines: [.text("1")]), TableCell(inlines: [.text("2")])],
            [TableCell(inlines: [.text("3")]), TableCell(inlines: [.text("4")])],
        ]
        let kind = BlockKind.table(header: header, rows: rows, alignments: [.none, .none])
        XCTAssertEqual(BlockAccessibility.announcement(for: kind), "Table, 2 columns, 2 rows")
    }

    func testSingularCountsDropTheS() {
        let header = [TableCell(inlines: [.text("A")])]
        let rows = [[TableCell(inlines: [.text("1")])]]
        let kind = BlockKind.table(header: header, rows: rows, alignments: [.none])
        XCTAssertEqual(BlockAccessibility.announcement(for: kind), "Table, 1 column, 1 row")
    }

    func testListAnnouncesOrdering() {
        let items = [ListItem(blocks: []), ListItem(blocks: [])]
        let ordered = BlockKind.list(items: items, ordered: true, start: 1)
        let bulleted = BlockKind.list(items: items, ordered: false, start: 1)
        XCTAssertEqual(BlockAccessibility.announcement(for: ordered), "Ordered list, 2 items")
        XCTAssertEqual(BlockAccessibility.announcement(for: bulleted), "Bulleted list, 2 items")
    }

    func testCalloutAnnouncesKind() {
        let kind = BlockKind.callout(kind: .warning, children: [])
        XCTAssertEqual(BlockAccessibility.announcement(for: kind), "Warning callout")
    }

    func testSimpleKindAnnouncements() {
        XCTAssertEqual(BlockAccessibility.announcement(for: .mermaid(source: "graph TD")), "Diagram")
        XCTAssertEqual(BlockAccessibility.announcement(for: .mathBlock(latex: "x^2")), "Equation")
        XCTAssertEqual(BlockAccessibility.announcement(for: .blockQuote(children: [])), "Block quote")
        XCTAssertEqual(BlockAccessibility.announcement(for: .thematicBreak), "Separator")
        XCTAssertEqual(BlockAccessibility.announcement(for: .tableOfContents), "Table of contents")
        XCTAssertEqual(BlockAccessibility.announcement(for: .frontMatter(yaml: "a: 1")), "Front matter")
        XCTAssertEqual(BlockAccessibility.announcement(for: .htmlBlock("<div>")), "HTML block")
    }

    func testSilentKinds() {
        // Prose and endmatter add no chrome announcement.
        XCTAssertNil(BlockAccessibility.announcement(for: .paragraph(inlines: [.text("hi")])))
        XCTAssertNil(BlockAccessibility.announcement(for: .reviewEndmatter(yaml: "comments: []")))
    }

    // MARK: - Attachment labels

    func testEquationLabelPrefixesSpokenMath() {
        XCTAssertEqual(
            BlockAccessibility.equationLabel(spokenDescription: "x squared"),
            "Equation, x squared")
        XCTAssertEqual(BlockAccessibility.equationLabel(spokenDescription: nil), "Equation")
        XCTAssertEqual(BlockAccessibility.equationLabel(spokenDescription: "   "), "Equation")
    }

    func testDiagramLabelUsesNarrationVerbatim() {
        // MermaidKit's narration already leads with the diagram type, so it is
        // NOT re-prefixed with "Diagram".
        XCTAssertEqual(
            BlockAccessibility.diagramLabel(narration: "Flowchart with 2 nodes and 1 connection: A, B."),
            "Flowchart with 2 nodes and 1 connection: A, B.")
        XCTAssertEqual(BlockAccessibility.diagramLabel(narration: nil), "Diagram")
        XCTAssertEqual(BlockAccessibility.diagramLabel(narration: ""), "Diagram")
    }
}
#endif
