import XCTest
@testable import QuoinCore

/// Explicit, undoable cleanup — never automatic. Quoin is byte-lossless; a save
/// must never move the user's text.
final class BlankLineTidyTests: XCTestCase {

    func testCollapsesRunsOfBlankLinesToOne() {
        XCTAssertEqual(BlankLineTidy.tidied("A\n\n\n\n\nB"), "A\n\nB")
    }

    func testLeavesCanonicalSpacingAlone() {
        XCTAssertEqual(BlankLineTidy.tidied("A\n\nB"), "A\n\nB")
    }

    func testNeverTouchesCodeBlockInteriors() {
        let src = "```\nx\n\n\n\ny\n```\n"
        XCTAssertEqual(BlankLineTidy.tidied(src), src,
                       "blank lines inside a fence are content, not spacing")
    }

    func testNormalizesCRLFRunsWithoutMangling() {
        XCTAssertEqual(BlankLineTidy.tidied("A\r\n\r\n\r\n\r\nB"), "A\r\n\r\nB")
    }
}
