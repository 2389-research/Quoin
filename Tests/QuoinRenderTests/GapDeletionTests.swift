#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Deletion must undo exactly what Return did: one blank line per Backspace,
/// and the last one merges the caret back to the end of the paragraph.
final class GapDeletionTests: XCTestCase {

    typealias C = MarkdownReaderView.Coordinator

    func testBackspaceOnABlankLineRemovesOneNewline() {
        // Slice "A\n\n" (two Returns pressed), caret on the second blank line.
        let d = C.gapDeletion(sourceText: "A\n\n", relCaret: 3, forward: false)
        XCTAssertEqual(d?.utf16Range, 2..<3)
        XCTAssertEqual(d?.caretUTF16, 2)
    }

    func testBackspaceOnTheLastBlankLineReturnsToTheParagraph() {
        let d = C.gapDeletion(sourceText: "A\n", relCaret: 2, forward: false)
        XCTAssertEqual(d?.utf16Range, 1..<2)
        XCTAssertEqual(d?.caretUTF16, 1, "caret lands at the end of 'A'")
    }

    func testBackspaceInsideContentIsNotOurs() {
        XCTAssertNil(C.gapDeletion(sourceText: "Hello", relCaret: 3, forward: false),
                     "ordinary deletion must fall through to the system")
    }

    func testForwardDeleteOnABlankLineIsSymmetric() {
        let d = C.gapDeletion(sourceText: "A\n\n", relCaret: 1, forward: true)
        XCTAssertEqual(d?.utf16Range, 1..<2)
        XCTAssertEqual(d?.caretUTF16, 1)
    }
}
#endif
