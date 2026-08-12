#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// **The refresh gate** (I6): the recycler re-projects on CONTENT identity, not on
/// `RenderedDocument.revision`.
///
/// `rendered.revision` is a PROJECTION counter. `ReaderModel` bumps it from
/// `restoreCaret`, from `rerenderAsync`, and from `scheduleAsyncContentRerender`'s
/// ~120 ms image-decode debounce — none of which change a document byte. The old
/// gate (`coordinator.appliedRevision != rendered.revision`) turned every one of
/// those into a full `updateDocumentPreservingEditing`: `settledHeights` emptied,
/// `rowByBlockID` rebuilt, and every non-editing row reloaded — on a timer, while
/// the user is typing in an island. The existing falsifier only proved the island
/// SURVIVED that; it never measured the churn.
///
/// These tests measure it. The gate now keys off `QuoinDocument.sourceHash` (the
/// same content hash `DocumentSession`/`ReaderModel.ingest` use) plus the laid-out
/// width; a projection-only bump reaches `noteProjectionOnlyBump()` and does no
/// table work, and the one appearance change a bump used to carry — an async image
/// decode landing — is repainted off the readiness signal itself.
///
/// Every counter assertion is paired with an anti-vacuity assert that the
/// interaction it is counting actually happened.
@MainActor
final class RecyclerRefreshGateTests: AppKitWindowTestCase {

    // MARK: - Harness

    private func representable(
        _ document: QuoinDocument, revision: Int,
        renderer: AttributedRenderer = AttributedRenderer(theme: Theme())
    ) -> BlockRecyclerReaderView {
        BlockRecyclerReaderView(
            document: document,
            rendered: RenderedDocument(attributed: NSAttributedString(),
                                       blockRanges: [:], revision: revision),
            theme: Theme(),
            renderer: renderer,
            scrollTarget: nil,
            onTopBlockChange: nil,
            searchQuery: nil,
            onReconcile: { _, _ in document })
    }

    /// The hosted recycler in a real offscreen window, seeded through the SAME
    /// `apply(initial:)` path `makeNSView` uses.
    private func makeHost(_ document: QuoinDocument, revision: Int = 1,
                          renderer: AttributedRenderer = AttributedRenderer(theme: Theme()))
        -> (view: BlockRecyclerView, coordinator: BlockRecyclerReaderView.Coordinator)
    {
        let coordinator = BlockRecyclerReaderView.Coordinator()
        let view = representable(document, revision: revision, renderer: renderer)
            .makeRecycler(coordinator: coordinator)
        let window = makeTestWindow(width: 640, height: 480)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        view.layoutSubtreeIfNeeded()
        // `makeRecycler` runs the INITIAL apply before the view has been laid out,
        // so its column is the not-yet-sized fallback. Re-apply once at the real
        // width, so the width is settled and a later same-revision apply is not
        // classified as a width change (which is a legitimate full refresh).
        representable(document, revision: revision, renderer: renderer)
            .apply(to: view, coordinator: coordinator, initial: false)
        view.layoutSubtreeIfNeeded()
        return (view, coordinator)
    }

    private static func paragraph(_ i: Int) -> String {
        "Paragraph \(i) with enough words in it to wrap across a couple of lines in a six hundred point column."
    }

    // MARK: - 5. A projection-only bump does no table work

    /// Identical document bytes, a bumped revision: the recycler must not clear
    /// `settledHeights`, must not rebuild `rowByBlockID`, and must not reload a
    /// single row.
    func testProjectionOnlyBumpDoesNotRebuildAnything() throws {
        let doc = MarkdownConverter.parse((0..<12).map(Self.paragraph).joined(separator: "\n\n"))
        let (view, coordinator) = makeHost(doc, revision: 1)
        XCTAssertEqual(coordinator.appliedRevision, 1)

        view.resetRefreshCountersForTest()
        view.resetChurnCountersForTest()
        // The same DOCUMENT VALUE (byte-identical, same hash) at a new revision —
        // exactly what `restoreCaret` / `rerenderAsync` / the 120 ms decode debounce
        // publish.
        representable(doc, revision: 2).apply(to: view, coordinator: coordinator, initial: false)
        view.layoutSubtreeIfNeeded()

        let trace = "cleared=\(view.settledHeightsClearedCountForTest) "
            + "rebuilds=\(view.rowMapRebuildCountForTest) "
            + "fullReloads=\(view.fullReloadCountForTest) "
            + "vends=\(view.renderCellVendsByRowForTest) "
            + "bumps=\(view.projectionOnlyBumpCountForTest)"

        // ANTI-VACUITY: the bump really did reach the recycler through the gate —
        // without this, all the zeros below would also pass if `apply` had not run.
        XCTAssertEqual(view.projectionOnlyBumpCountForTest, 1,
                       "the projection-only bump must reach the recycler — \(trace)")
        XCTAssertEqual(coordinator.appliedRevision, 2,
                       "the gate must consume the revision so it is not re-evaluated forever — \(trace)")

        XCTAssertEqual(view.settledHeightsClearedCountForTest, 0,
                       "a content-free bump must not throw the measured row heights away — \(trace)")
        XCTAssertEqual(view.rowMapRebuildCountForTest, 0,
                       "a content-free bump must not rebuild the block→row map — \(trace)")
        XCTAssertEqual(view.fullReloadCountForTest, 0,
                       "a content-free bump must not reload the table — \(trace)")
        XCTAssertTrue(view.renderCellVendsByRowForTest.isEmpty,
                      "a content-free bump must not re-vend any row — \(trace)")
    }

