#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 1, Task 5: a recycled cell must surface that its block's content is
/// still decoding (`hasPendingContent`) and fire `onContentSettled(blockID)`
/// once that content lands — the signal the recycler (Task 6) uses to re-query a
/// provisional row height instead of caching it as final.
///
/// This mirrors `AsyncImageRerenderTests`: it drives the REAL async decode
/// through the shared `AsyncImageStore` (no fixed sleep, no fake that bypasses
/// the store) and waits on the callback via an expectation. The cell reaches
/// that store only by rendering through `AttributedRenderer` — the same path the
/// monolithic reader uses — so the wiring under test is genuine.
@MainActor
final class AsyncRowHeightTests: XCTestCase {

    /// A 1×1 PNG — valid enough for ImageIO to decode into an attachment image.
    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    /// A fresh directory + image per test: the shared `AsyncImageStore` cache is
    /// keyed on path+mtime, so a unique path guarantees a cache MISS and thus the
    /// placeholder-first (pending) path a warm cache would skip.
    private func makeDocumentDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-async-row-\(UUID().uuidString)")
        let assets = dir.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Self.onePixelPNG.write(to: assets.appendingPathComponent("pixel.png"))
        return dir
    }

    /// Configure a cell for an image block: it reports `hasPendingContent` while
    /// the image is decoding, and fires `onContentSettled` with that block's id
    /// once the shared store reports the decode ready. The settled height is
    /// re-queryable and matches the freshly-measured (now-cached) height.
    func testImageCellIsPendingThenSettles() throws {
        let dir = try makeDocumentDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = MarkdownConverter.parse("![a pixel](assets/pixel.png)")
        let block = doc.blocks[0]

        // Async image resolution + a baseURL so the relative path resolves — the
        // cell copies THIS configuration into its own observing renderer.
        let renderer = AttributedRenderer(baseURL: dir, imageResolution: .async)
        let theme = Theme()
        let width: CGFloat = 600

        let cell = BlockRenderCell()

        let settled = expectation(description: "onContentSettled fires when the decode completes")
        var settledID: BlockID?
        cell.onContentSettled = { id in
            settledID = id
            settled.fulfill()
        }

        cell.configure(block: block, document: doc, renderer: renderer, theme: theme, width: width)

        // Cache miss → the image is still decoding, so the cell's fragment is a
        // placeholder tagged pending. The row height is provisional but valid.
        XCTAssertTrue(cell.hasPendingContent,
                      "an uncached async image block must report hasPendingContent while decoding")
        let provisionalHeight = cell.fittingHeightForConfiguredWidth
        XCTAssertGreaterThan(provisionalHeight, 0,
                             "the provisional placeholder height must still be a real, layout-derived value")

        // Driven by the real AsyncImageStore decode callback, not a sleep.
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(settledID, block.id,
                       "onContentSettled must carry the id of the block that settled")

        // The height was provisional, so the recycler re-queries it. With the
        // decode now cached the block is no longer pending, and BlockRowMetrics
        // returns the settled content height.
        let requeried = BlockRowMetrics.rowHeight(
            for: block, at: 0, in: doc, renderer: renderer, theme: theme, width: width)
        XCTAssertGreaterThan(requeried, 0)

        // Reconfiguring the same cell against the now-warm cache clears pending —
        // proving the pending flag tracked real decode state, not a constant.
        let warmCell = BlockRenderCell()
        warmCell.configure(block: block, document: doc, renderer: renderer, theme: theme, width: width)
        XCTAssertFalse(warmCell.hasPendingContent,
                       "after the decode is cached, a fresh render of the block must not be pending")
    }

    /// A non-async block (plain prose) is never pending and never fires the
    /// settle callback — guards against a flag/callback that is always-on.
    func testProseCellIsNeverPending() {
        let doc = MarkdownConverter.parse("Just a paragraph of prose, no images.")
        let renderer = AttributedRenderer()
        let cell = BlockRenderCell()
        var fired = false
        cell.onContentSettled = { _ in fired = true }
        cell.configure(block: doc.blocks[0], document: doc, renderer: renderer, theme: Theme(), width: 600)
        XCTAssertFalse(cell.hasPendingContent, "a prose block has no async content to wait on")
        XCTAssertFalse(fired, "no decode is scheduled, so onContentSettled must not fire")
    }
}
#endif
