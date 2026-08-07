#if canImport(AppKit)
import XCTest
import QuoinCore
@testable import QuoinRender

/// The active block's KIND must reach the coordinator. Return semantics key on
/// kind (a blank line terminates a table, so a table must never be mistaken for
/// a paragraph); EditingFlavor is NOT a substitute — it calls tables .prose.
final class ActiveBlockKindTests: XCTestCase {

    func testFullRenderPublishesActiveBlockKind() {
        let doc = MarkdownConverter.parse("Para\n\n| a | b |\n| - | - |\n| 1 | 2 |\n")
        let table = doc.blocks[1]
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        var held: AttributedRenderer.HeldPreview?
        let rendered = renderer.render(
            doc, activeBlockID: table.id, activeCaret: 0, cache: &cache, heldPreview: &held)
        XCTAssertEqual(rendered.activeBlockKind, table.kind,
                       "the revealed block's kind must reach the host")
    }

    func testReadingRenderHasNoActiveBlockKind() {
        let doc = MarkdownConverter.parse("Para\n")
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        var held: AttributedRenderer.HeldPreview?
        let rendered = renderer.render(
            doc, activeBlockID: nil, activeCaret: nil, cache: &cache, heldPreview: &held)
        XCTAssertNil(rendered.activeBlockKind)
    }

    // MARK: - ReaderModel reconstruction regression (whole-branch review)
    //
    // `ReaderModel` REBUILDS `RenderedDocument` at four sites (full render,
    // keystroke patch, async render, activation flip) and once forgot to carry
    // `activeBlockKind` through — so it was nil in the running app and every
    // prose/quote/table Return was dead, while these renderer-level tests stayed
    // green. ReaderModel is app-target-only (no SwiftPM test bundle), so we can't
    // drive it under `swift test`; instead we pin the two SOURCE VALUES those
    // sites read — a fresh `render(...)` and an `ActiveBlockEditUpdate` — proving
    // each carries a non-nil paragraph kind. The four sites now carry code
    // comments naming the invariant. If either assert below regresses, Return is
    // dead again.

    func testFullRenderPublishesActiveBlockKindForParagraph() {
        let doc = MarkdownConverter.parse("Hello world\n")
        let para = doc.blocks[0]
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        var held: AttributedRenderer.HeldPreview?
        let rendered = renderer.render(
            doc, activeBlockID: para.id, activeCaret: 0, cache: &cache, heldPreview: &held)
        XCTAssertEqual(rendered.activeBlockKind, para.kind,
                       "full-render path must carry the active paragraph's kind")
        XCTAssertNotNil(rendered.activeBlockKind)
    }

    func testActiveBlockPatchUpdateCarriesParagraphKind() throws {
        let source = "Hello\n"
        let document = MarkdownConverter.parse(source)
        let block = document.blocks[0]
        let slice = try XCTUnwrap(
            AttributedRenderer.editableSlice(for: block, at: 0, in: document))
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        var held: AttributedRenderer.HeldPreview?
        let active = renderer.render(
            document, activeBlockID: block.id, activeCaret: 1, cache: &cache, heldPreview: &held)
        let rendered = RenderedDocument(
            attributed: active.attributed, blockRanges: active.blockRanges,
            activeBlockID: block.id, activeEditableRange: active.activeEditableRange,
            activeSourceText: slice)

        // Type a character inside the paragraph — the keystroke-patch path.
        let newDocument = MarkdownConverter.parse("Hexllo\n")
        var editHeld = held
        let update = try XCTUnwrap(
            renderer.activeBlockEditUpdate(
                oldDocument: document, oldRendered: rendered, oldActiveBlockID: block.id,
                newDocument: newDocument, newActiveBlockID: newDocument.blocks[0].id,
                caret: 3, heldPreview: &editHeld),
            "typing in a paragraph must stay on the patch path")
        // `ActiveBlockEditUpdate.activeBlockKind` is NON-optional; the patch site
        // in ReaderModel republishes it. Confirm it names the paragraph.
        XCTAssertEqual(update.activeBlockKind, newDocument.blocks[0].kind,
                       "patch path must carry the active paragraph's kind")
    }
}
#endif
