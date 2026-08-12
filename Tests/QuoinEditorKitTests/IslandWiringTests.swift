#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 2, Task 7: the app-wiring seam that drives an editable island end to
/// end through the block recycler reader. This exercises
/// `BlockRecyclerReaderView`'s own wiring — WITHOUT SwiftUI — by building the
/// hosted `BlockRecyclerView` via `makeRecycler`, driving the recycler's click
/// seam (`onBlockClicked`), typing into the promoted island, flushing the
/// reconcile debounce, and re-feeding a higher-revision projection through
/// `apply` to prove the revision gate re-runs `setDocument`.
///
/// The representable owns an `IslandController` (on its `Coordinator`), forwards
/// `onBlockClicked → controller.activate`, and installs
/// `controller.onReconcile` so a flush calls the app's `onReconcile` closure and
/// then `controller.applyReconciled(newDocument)`. Here the app closure is
/// stubbed to apply the edit through the real incremental parse (exactly what
/// `ReaderModel.reconcileIsland`/`DocumentSession` do) and hand the new document
/// back.
///
/// Headless, on a real recycler in an offscreen borderless window (same recipe
/// as `IslandControllerTests` / `IslandReconcileTests`).
@MainActor
final class IslandWiringTests: XCTestCase {

    /// Build a hosted, laid-out recycler wired through `BlockRecyclerReaderView`
    /// for `document` at `revision`, with `onReconcile` installed as the app
    /// closure. Returns everything the test needs to drive and observe the seams.
    private func makeHarness(
        document: QuoinDocument,
        revision: Int,
        onReconcile: @escaping (ByteRange, String) async -> QuoinDocument
    ) -> (view: BlockRecyclerView,
          coordinator: BlockRecyclerReaderView.Coordinator,
          window: NSWindow) {
        let repr = representable(document: document, revision: revision, onReconcile: onReconcile)
        let coordinator = repr.makeCoordinator()
        let view = repr.makeRecycler(coordinator: coordinator)
        let window = OffscreenTestWindow.make(width: 640, height: 480)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        view.layoutSubtreeIfNeeded()
        return (view, coordinator, window)
    }

    private func representable(
        document: QuoinDocument,
        revision: Int,
        onReconcile: ((ByteRange, String) async -> QuoinDocument)? = nil
    ) -> BlockRecyclerReaderView {
        BlockRecyclerReaderView(
            document: document,
            rendered: RenderedDocument(attributed: NSAttributedString(), blockRanges: [:],
                                       revision: revision),
            theme: Theme(),
            renderer: AttributedRenderer(),
            scrollTarget: nil,
            scrollGeneration: 0,
            onTopBlockChange: nil,
            searchQuery: nil,
            wordWrap: true,
            onReconcile: onReconcile)
    }

    // MARK: - Click → activate → type → flush → onReconcile fires with the edit

    func testClickThenTypeFlushesReconcileWithByteRangeAndText() async {
        final class Box {
            var doc: QuoinDocument
            var lastRange: ByteRange?
            var lastText: String?
            init(_ d: QuoinDocument) { doc = d }
        }
        let doc = MarkdownConverter.parse("# Title\n\nHello world.\n\nTail.")
        let box = Box(doc)
        // Sanity: block[1] is the middle paragraph "Hello world." at offset 9.
        XCTAssertEqual(doc.source.substring(in: doc.blocks[1].range), "Hello world.")
        XCTAssertEqual(doc.blocks[1].range.offset, 9)

        let fired = expectation(description: "onReconcile fired")
        let (view, coordinator, window) = makeHarness(document: doc, revision: 1) { range, text in
            box.lastRange = range
            box.lastText = text
            let edit = SourceEdit(range: range, replacement: text)
            let result = try! MarkdownConverter.parseAfterEdit(previous: box.doc, edit: edit)
            box.doc = result.document
            fired.fulfill()
            return result.document
        }
        defer { window.orderOut(nil) }

        // 1. Click block[1] through the recycler's click seam → the wiring
        //    forwards to controller.activate → the row promotes to an island.
        view.onBlockClicked?(doc.blocks[1].id, CGPoint(x: 2, y: 2))
        XCTAssertEqual(coordinator.islandController?.activeIsland?.originBlockID,
                       doc.blocks[1].id,
                       "the click seam activated the clicked block's island")

        // 2. Type "X" after "Hello" (island-local UTF-16 location 5) through the
        //    real input path so the recycler → controller fan-out fires.
        let cell = view.editorCellForEditingRow()!
        cell.islandTextView.insertText("X", replacementRange: NSRange(location: 5, length: 0))

        // 3. Flush the debounce deterministically → the installed onReconcile
        //    fires (async), applies the edit, and hands the document back.
        coordinator.islandController?.flushPendingReconcile()
        await fulfillment(of: [fired], timeout: 2)

        // The reconcile closure received block[1]'s byte range and the new text.
        XCTAssertEqual(box.lastText, "HelloX world.")
        XCTAssertEqual(box.lastRange?.offset, doc.blocks[1].range.offset)
        XCTAssertEqual(box.lastRange?.length, doc.blocks[1].range.length)
        // The edit spliced byte-exactly into the document the app now owns.
        XCTAssertEqual(box.doc.source, "# Title\n\nHelloX world.\n\nTail.")

        // 4. applyReconciled runs as the continuation of the wiring Task; let it
        //    drain, then confirm the KEEP path re-anchored the island 1:1.
        await Task.yield()
        await Task.yield()
        XCTAssertNotNil(coordinator.islandController?.activeIsland,
                        "the block stayed 1:1 — the island is kept (KEEP path)")
        XCTAssertEqual(coordinator.islandController?.activeIsland?.byteRange.lowerBound, 9)
        XCTAssertEqual(coordinator.islandController?.activeIsland?.byteRange.count,
                       "HelloX world.".utf8.count,
                       "the island re-anchored onto the edited block's new range")
    }

    // MARK: - A higher-revision projection re-runs setDocument (the refresh)

    func testHigherRevisionReappliesDocument() {
        let doc = MarkdownConverter.parse("# Title\n\nHello world.\n\nTail.")
        let (view, coordinator, window) = makeHarness(document: doc, revision: 1) { _, text in
            _ = text
            return doc
        }
        defer { window.orderOut(nil) }

        // Settle the applied width to the windowed layout so the NEXT apply
        // differs ONLY in revision — isolating the revision-driven refresh.
        representable(document: doc, revision: 1)
            .apply(to: view, coordinator: coordinator, initial: false)
        XCTAssertEqual(coordinator.appliedRevision, 1)
        let settledWidth = coordinator.appliedWidth

        // The reconciled document arrives as a new projection at revision 2 — the
        // same monotonic bump ReaderModel makes after a KEEP apply. `apply` must
        // re-run `setDocument` (revision gate), advancing appliedRevision.
        let reconciled = MarkdownConverter.parse("# Title\n\nHelloX world.\n\nTail.")
        representable(document: reconciled, revision: 2)
            .apply(to: view, coordinator: coordinator, initial: false)

        XCTAssertEqual(coordinator.appliedRevision, 2,
                       "a higher-revision projection re-runs setDocument (recycler refresh)")
        XCTAssertEqual(coordinator.appliedWidth, settledWidth,
                       "width was unchanged — the refresh was revision-driven")
        XCTAssertNotNil(view.rowForBlockID(reconciled.blocks[1].id),
                        "the recycler now hosts the reconciled document's blocks")
    }
}
#endif
