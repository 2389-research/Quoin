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
}
#endif