    /// The same thing with a LIVE ISLAND: the previous falsifier proved the island
    /// survived a content-free bump; this proves the bump no longer costs the
    /// document a full re-projection underneath it, and that the live cell is not
    /// even touched.
    func testProjectionOnlyBumpDoesNotChurnUnderALiveIsland() throws {
        let doc = MarkdownConverter.parse((0..<12).map(Self.paragraph).joined(separator: "\n\n"))
        let (view, coordinator) = makeHost(doc, revision: 1)
        let controller = try XCTUnwrap(view.islandControllerForTest,
                                       "the wrapper must install an IslandController")
        controller.activate(blockID: doc.blocks[4].id, localPoint: .zero, in: doc, baseRevision: 1)
        view.layoutSubtreeIfNeeded()
        let cell = try XCTUnwrap(view.currentEditorCell, "the island must be open")
        cell.islandTextView.setSelectedRange(NSRange(location: 3, length: 0))

        view.resetRefreshCountersForTest()
        view.resetChurnCountersForTest()
        representable(doc, revision: 7).apply(to: view, coordinator: coordinator, initial: false)
        view.layoutSubtreeIfNeeded()

        let trace = "cleared=\(view.settledHeightsClearedCountForTest) "
            + "rebuilds=\(view.rowMapRebuildCountForTest) "
            + "editorVends=\(view.editorCellVendsByRowForTest) "
            + "renderVends=\(view.renderCellVendsByRowForTest)"

        XCTAssertEqual(view.projectionOnlyBumpCountForTest, 1, "the bump must have landed — \(trace)")
        XCTAssertEqual(view.settledHeightsClearedCountForTest, 0, trace)
        XCTAssertEqual(view.rowMapRebuildCountForTest, 0, trace)
        XCTAssertTrue(view.renderCellVendsByRowForTest.isEmpty,
                      "no row may be re-projected by a content-free bump — \(trace)")
        XCTAssertTrue(view.editorCellVendsByRowForTest.isEmpty,
                      "the island cell must not be re-vended — \(trace)")
        XCTAssertTrue(view.currentEditorCell === cell, "the live island cell must be the same object")
        XCTAssertEqual(view.currentEditorCell?.islandTextView.selectedRange().location, 3,
                       "the caret must not move")
    }

    // MARK: - 6. A genuine content change still fully refreshes (positive control)

    func testContentChangeStillRefreshes() throws {
        let doc = MarkdownConverter.parse((0..<12).map(Self.paragraph).joined(separator: "\n\n"))
        let (view, coordinator) = makeHost(doc, revision: 1)

        var parts = (0..<12).map(Self.paragraph)
        parts.append("A new final paragraph that did not exist before.")
        let edited = MarkdownConverter.parse(parts.joined(separator: "\n\n"))
        XCTAssertNotEqual(edited.sourceHash, doc.sourceHash,
                          "precondition: the content really changed")

        view.resetRefreshCountersForTest()
        view.resetChurnCountersForTest()
        representable(edited, revision: 2).apply(to: view, coordinator: coordinator, initial: false)
        view.layoutSubtreeIfNeeded()

        let trace = "rows=\(view.numberOfRowsForTest) "
            + "cleared=\(view.settledHeightsClearedCountForTest) "
            + "rebuilds=\(view.rowMapRebuildCountForTest) "
            + "fullReloads=\(view.fullReloadCountForTest) "
            + "bumps=\(view.projectionOnlyBumpCountForTest)"

        XCTAssertEqual(view.numberOfRowsForTest, edited.blocks.count,
                       "the new block must be on screen — \(trace)")
        XCTAssertEqual(view.rowMapRebuildCountForTest, 1,
                       "a real content change must rebuild the row map — \(trace)")
        XCTAssertGreaterThanOrEqual(view.fullReloadCountForTest, 1,
                                    "with no island open a content change is a full swap — \(trace)")
        XCTAssertEqual(view.projectionOnlyBumpCountForTest, 0,
                       "a content change must NOT be classified as projection-only — \(trace)")
        XCTAssertEqual(coordinator.appliedSourceHash, edited.sourceHash,
                       "the gate must record the new content identity — \(trace)")
    }

