#if canImport(AppKit)
import XCTest
import QuoinCore
@testable import QuoinRender

/// A prose block's editable slice absorbs ONLY the whitespace in excess of the
/// canonical "\n\n" separator — never the whole gap. Absorbing the whole gap
/// would give every paragraph in every existing document a caret-occupiable
/// blank line; absorbing only the excess leaves untouched files bit-identical.
final class ExcessWhitespaceSliceTests: XCTestCase {

    private func slice(_ source: String, block index: Int) -> String? {
        let d = MarkdownConverter.parse(source)
        return AttributedRenderer.editableSlice(for: d.blocks[index], at: index, in: d)
    }

    /// THE regression guard: an ordinary document must not change at all.
    func testCanonicalGapAbsorbsNothing() {
        XCTAssertEqual(slice("A\n\nB", block: 0), "A")
    }

    func testOneExtraNewlineIsAbsorbed() {
        XCTAssertEqual(slice("A\n\n\nB", block: 0), "A\n",
                       "one Return pressed → one occupiable blank line")
    }

    func testTwoExtraNewlinesAreAbsorbed() {
        XCTAssertEqual(slice("A\n\n\n\nB", block: 0), "A\n\n")
    }

    /// A tight construction has a gap SHORTER than "\n\n" — absorb nothing.
    func testTightGapAbsorbsNothing() {
        XCTAssertEqual(slice("# H\nA", block: 0), "# H")
    }

    /// Whitespace-only lines are left strictly alone: the gap does not END with
    /// "\n\n", so it is not canonical-plus-excess.
    func testWhitespaceGapAbsorbsNothing() {
        XCTAssertEqual(slice("A\n   \nB", block: 0), "A")
    }

    /// Non-prose keeps its exact range even with an oversized gap.
    func testTableKeepsExactRangeDespiteExcessGap() {
        let source = "| a |\n| - |\n\n\nB"
        let d = MarkdownConverter.parse(source)
        let table = AttributedRenderer.editableSlice(for: d.blocks[0], at: 0, in: d)
        XCTAssertFalse(table?.hasSuffix("\n\n") ?? true,
                       "a table must never absorb a blank line — it would terminate the table")
    }

    /// CRLF is ONE grapheme in Swift; absorption is byte-wise, so a CRLF gap
    /// must not be mangled.
    func testCRLFGapIsNotMangled() {
        let d = MarkdownConverter.parse("A\r\n\r\nB")
        let s = AttributedRenderer.editableSlice(for: d.blocks[0], at: 0, in: d)
        XCTAssertEqual(s, "A", "a canonical CRLF gap absorbs nothing")
    }

    /// The separatorUnchangedAcrossEdit fix, guarded. Typing at the end of a
    /// mid-document paragraph must stay on the per-keystroke PATCH path; a
    /// silent fall back to full re-render is a performance regression that no
    /// equivalence test can see.
    func testTypingAtAMidDocumentParagraphEndStaysOnThePatchPath() throws {
        let source = "A\n\n\nB\n\nC"      // block 0 has one absorbed newline
        let document = MarkdownConverter.parse(source)
        let block = document.blocks[0]
        let slice = AttributedRenderer.editableSlice(for: block, at: 0, in: document)!
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        var held: AttributedRenderer.HeldPreview?
        let active = renderer.render(
            document, activeBlockID: block.id, activeCaret: 1, cache: &cache, heldPreview: &held)
        let rendered = RenderedDocument(
            attributed: active.attributed, blockRanges: active.blockRanges,
            activeBlockID: block.id, activeEditableRange: active.activeEditableRange,
            activeSourceText: slice)

        let newSource = "Ax\n\n\nB\n\nC"
        let newDocument = MarkdownConverter.parse(newSource)
        var editHeld = held
        let update = renderer.activeBlockEditUpdate(
            oldDocument: document, oldRendered: rendered, oldActiveBlockID: block.id,
            newDocument: newDocument, newActiveBlockID: newDocument.blocks[0].id,
            caret: 2, heldPreview: &editHeld)
        let taken = try XCTUnwrap(
            update, "typing near a block end must not bail to a full render")

        // NotNil alone only proves the patch was TAKEN, not that it is
        // CORRECT — and ProjectorEquivalenceTests can't see this state
        // (its prefix(6) never reaches an oversized gap, and a
        // canonical→absorbed edit flips the separator unclamped→clamped in
        // one step, so the patch there bails and `continue`s WITHOUT
        // comparing storage). So compare the taken patch directly: applying
        // it to the pre-edit active storage must equal a full re-render of
        // the edited document with the same block active at the same caret.
        let patched = NSMutableAttributedString(attributedString: active.attributed)
        patched.replaceCharacters(
            in: taken.storagePatch.oldRange, with: taken.storagePatch.replacement)
        var refCache: [BlockID: NSAttributedString] = [:]
        var refHeld: AttributedRenderer.HeldPreview?
        let reference = renderer.render(
            newDocument, activeBlockID: newDocument.blocks[0].id, activeCaret: 2,
            cache: &refCache, heldPreview: &refHeld)
        XCTAssertEqual(patched.string, reference.attributed.string,
                       "patched storage string drifted from a full re-render")
        XCTAssertTrue(patched.isEqual(to: reference.attributed),
                      "patched storage attributes drifted from a full re-render")
        XCTAssertEqual(taken.blockRanges, reference.blockRanges,
                       "patch block ranges drifted from a full re-render")
    }
}
#endif
