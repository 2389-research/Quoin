#if canImport(AppKit)
import XCTest
import AppKit
@testable import QuoinEditorKit

@MainActor
final class HarnessSmokeTests: XCTestCase {
    func testTypingLandsAndCaretIsARealBar() {
        let h = EditorTestHarness()
        h.type("# Heading")
        h.quiesce()
        XCTAssertEqual(h.textView.string, "# Heading")
        XCTAssertEqual(h.appliedRevision, 9)              // one bump per inserted character
        h.assertInsertionBar(minHeight: 8, file: #filePath, line: #line)   // NOT a 2pt dot
    }
    func testReturnAndBackspaceDrive() {
        let h = EditorTestHarness()
        h.type("ab"); h.pressReturn(); h.type("c"); h.quiesce()
        XCTAssertEqual(h.textView.string, "ab\nc")
        h.pressBackspace(); h.pressBackspace(); h.quiesce()   // delete "c" and the newline
        XCTAssertEqual(h.textView.string, "ab")
    }
    func testCaretRectIsNonEmptyAfterQuiesce() {
        let h = EditorTestHarness(); h.type("x"); h.quiesce()
        XCTAssertGreaterThan(h.caretRect.height, 0)
    }
}
#endif
