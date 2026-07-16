import XCTest
@testable import QuoinCore

/// Review Mode's keystroke transform (S3b): stateless coalescing —
/// a fresh keystroke mints a mark and parks the caret inside; the next
/// one is a plain edit that grows it.
final class SuggestTransformTests: XCTestCase {

    private func applying(_ outcome: SuggestTransform.Outcome, to slice: String,
                          originalRange: ByteRange, originalReplacement: String) -> String {
        var bytes = Array(slice.utf8)
        switch outcome {
        case .plain:
            bytes.replaceSubrange(
                originalRange.offset..<(originalRange.offset + originalRange.length),
                with: Array(originalReplacement.utf8))
        case .transformed(let range, let replacement, _):
            bytes.replaceSubrange(
                range.offset..<(range.offset + range.length),
                with: Array(replacement.utf8))
        case .refused:
            XCTFail("refused unexpectedly")
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Insertion coalescing

    func testTypingMintsAMarkThenGrowsIt() {
        let slice = "Alpha beta."
        // First keystroke at offset 6: "h"
        let first = SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 6, length: 0), replacement: "h", in: slice)
        guard case .transformed(let range, let replacement, let caret) = first else {
            return XCTFail("expected transform, got \(first)")
        }
        XCTAssertEqual(replacement, "{++h++}")
        XCTAssertEqual(caret, 4, "caret inside the body, after h")
        let after = applying(first, to: slice, originalRange: range, originalReplacement: replacement)
        XCTAssertEqual(after, "Alpha {++h++}beta.")

        // Second keystroke lands INSIDE the body (offset 6+4=10): plain.
        let second = SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 10, length: 0), replacement: "i", in: after)
        XCTAssertEqual(second, .plain, "growing the fresh mark is a plain edit")
        XCTAssertEqual(
            applying(second, to: after, originalRange: ByteRange(offset: 10, length: 0),
                     originalReplacement: "i"),
            "Alpha {++hi++}beta.")
    }

    func testTypingAtBodyEdgesGrows() {
        let slice = "A {++mid++} z."
        // Right after "{++" (offset 5) and right before "++}" (offset 8).
        XCTAssertEqual(SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 5, length: 0), replacement: "x", in: slice), .plain)
        XCTAssertEqual(SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 8, length: 0), replacement: "x", in: slice), .plain)
    }

    func testTypingInsideSigilsRefuses() {
        let slice = "A {++mid++} z."
        // Between the two + of the opener (offset 2 is "{", 3 "+", 4 "+").
        let outcome = SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 4, length: 0), replacement: "x", in: slice)
        XCTAssertEqual(outcome, .refused, "never tear a sigil")
    }

    func testNewlineRefuses() {
        XCTAssertEqual(SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 3, length: 0), replacement: "\n", in: "Prose here."),
            .refused, "structural edits aren't suggestions in v1")
    }

    // MARK: - Deletion

    func testDeleteWrapsAsDeletionMark() {
        let slice = "Alpha beta gamma."
        let outcome = SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 6, length: 5), replacement: "", in: slice)
        guard case .transformed(_, let replacement, let caret) = outcome else {
            return XCTFail("\(outcome)")
        }
        XCTAssertEqual(replacement, "{--beta --}")
        XCTAssertEqual(caret, replacement.utf8.count, "caret after the mark")
    }

    func testBackspaceAfterDeletionMarkExtendsIt() {
        let slice = "Alpha x{--beta--} rest."
        // Caret sits right after "--}" (offset 17); backspace deletes 16..<17.
        let outcome = SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 16, length: 1), replacement: "", in: slice)
        guard case .transformed(let range, let replacement, _) = outcome else {
            return XCTFail("\(outcome)")
        }
        XCTAssertEqual(range, ByteRange(offset: 6, length: 11), "x + the whole old mark")
        XCTAssertEqual(replacement, "{--xbeta--}", "the preceding char joins the deletion")
    }

    func testBackspaceInsideOwnInsertionShrinksPlainly() {
        let slice = "A {++hi++} z."
        // Delete the "i" (offset 6..<7) — inside the body.
        XCTAssertEqual(SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 6, length: 1), replacement: "", in: slice), .plain)
    }

    func testEmptyingAnInsertionRemovesTheWholeMark() {
        let slice = "A {++hi++} z."
        let outcome = SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 5, length: 2), replacement: "", in: slice)
        guard case .transformed(let range, let replacement, _) = outcome else {
            return XCTFail("\(outcome)")
        }
        XCTAssertEqual(range, ByteRange(offset: 2, length: 8), "the whole {++hi++}")
        XCTAssertEqual(replacement, "", "an empty suggestion is noise — remove it")
    }

    func testDeletingInsideADeletionMarkBodyRefuses() {
        let slice = "A {--keep--} z."
        XCTAssertEqual(SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 5, length: 2), replacement: "", in: slice), .refused,
            "the original text under a deletion suggestion is not editable")
    }

    func testDeletionCrossingAMarkBoundaryRefuses() {
        let slice = "AB {++new++} z."
        // From "B" into the opener.
        XCTAssertEqual(SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 1, length: 5), replacement: "", in: slice), .refused)
    }

    // MARK: - Replacement

    func testTypingOverASelectionBecomesASubstitution() {
        let slice = "Alpha beta gamma."
        let outcome = SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 6, length: 4), replacement: "delta", in: slice)
        guard case .transformed(_, let replacement, let caret) = outcome else {
            return XCTFail("\(outcome)")
        }
        XCTAssertEqual(replacement, "{~~beta~>delta~~}")
        XCTAssertEqual(caret, 3 + 4 + 2 + 5, "caret after delta, inside the new half")
    }

    func testTypingGrowsTheSubstitutionNewHalf() {
        let slice = "A {~~old~>new~~} z."
        // Caret after "new" (offset 13): plain growth.
        XCTAssertEqual(SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 13, length: 0), replacement: "!", in: slice), .plain)
        // Caret inside the OLD half: refused.
        XCTAssertEqual(SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 6, length: 0), replacement: "!", in: slice), .refused)
    }

    func testEmptyingTheNewHalfDowngradesToADeletion() {
        let slice = "A {~~old~>new~~} z."
        // Delete "new" entirely (offsets 10..<13).
        let outcome = SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 10, length: 3), replacement: "", in: slice)
        guard case .transformed(let range, let replacement, _) = outcome else {
            return XCTFail("\(outcome)")
        }
        XCTAssertEqual(range, ByteRange(offset: 2, length: 14), "the whole substitution")
        XCTAssertEqual(replacement, "{--old--}")
    }

    // MARK: - Multi-byte safety

    func testBackspaceExtensionConsumesAWholeGrapheme() {
        let slice = "café{--x--}"
        // Backspace at the closer's last byte (é is 2 bytes: c=0 a=1 f=2 é=3-4).
        let markEnd = slice.utf8.count
        let outcome = SuggestTransform.outcome(
            relativeRange: ByteRange(offset: markEnd - 1, length: 1), replacement: "", in: slice)
        guard case .transformed(let range, let replacement, _) = outcome else {
            return XCTFail("\(outcome)")
        }
        XCTAssertEqual(replacement, "{--éx--}", "é joins whole, never torn mid-byte")
        XCTAssertEqual(range.offset, 3)
    }

    // MARK: - Review-panel-verified defects (2026-07-15)

    func testBackspaceExtendDoesNotEatAnAdjacentMark() {
        // {++a++}{--del--}: backspace deleting the trailing '}' must NOT
        // absorb the neighbor insertion mark's closing byte (BLOCKER).
        let slice = "{++a++}{--del--}"
        let markEnd = slice.utf8.count // 15
        let outcome = SuggestTransform.outcome(
            relativeRange: ByteRange(offset: markEnd - 1, length: 1), replacement: "", in: slice)
        XCTAssertEqual(outcome, .refused,
                       "cannot extend a deletion across an abutting mark boundary")
    }

    func testBackspaceExtendPreservesTheMarkID() {
        // X{--del--}{#c1}: extending the deletion must keep {#c1} (HIGH).
        let slice = "X{--del--}{#c1}"
        let markEnd = slice.utf8.count
        let outcome = SuggestTransform.outcome(
            relativeRange: ByteRange(offset: markEnd - 1, length: 1), replacement: "", in: slice)
        guard case .transformed(let range, let replacement, _) = outcome else {
            return XCTFail("\(outcome)")
        }
        XCTAssertEqual(replacement, "{--Xdel--}{#c1}", "id survives the extend")
        XCTAssertEqual(range, ByteRange(offset: 0, length: markEnd))
    }

    func testTypingAClosingBraceThatLeaksRefuses() {
        // The finding's accumulated state: repeated '+' growth left
        // "{++x++++}" (body "x++"); a '}' at bodyEnd re-anchors the closer
        // early, dropping the caret OUTSIDE the body into a leaked "++}"
        // tail (MEDIUM). Self-calibration must refuse rather than corrupt.
        let slice = "Alpha {++x++++} beta."
        // {++x++++} at 6..15: bodyEnd (closerStart) = 12.
        let outcome = SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 12, length: 0), replacement: "}", in: slice)
        XCTAssertEqual(outcome, .refused, "a leaking brace insert must not apply")
    }

    func testTypingAPlainCharIntoABodyStillGrows() {
        let slice = "Alpha {++x++} beta."
        let outcome = SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 10, length: 0), replacement: "y", in: slice)
        XCTAssertEqual(outcome, .plain, "ordinary growth is unaffected")
    }

    func testTypingAPlusThatStaysValidStillGrows() {
        // A single '+' into the body yields "x+", still a valid mark with
        // the caret in the body — that legitimately grows.
        let slice = "Alpha {++x++} beta."
        let outcome = SuggestTransform.outcome(
            relativeRange: ByteRange(offset: 10, length: 0), replacement: "+", in: slice)
        XCTAssertEqual(outcome, .plain)
    }

}
