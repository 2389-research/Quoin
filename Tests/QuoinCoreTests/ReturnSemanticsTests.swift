import XCTest
@testable import QuoinCore

/// THE Return rule table. One switch, exhaustive, so adding a BlockKind forces
/// a deliberate decision instead of silently inheriting paragraph behavior.
final class ReturnSemanticsTests: XCTestCase {

    func testProseGetsAParagraphBreak() {
        XCTAssertEqual(ReturnSemantics.mode(for: .paragraph(inlines: [])), .paragraphBreak)
        XCTAssertEqual(
            ReturnSemantics.mode(for: .heading(level: 1, inlines: [], slug: "h")),
            .paragraphBreak)
    }

    /// The load-bearing case: a blank line TERMINATES a markdown table, so a
    /// paragraph break here would destroy the user's table.
    func testTableNeverGetsAParagraphBreak() {
        let table = BlockKind.table(header: [], rows: [], alignments: [])
        XCTAssertEqual(ReturnSemantics.mode(for: table), .tableRow)
        XCTAssertNotEqual(ReturnSemantics.mode(for: table), .paragraphBreak)
    }

    func testVerbatimKindsGetAPlainNewline() {
        XCTAssertEqual(ReturnSemantics.mode(for: .codeBlock(language: nil, code: "")), .verbatim)
        XCTAssertEqual(ReturnSemantics.mode(for: .mathBlock(latex: "")), .verbatim)
        XCTAssertEqual(ReturnSemantics.mode(for: .htmlBlock("")), .verbatim)
        XCTAssertEqual(ReturnSemantics.mode(for: .frontMatter(yaml: "")), .verbatim)
        XCTAssertEqual(ReturnSemantics.mode(for: .reviewEndmatter(yaml: "")), .verbatim)
    }

    func testListAndQuoteContinue() {
        XCTAssertEqual(
            ReturnSemantics.mode(for: .list(items: [], ordered: false, start: 1)), .listAware)
        XCTAssertEqual(ReturnSemantics.mode(for: .blockQuote(children: [])), .quoteAware)
        XCTAssertEqual(
            ReturnSemantics.mode(for: .callout(kind: .note, children: [])), .quoteAware,
            "a callout is a '> [!NOTE]' quote — it continues like one")
    }
}
