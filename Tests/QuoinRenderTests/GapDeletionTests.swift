#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Deletion must undo exactly what Return did: one blank line per Backspace,
/// and the last one merges the caret back to the end of the paragraph.
final class GapDeletionTests: XCTestCase {

    typealias C = MarkdownReaderView.Coordinator

    func testBackspaceOnTheFirstBlankLineUndoesTheReturnInOnePress() {
        // "A\n\n" is ONE Return from content (inserts "\n\n"). Backspace from the
        // blank line must UNDO it in one press — remove BOTH newlines → "A".
        let d = C.gapDeletion(sourceText: "A\n\n", relCaret: 3, forward: false)
        XCTAssertEqual(d?.utf16Range, 1..<3, "symmetry: one Return, one Backspace")
        XCTAssertEqual(d?.caretUTF16, 1)
    }

    func testBackspaceOnADeeperBlankLineRemovesOneNewline() {
        // "A\n\n\n" is TWO Returns (first "\n\n", then "\n"). Backspace from the
        // last blank line undoes the SECOND Return — remove one → "A\n\n".
        let d = C.gapDeletion(sourceText: "A\n\n\n", relCaret: 4, forward: false)
        XCTAssertEqual(d?.utf16Range, 3..<4)
        XCTAssertEqual(d?.caretUTF16, 3)
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

    // MARK: - INTERIM data-loss guard: caret stranded in content above a blank line

    /// THE reported corruption: `# How to do things\n\n` with the caret stranded
    /// at 17 (inside the heading, before the "s") while an occupiable blank line
    /// hangs below. A native Backspace would eat the "g". The guard fires.
    func testStrandedCaretInsideHeadingContentIsGuarded() {
        XCTAssertTrue(
            C.caretStrandedAboveBlankLine(sourceText: "# How to do things\n\n", relCaret: 17),
            "caret inside content with an occupiable blank line below must be guarded")
    }

    /// The guard must NOT hijack an ordinary mid-content Backspace when there is
    /// no occupiable blank line (no trailing blanks).
    func testMidContentBackspaceWithoutTrailingBlankIsNotGuarded() {
        XCTAssertFalse(
            C.caretStrandedAboveBlankLine(sourceText: "# How to do things", relCaret: 17),
            "no trailing blank line: a real content Backspace must pass through")
    }

    /// A single trailing newline (canonical terminator) is not an occupiable
    /// blank line — the guard stays out of the way.
    func testMidContentWithSingleTrailingNewlineIsNotGuarded() {
        XCTAssertFalse(
            C.caretStrandedAboveBlankLine(sourceText: "# Heading\n", relCaret: 4),
            "one trailing newline is the terminator, not a blank line")
    }

    /// The caret genuinely ON the blank line (in the trailing run) is handled by
    /// gapDeletion, not the strand guard.
    func testCaretOnBlankLineIsNotStranded() {
        XCTAssertFalse(
            C.caretStrandedAboveBlankLine(sourceText: "# How to do things\n\n", relCaret: 20),
            "the caret on the blank line is gapDeletion's job, not the strand guard")
    }
}
#endif
