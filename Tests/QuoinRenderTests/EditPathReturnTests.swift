#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Edit-path integration tests: drive the REAL Return → caret-restore → render
/// cycle through the same pure functions the app uses (`paragraphBreakInsertion`
/// → `caretUTF8 = insertOffset + insertion.length` → `caretMapping` → render),
/// so the INTERIOR blank-line case (a heading/paragraph WITH content below it)
/// is exercised — not just the last-block fixtures the earlier CARET-1 tests
/// used. The interior case regressed to a 2pt "dot" caret because the caret
/// lands past the revealed slice, on the following block separator; this suite
/// pins it as a body-height bar.
final class EditPathReturnTests: XCTestCase {

    // MARK: helpers

    /// UTF-8 byte insertion (mirrors how the model splices a source edit).
    private func insert(_ s: String, into src: String, atUTF8 offset: Int) -> String {
        var bytes = Array(src.utf8)
        bytes.insert(contentsOf: Array(s.utf8), at: offset)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Height of the layout fragment the caret sits on (forward affinity).
    private func caretFragmentHeight(_ a: NSAttributedString, utf16 caret: Int, width: CGFloat = 700) -> CGFloat {
        let storage = NSTextStorage(attributedString: a)
        let cs = NSTextContentStorage(); cs.textStorage = storage
        let lm = NSTextLayoutManager(); cs.addTextLayoutManager(lm)
        lm.textContainer = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        lm.ensureLayout(for: cs.documentRange)
        var h: CGFloat = -1
        lm.enumerateTextLayoutFragments(from: cs.documentRange.location) { f in
            if let r = f.rangeInElement as NSTextRange?,
               let start = cs.offset(from: cs.documentRange.location, to: r.location) as Int?,
               let end = cs.offset(from: cs.documentRange.location, to: r.endLocation) as Int?,
               caret >= start && caret < max(end, start + 1) {
                h = f.layoutFragmentFrame.height
            }
            return true
        }
        return h
    }

    /// Drive one Return at the end of the active prose block's slice; return the
    /// post-Return document, the caret's block/slice mapping, and the caret's
    /// resulting UTF-8 offset — exactly as the app's edit path computes them.
    private func pressReturn(
        source: String, activeBlockIndex: Int
    ) -> (doc: QuoinDocument, blockID: BlockID, caretUTF16InSlice: Int, caretUTF8: Int)? {
        let d0 = MarkdownConverter.parse(source)
        guard activeBlockIndex < d0.blocks.count,
              let slice0 = AttributedRenderer.editableSlice(
                for: d0.blocks[activeBlockIndex], at: activeBlockIndex, in: d0)
        else { return nil }
        let relCaret = (slice0 as NSString).length           // caret at end of slice
        let atEnd = activeBlockIndex == d0.blocks.count - 1
        guard let insertion = MarkdownReaderView.Coordinator.paragraphBreakInsertion(
                sourceText: slice0, relCaret: relCaret, atDocumentEnd: atEnd),
              let relUTF8 = EditMapping.utf8Offset(inText: slice0, utf16Offset: relCaret)
        else { return nil }
        let byteOffset = d0.blocks[activeBlockIndex].range.offset + relUTF8
        let caretUTF8 = byteOffset + insertion.utf8.count     // ReaderModel caret formula
        let src1 = insert(insertion, into: source, atUTF8: byteOffset)
        let d1 = MarkdownConverter.parse(src1)
        guard let map = AttributedRenderer.caretMapping(inDocument: d1, atUTF8Offset: caretUTF8) else { return nil }
        return (d1, map.blockID, map.caretUTF16InSlice, caretUTF8)
    }

    // MARK: tests

    /// INTERIOR: a heading with content below. After Return the caret must land
    /// on a BODY-height bar, not a 2pt dot. (Regression: the dot the user hit on
    /// the Welcome doc.)
    func testInteriorHeadingReturnCaretIsBodyHeightBar() throws {
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let r = try XCTUnwrap(pressReturn(source: "# Welcome\n\nThis is a body paragraph.", activeBlockIndex: 0))
        let rendered = renderer.render(r.doc, activeBlockID: r.blockID, activeCaret: r.caretUTF16InSlice, cache: &cache)
        // Heading is block 0 → rendered start 0 → caret rendered offset == slice offset.
        let h = caretFragmentHeight(rendered.attributed, utf16: r.caretUTF16InSlice)
        XCTAssertGreaterThan(h, 15, "interior-Return caret must be a body-height bar, not a 2pt dot (got \(h)pt)")
    }

    /// INTERIOR: a paragraph with content below — same guarantee as the heading.
    func testInteriorParagraphReturnCaretIsBodyHeightBar() throws {
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let r = try XCTUnwrap(pressReturn(source: "First paragraph.\n\nSecond paragraph.", activeBlockIndex: 0))
        let rendered = renderer.render(r.doc, activeBlockID: r.blockID, activeCaret: r.caretUTF16InSlice, cache: &cache)
        let h = caretFragmentHeight(rendered.attributed, utf16: r.caretUTF16InSlice)
        XCTAssertGreaterThan(h, 15, "interior paragraph-Return caret must be a body-height bar (got \(h)pt)")
    }

    // (The LAST-block Return caret lands on TextKit's extra-line-fragment,
    // which `enumerateTextLayoutFragments` does not surface for measurement;
    // that case is guarded by RevealFidelityTests.testReturnBlankLineEquals-
    // AfterFirstCharacter instead.)

    /// The byte model stays correct: typing the first character after an
    /// interior Return produces a PROPERLY SEPARATED paragraph, never text glued
    /// onto the heading line.
    func testInteriorReturnThenTypeProducesSeparatedParagraph() throws {
        let r = try XCTUnwrap(pressReturn(source: "# Welcome\n\nThis is a body paragraph.", activeBlockIndex: 0))
        // Reconstruct the source and type "x" at the caret.
        let src1 = "# Welcome\n\n\n\nThis is a body paragraph."   // after Return (insert \n\n at 9)
        let typed = insert("x", into: src1, atUTF8: r.caretUTF8)
        XCTAssertEqual(typed, "# Welcome\n\nx\n\nThis is a body paragraph.",
                       "typed character must become its own paragraph, separated from the heading by \\n\\n")
        // And it re-parses to three blocks (heading, x, paragraph) — x is NOT
        // part of the heading.
        let d = MarkdownConverter.parse(typed)
        XCTAssertEqual(d.blocks.count, 3)
        if case .paragraph = d.blocks[1].kind {} else { XCTFail("second block should be the 'x' paragraph") }
    }
}
#endif
