#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 3, Task 2: the both-orders gate for island preservation.
///
/// A KEEP reconcile bumps `rendered.revision` → SwiftUI `updateNSView` →
/// `BlockRecyclerReaderView.apply(initial: false)` →
/// `BlockRecyclerView.updateDocumentPreservingEditing`. The KEEP edit changed the
/// block's CONTENT, so its content-hash `BlockID` changed. Pre-fix, the preserve
/// path located the editing row by the (now-stale) `_editingBlockID`, so if this
/// refresh ran BEFORE `IslandController.applyReconciled` re-anchored the id (the
/// losing race), the id-equality guard failed → fell back to `setDocument` →
/// island torn down to read-only. It "happened to work" only by ordering luck.
///
/// The fix re-anchors the editing row by the island's STABLE start byte (bytes
/// before the island never move across its own edits), so the refresh is
/// idempotent with `applyReconciled` in EITHER order. This test drives the
/// LOSING race — refresh BEFORE any `applyReconciled` — and asserts the island
/// survives and the editing identity re-points onto the new content-hash id.
@MainActor
final class IslandRefreshOrderTests: XCTestCase {
    // Simulate: reconcile produced a NEW document (block content changed → new content-hash id).
    // Refresh runs BEFORE applyReconciled re-anchors (the losing race). Island must survive.
    func testRefreshBeforeReanchorPreservesIsland() {
        let doc0 = MarkdownConverter.parse("Alpha.\n\nBravo.")
        let recycler = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = OffscreenTestWindow.make(width: 640, height: 400)
        window.contentView = recycler
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        recycler.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        recycler.setDocument(doc0, contentWidth: 600)
        recycler.layoutSubtreeIfNeeded()
        let controller = IslandController(recycler: recycler)
        let start = doc0.blocks[0].range.offset   // island start byte (stable)
        controller.activate(blockID: doc0.blocks[0].id, localPoint: .zero, in: doc0, baseRevision: 0)
        // The edited doc: "Alpha." -> "AlphaX." (block[0] content-hash id CHANGES).
        let doc1 = MarkdownConverter.parse("AlphaX.\n\nBravo.")
        XCTAssertNotEqual(doc0.blocks[0].id, doc1.blocks[0].id,
                          "precondition: the content-hash id changed with the edit")
        // Refresh FIRST (before any applyReconciled), located by island start byte:
        recycler.updateDocumentPreservingEditing(doc1, contentWidth: 600, islandStartByte: start)
        XCTAssertTrue(recycler.isEditingRow(0), "editing row preserved via start-byte re-anchor, not stale id")
        XCTAssertEqual(recycler.currentEditorCell?.blockID, doc1.blocks[0].id, "editing id re-pointed to the new content-hash id")
    }
}
#endif
