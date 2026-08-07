#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Return inside a quote continues "> "; an empty quoted line exits the quote.
/// Return inside a table adds a ROW — never a blank line, which would terminate
/// the table.
final class QuoteAndTableReturnTests: XCTestCase {

    typealias C = MarkdownReaderView.Coordinator

    func testReturnInAQuoteCarriesThePrefixDown() {
        let e = C.quoteContinuationEdit(sourceText: "> hello", caretUTF16: 7)
        XCTAssertEqual(e?.replacement, "\n> ")
        XCTAssertEqual(e?.utf16Range, 7..<7)
    }

    func testReturnOnAnEmptyQuotedLineExitsTheQuote() {
        // "> a\n> " with the caret after the empty marker.
        let e = C.quoteContinuationEdit(sourceText: "> a\n> ", caretUTF16: 6)
        XCTAssertEqual(e?.replacement, "")
        XCTAssertEqual(e?.utf16Range, 4..<6, "the empty '> ' marker is removed")
    }

    func testNestedQuotePrefixIsPreserved() {
        let e = C.quoteContinuationEdit(sourceText: ">> deep", caretUTF16: 7)
        XCTAssertEqual(e?.replacement, "\n>> ")
    }

    func testNonQuoteLineIsNotOurs() {
        XCTAssertNil(C.quoteContinuationEdit(sourceText: "plain", caretUTF16: 5))
    }

    func testReturnAtTheEndOfARowAddsAnEmptyRow() {
        let table = "| a | b |\n| - | - |\n| 1 | 2 |"
        XCTAssertEqual(
            C.tableRowInsertion(sourceText: table, caretUTF16: (table as NSString).length),
            "\n|  |  |",
            "a new row must match the header's column count")
    }

    func testReturnMidRowIsAPlainNewline() {
        let table = "| a | b |\n| - | - |\n| 1 | 2 |"
        XCTAssertNil(C.tableRowInsertion(sourceText: table, caretUTF16: 3),
                     "mid-row Return falls through to a plain newline")
    }

    /// The whole reason tables are excluded from .paragraphBreak.
    func testTableInsertionNeverContainsABlankLine() {
        let table = "| a |\n| - |\n| 1 |"
        let out = C.tableRowInsertion(sourceText: table, caretUTF16: (table as NSString).length)
        XCTAssertFalse(out?.contains("\n\n") ?? false,
                       "a blank line would TERMINATE the table")
    }
}
#endif
