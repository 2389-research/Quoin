#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

@MainActor
final class BlockRenderCellTests: XCTestCase {
    func testCellShowsBlockTextAndHeightMatchesMetric() {
        let doc = MarkdownConverter.parse("# A heading\n\nA body paragraph that is reasonably long.")
        let renderer = AttributedRenderer()
        let theme = Theme()     // Theme has no `.graphite` member; the default constructor is the app default.
        let width: CGFloat = 600
        let cell = BlockRenderCell()
        cell.configure(block: doc.blocks[0], document: doc, renderer: renderer, theme: theme, width: width)
        XCTAssertEqual(cell.blockID, doc.blocks[0].id)
        XCTAssertEqual(cell.fittingHeightForConfiguredWidth,
                       renderer.measuredHeight(of: doc.blocks[0], in: doc, width: width), accuracy: 0.5)
        // Reconfiguring for a different block updates identity (recycling).
        cell.configure(block: doc.blocks[1], document: doc, renderer: renderer, theme: theme, width: width)
        XCTAssertEqual(cell.blockID, doc.blocks[1].id)
    }
}
#endif
