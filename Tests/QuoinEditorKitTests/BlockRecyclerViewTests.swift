#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 1, Task 6: the view-based `NSTableView` host recycles per-block cells
/// into a scrolling list. The contract:
///  - `numberOfRows == document.blocks.count`;
///  - recycling keeps LIVE cells bounded (visible + reuse buffer), NOT
///    one-per-block, even after scrolling the whole document past the viewport;
///  - the top-most visible block is reported after a scroll.
///
/// Plus two acceptance checks carried from prior-task reviews:
///  - (A) the scroll view reserves `>= verticalBleed` of top/bottom content
///    insets so edge cells' decorations don't clip (Task 4);
///  - (B) a pending async-image row's decode registration is NOT stolen by the
///    height path: the cell wins, so `onContentSettled` fires and the row
///    re-sizes (Task 5). If the height path had stolen the registration the
///    settle callback would never fire and the expectation would time out.
///
/// Offscreen borderless-window recipe follows `DecorationGeometryTests`.
@MainActor
final class BlockRecyclerViewTests: XCTestCase {

    func testRowCountAndBoundedRecycling() {
        // 400 short blocks so many rows scroll through a small viewport.
        let src = (0..<400).map { "Paragraph number \($0)." }.joined(separator: "\n\n")
        let doc = MarkdownConverter.parse(src)
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = OffscreenTestWindow.make(width: 640, height: 480)
        window.contentView = v
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()

        XCTAssertEqual(v.numberOfRowsForTest, 400)

        // Scroll to the bottom; live cell count stays bounded (visible + reuse
        // buffer), NOT 400.
        v.scroll(to: doc.blocks[399].id)
        v.layoutSubtreeIfNeeded()
        // ANTI-VACUITY (proved: with `visibleCellCount` stubbed to 0 this test
        // still passed). An upper bound on a counter is satisfied by a counter
        // that never counts, so pin the lower end too: a 480pt viewport of ~24pt
        // rows must be holding real cells.
        XCTAssertGreaterThan(v.visibleCellCount, 0,
                             "the live-cell instrument must actually observe cells")
        XCTAssertLessThan(v.visibleCellCount, 60,
                          "recycling must keep live cells bounded, not one-per-block")
    }

    func testTopBlockReported() {
        let doc = MarkdownConverter.parse((0..<50).map { "P\($0)." }.joined(separator: "\n\n"))
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        var top: BlockID?
        v.onTopBlockChange = { top = $0 }
        let window = OffscreenTestWindow.make(width: 640, height: 400)
        window.contentView = v
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        v.frame = window.contentLayoutRect
        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()

        v.scroll(to: doc.blocks[20].id)
        v.layoutSubtreeIfNeeded()

        // `XCTAssertNotNil(top)` alone passes for a callback that reports a
        // CONSTANT or the WRONG row, and "which block is at the top" is the entire
        // content of this signal (the outline highlight reads it). Pin it against
        // an INDEPENDENT oracle — AppKit's own `rows(in: visibleRect)` — rather
        // than against block 20: `scroll(to:)` is a MINIMAL scroll, so it brings
        // block 20 to the BOTTOM of the viewport and the top block is an earlier
        // one (measured: block 9 at this geometry). Asserting `blocks[20]` here
        // would be asserting a bug.
        let visible = v.tableViewForTest.rows(in: v.tableViewForTest.visibleRect)
        XCTAssertGreaterThan(visible.length, 0, "precondition: some rows are visible")
        XCTAssertNotEqual(top, doc.blocks[0].id,
                          "the top block must have TRACKED the scroll, not stayed at block 0")
        XCTAssertEqual(top, doc.blocks[visible.location].id,
                       "the reported top block must be the top-most visible row "
                       + "(row \(visible.location); got \(top.map { "\($0)" } ?? "nil"))")
    }

    /// Acceptance (A): the scroll view reserves the edge bleed so the first
    /// block's top decoration and the last block's bottom decoration — whose
    /// cell frames are `verticalBleed` taller than their rows — do not clip.
    func testContentInsetsReserveEdgeBleed() {
        let doc = MarkdownConverter.parse("# H\n\nBody paragraph.\n\nTail.")
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = OffscreenTestWindow.make(width: 640, height: 400)
        window.contentView = v
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(v.scrollInsetsForTest.top, DecorationDraw.verticalBleed,
                                    "top inset must reserve the first row's omitted top bleed")
        XCTAssertGreaterThanOrEqual(v.scrollInsetsForTest.bottom, DecorationDraw.verticalBleed,
                                    "bottom inset must reserve the last row's omitted bottom bleed")
    }

    /// A 1×1 PNG — valid enough for ImageIO to decode into an attachment image.
    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    /// Acceptance (B): a pending async-image row's decode registration is NOT
    /// stolen by the recycler's height path. The cell (rendering through the
    /// real `.async` renderer) is the sole first caller, so its
    /// `onContentSettled` fires; the recycler records the settled height and
    /// notes the row. Had the height path stolen the registration, the settle
    /// callback would never fire and this expectation would time out.
    func testPendingImageRowSettlesWithoutStolenRegistration() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-recycler-async-\(UUID().uuidString)")
        let assets = dir.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Self.onePixelPNG.write(to: assets.appendingPathComponent("pixel.png"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let doc = MarkdownConverter.parse("![a pixel](assets/pixel.png)")
        // A fresh, unique path guarantees a cache MISS → the placeholder-first
        // (pending) path a warm cache would skip.
        let renderer = AttributedRenderer(baseURL: dir, imageResolution: .async)
        let v = BlockRecyclerView(renderer: renderer, theme: Theme())
        let window = OffscreenTestWindow.make(width: 640, height: 400)
        window.contentView = v
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 400)

        let settled = expectation(description: "the row settles when the decode lands")
        v.didRecordSettledHeightForTest = { id in
            if id == doc.blocks[0].id { settled.fulfill() }
        }

        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()
        // Force the cell to instantiate + register the decode (viewFor). The
        // height path used `.textReference` and never touched the store, so this
        // cell is the first caller.
        XCTAssertNotNil(v.forceLoadRowForTest(0))
        let provisional = v.rowHeightForTest(0)
        XCTAssertGreaterThan(provisional, 0, "the provisional (placeholder) row height is a real value")

        wait(for: [settled], timeout: 5)
        XCTAssertGreaterThan(v.rowHeightForTest(0), 0, "the settled row height is re-queryable")
    }
}
#endif
