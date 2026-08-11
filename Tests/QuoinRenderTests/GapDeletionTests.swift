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

    /// CARET-1 symptom 3: Backspace at the content boundary of a block that has
    /// an absorbed trailing blank line must remove a NEWLINE (merge toward the
    /// canonical separator), NOT delete the last content glyph.
    func testBackspaceAtContentBoundaryRemovesNewlineNotContent() {
        // "# heading\n\n" — caret at offset 9 (end of "# heading"), trailing = 2.
        let d = C.gapDeletion(sourceText: "# heading\n\n", relCaret: 9, forward: false)
        XCTAssertEqual(d?.utf16Range, 9..<10, "must delete a newline, not the 'g' at 8..<9")
        XCTAssertEqual(d?.caretUTF16, 9)
    }

    /// The boundary-merge also fires with THREE+ trailing newlines: still an
    /// occupiable blank line hangs below, so remove the first one and merge.
    func testBackspaceAtContentBoundaryWithThreeTrailingNewlinesMerges() {
        let d = C.gapDeletion(sourceText: "Para\n\n\n", relCaret: 4, forward: false)
        XCTAssertEqual(d?.utf16Range, 4..<5, "remove the first trailing newline")
        XCTAssertEqual(d?.caretUTF16, 4)
    }

    // MARK: - Counter-tests: the boundary merge must NOT over-claim

    /// Ordinary end-of-content Backspace: a plain paragraph with content and NO
    /// trailing newline must still delete its last glyph — gapDeletion declines.
    func testBackspaceAtEndOfContentWithNoTrailingNewlineDeletesContent() {
        // "Hello" — caret at the content end (5), trailing = 0.
        XCTAssertNil(C.gapDeletion(sourceText: "Hello", relCaret: 5, forward: false),
                     "no absorbed blank line: the system deletes the 'o'")
    }

    /// A SINGLE trailing newline at the content boundary is the canonical
    /// terminator, not an occupiable blank line: Backspace deletes content.
    func testBackspaceAtContentBoundaryWithOneTrailingNewlineDeletesContent() {
        // "Hello\n" — caret at the content end (5), trailing = 1.
        XCTAssertNil(C.gapDeletion(sourceText: "Hello\n", relCaret: 5, forward: false),
                     "one trailing newline is the terminator, not a blank line to merge")
    }
}
#endif