    /// A WIDTH change with identical bytes is the other legitimate reason to
    /// re-project (the column changed, so every measured height is stale).
    func testWidthChangeStillRefreshes() throws {
        let doc = MarkdownConverter.parse((0..<12).map(Self.paragraph).joined(separator: "\n\n"))
        let (view, coordinator) = makeHost(doc, revision: 1)
        let widthBefore = try XCTUnwrap(coordinator.appliedWidth)

        view.resetRefreshCountersForTest()
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
        view.layoutSubtreeIfNeeded()
        representable(doc, revision: 1).apply(to: view, coordinator: coordinator, initial: false)
        view.layoutSubtreeIfNeeded()

        XCTAssertNotEqual(coordinator.appliedWidth, widthBefore,
                          "precondition: the laid-out column really changed")
        XCTAssertGreaterThanOrEqual(view.rowMapRebuildCountForTest, 1,
                                    "a width change must re-project the rows")
        XCTAssertEqual(view.projectionOnlyBumpCountForTest, 0,
                       "a width change is not a projection-only bump")
    }

    // MARK: - 7. Async content-ready still repaints its row (positive control)

    /// The one thing a projection bump used to carry that mattered: an image
    /// decode landing. It no longer needs the bump — `contentDidSettle` repaints
    /// that row (and only that row) off the readiness signal from
    /// `AsyncImageStore` itself. Driven by the REAL decode, no sleeps, no fakes.
    func testAsyncImageDecodeRepaintsItsRowWithoutAFullRefresh() throws {
        let dir = try Self.makeImageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        var parts = ["Intro paragraph.", "![a picture](picture.png)"]
        parts.append(contentsOf: (0..<8).map(Self.paragraph))
        let doc = MarkdownConverter.parse(parts.joined(separator: "\n\n"))
        let renderer = AttributedRenderer(theme: Theme(), baseURL: dir, imageResolution: .async)
        let (view, _) = makeHost(doc, revision: 1, renderer: renderer)

        view.resetRefreshCountersForTest()
        view.resetChurnCountersForTest()

        let settled = expectation(description: "the image decode lands")
        view.didRecordSettledHeightForTest = { _ in settled.fulfill() }
        let cell = try XCTUnwrap(view.forceLoadRowForTest(1), "row 1 must vend a render cell")
        XCTAssertEqual(cell.blockID, doc.blocks[1].id, "row 1 must be the image block")
        // ANTI-VACUITY: the decoded height is NOT known yet, so the row is sized by
        // the `.textReference` placeholder. (`hasPendingContent` on the cell is NOT
        // usable here: the shared decode can finish between the row's first
        // realization and this one, in which case the re-vended cell renders from
        // the warm cache while the FIRST cell's registration is what later fires
        // the settle. The recorded-height count is the race-free statement of the
        // same precondition.)
        XCTAssertEqual(view.settledHeightCountForTest, 0,
                       "precondition: the decoded height must not be known yet")
        let pendingHeight = view.rowHeightForTest(1)

        wait(for: [settled], timeout: 5)
        view.layoutSubtreeIfNeeded()

        let trace = "repainted=\(view.projectionRepaintedRowsForTest) "
            + "fullReloads=\(view.fullReloadCountForTest) "
            + "rebuilds=\(view.rowMapRebuildCountForTest) "
            + "height=\(pendingHeight)→\(view.rowHeightForTest(1))"

        XCTAssertTrue(view.projectionRepaintedRowsForTest.contains(1),
                      "the settled row must be repainted so the decoded image reaches the screen — \(trace)")
        XCTAssertGreaterThan(view.rowHeightForTest(1), pendingHeight + 10,
                             "the row must take the decoded image's height — \(trace)")
        // The repaint is SURGICAL: one row, no table-wide work.
        XCTAssertEqual(view.fullReloadCountForTest, 0,
                       "an image decode must not reload the whole table — \(trace)")
        XCTAssertEqual(view.rowMapRebuildCountForTest, 0,
                       "an image decode must not rebuild the row map — \(trace)")
        XCTAssertEqual(view.projectionRepaintedRowsForTest.filter { $0 != 1 }, [],
                       "no other row may be repainted — \(trace)")
        // And the freshly vended cell really is showing the decoded image now.
        let repainted = try XCTUnwrap(view.forceLoadRowForTest(1))
        XCTAssertFalse(repainted.hasPendingContent,
                       "the repainted cell must no longer be a placeholder — \(trace)")
    }

    private static func makeImageFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-refresh-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 160,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 240, height: 160).fill()
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!
            .write(to: dir.appendingPathComponent("picture.png"))
        return dir
    }
}
#endif
