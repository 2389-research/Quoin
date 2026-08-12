#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 2, Task 6: reconciliation — island text flows back into the document.
/// The `IslandController` debounces the editing cell's live text changes, builds
/// a `SourceEdit(range: island.byteRange, replacement: islandText)`, fires
/// `onReconcile`, and — on the KEEP path — re-anchors the island against the
/// document the app produced. Per the NO-STRUCTURAL-OPS rule, an interior
/// newline that splits the origin block deactivates the island rather than
/// editing across the split.
///
/// The stub `onReconcile` applies the `SourceEdit` through the real incremental
/// parse (`MarkdownConverter.parseAfterEdit`, exactly what `DocumentSession`
/// uses) and hands the resulting document back via `applyReconciled` — the same
/// two-phase seam the app uses (fire the edit; receive the new document).
///
/// Headless, on a real recycler in an offscreen borderless window (same recipe
/// as `IslandControllerTests`). Flushing is deterministic via
/// `flushPendingReconcile()` — no sleeping on the real 200 ms debounce.
@MainActor
final class IslandReconcileTests: XCTestCase {

    private func makeRecycler(_ md: String) -> (BlockRecyclerView, QuoinDocument, NSWindow) {
        let doc = MarkdownConverter.parse(md)
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = OffscreenTestWindow.make(width: 640, height: 480)
        window.contentView = v
        window.makeKeyAndOrderFront(nil)
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()
        return (v, doc, window)
    }

    /// Wire a stub `onReconcile` that applies the edit and re-anchors, tracking
    /// the produced document so the test can assert byte-exactness.
    private func installReconcileStub(
        _ controller: IslandController, startingFrom doc: QuoinDocument
    ) -> () -> QuoinDocument {
        final class Box { var doc: QuoinDocument; init(_ d: QuoinDocument) { doc = d } }
        let box = Box(doc)
        controller.onReconcile = { [weak controller] range, newText, _ in
            let edit = SourceEdit(range: range, replacement: newText)
            let result = try! MarkdownConverter.parseAfterEdit(previous: box.doc, edit: edit)
            box.doc = result.document
            controller?.applyReconciled(result.document)
        }
        return { box.doc }
    }

    // MARK: - KEEP: a typed char splices byte-exactly; the island id is preserved

    func testTypedCharSplicesByteExactAndPreservesIslandID() {
        let (v, doc, window) = makeRecycler("# Title\n\nHello world.\n\nTail.")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let currentDoc = installReconcileStub(controller, startingFrom: doc)

        // Sanity: block[1] is the middle paragraph "Hello world." at offset 9.
        XCTAssertEqual(doc.source.substring(in: doc.blocks[1].range), "Hello world.")
        XCTAssertEqual(doc.blocks[1].range.offset, 9)

        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        let islandID = controller.activeIsland!.id

        // Type "X" after "Hello" (island-local location 5) through the real input
        // path so the recycler → controller fan-out fires.
        let cell = v.editorCellForEditingRow()!
        cell.islandTextView.insertText("X", replacementRange: NSRange(location: 5, length: 0))

        controller.flushPendingReconcile()

        // The document is spliced BYTE-EXACTLY: the X lands in block[1]'s range,
        // every untouched region is identical.
        XCTAssertEqual(currentDoc().source, "# Title\n\nHelloX world.\n\nTail.")
        XCTAssertEqual(String(currentDoc().source.prefix(9)), "# Title\n\n",
                       "the prefix (block[0] + gap) is untouched")
        XCTAssertTrue(currentDoc().source.hasSuffix("\n\nTail."),
                      "the suffix (gap + block[2]) is untouched")

        // KEEP: the island stays active, its id preserved, byte range re-anchored
        // to the new content ("HelloX world." — 13 bytes at offset 9).
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNotNil(controller.activeIsland, "the block stayed 1:1 — island kept")
        XCTAssertEqual(controller.activeIsland?.id, islandID, "the IslandUnit.id is preserved")
        XCTAssertEqual(controller.activeIsland?.byteRange.lowerBound, 9)
        XCTAssertEqual(controller.activeIsland?.byteRange.count, "HelloX world.".utf8.count,
                       "the island re-anchors onto the edited block's new range")
    }

    // MARK: - NO STRUCTURAL OPS: an interior newline that splits the block deactivates

    func testInteriorNewlineSplitDeactivates() {
        let (v, doc, window) = makeRecycler("# Title\n\n## Section\n\nTail.")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let currentDoc = installReconcileStub(controller, startingFrom: doc)

        // block[1] is the heading "## Section" at offset 9.
        XCTAssertEqual(doc.source.substring(in: doc.blocks[1].range), "## Section")

        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        XCTAssertNotNil(controller.activeIsland)

        // Type a newline after "## Sec" (island-local location 6): a heading is a
        // single line, so "## Sec\ntion" parses as heading + paragraph — the
        // origin block SPLITS.
        let cell = v.editorCellForEditingRow()!
        cell.islandTextView.insertText("\n", replacementRange: NSRange(location: 6, length: 0))

        controller.flushPendingReconcile()

        // The edit still applied byte-exactly (the app owns the document)…
        XCTAssertEqual(currentDoc().source, "# Title\n\n## Sec\ntion\n\nTail.")
        // …but the island refused to edit across the split: it deactivated per the
        // no-structural-ops rule (idle, no active island), rather than hopping the
        // caret into a split block or merging.
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.activeIsland, "a structural split tears the island down")
        XCTAssertNil(v.editingRowForTest, "the editing row swapped back to read-only")
    }

    // MARK: - No spurious flush: a debounce with no active island is inert

    func testFlushWithoutActiveIslandIsNoOp() {
        let (v, doc, window) = makeRecycler("# Title\n\nBody.")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        var reconciled = 0
        controller.onReconcile = { _, _, _ in reconciled += 1 }

        controller.flushPendingReconcile()
        XCTAssertEqual(reconciled, 0, "no active island → no reconcile fires")
        _ = doc
    }
}
#endif
