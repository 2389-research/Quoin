#if canImport(AppKit)
import XCTest
import QuoinCore
@testable import QuoinRender

/// Return continues a list/quote/checkbox marker (or ends the list on an empty
/// item) — the pure edit computation behind the coordinator's insertNewline
/// hook (#20). One UTF-16 span, one replacement, caret within it.
final class ListContinuationEditTests: XCTestCase {

    private typealias Coordinator = MarkdownReaderView.Coordinator

    func testUnorderedContinuation() throws {
        let edit = try XCTUnwrap(Coordinator.listContinuationEdit(sourceText: "- one", caretUTF16: 5))
        XCTAssertEqual(edit.utf16Range, 5..<5)
        XCTAssertEqual(edit.replacement, "\n- ")
        XCTAssertEqual(edit.caretUTF16, 3)
    }

    func testOrderedIncrements() throws {
        let edit = try XCTUnwrap(Coordinator.listContinuationEdit(sourceText: "1. first", caretUTF16: 8))
        XCTAssertEqual(edit.replacement, "\n2. ")
        let ten = try XCTUnwrap(Coordinator.listContinuationEdit(sourceText: "9) x", caretUTF16: 4))
        XCTAssertEqual(ten.replacement, "\n10) ")
    }

    func testCheckboxResetsToUnchecked() throws {
        let edit = try XCTUnwrap(Coordinator.listContinuationEdit(sourceText: "- [x] done", caretUTF16: 10))
        XCTAssertEqual(edit.replacement, "\n- [ ] ")
    }

    func testBlockquoteContinuation() throws {
        let edit = try XCTUnwrap(Coordinator.listContinuationEdit(sourceText: "> quote", caretUTF16: 7))
        XCTAssertEqual(edit.replacement, "\n> ")
    }

    func testIndentPreserved() throws {
        let edit = try XCTUnwrap(Coordinator.listContinuationEdit(sourceText: "  - nested", caretUTF16: 10))
        XCTAssertEqual(edit.replacement, "\n  - ")
    }

    func testEmptyItemEndsTheList() throws {
        // "- one\n- " — the trailing "- " is an empty item; Return removes it.
        let source = "- one\n- "
        let edit = try XCTUnwrap(Coordinator.listContinuationEdit(sourceText: source, caretUTF16: 8))
        XCTAssertEqual(edit.utf16Range, 6..<8, "delete the empty marker span")
        XCTAssertEqual(edit.replacement, "")
        XCTAssertEqual(edit.caretUTF16, 0)
    }

    func testMidLineSplitCarriesTheMarker() throws {
        // "- foobar" with caret after "- fo" → split, second line continues.
        let edit = try XCTUnwrap(Coordinator.listContinuationEdit(sourceText: "- foobar", caretUTF16: 4))
        XCTAssertEqual(edit.utf16Range, 4..<4)
        XCTAssertEqual(edit.replacement, "\n- ")
    }

    func testPlainProseFallsThrough() {
        XCTAssertNil(Coordinator.listContinuationEdit(sourceText: "plain text", caretUTF16: 10))
        XCTAssertNil(Coordinator.listContinuationEdit(sourceText: "-notalist", caretUTF16: 9))
    }

    func testCaretInsideMarkerFallsThrough() {
        // Caret between '-' and the space is inside the marker → plain newline.
        XCTAssertNil(Coordinator.listContinuationEdit(sourceText: "- one", caretUTF16: 1))
    }
}
#endif
