#if canImport(AppKit)
import XCTest
import AppKit
import SwiftUI
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 2 final-review regression: the CRITICAL flag-on data-loss bug.
///
/// The real app loop is: type in the island → debounce → `IslandController`
/// reconcile fires `onReconcile` → `ReaderModel.reconcileIsland` applies the edit
/// and BUMPS `rendered.revision` → SwiftUI re-evaluates → `updateNSView` →
/// `BlockRecyclerReaderView.apply(initial: false)`. The revision moved, so `apply`
/// re-projects the document into the recycler.
///
/// Pre-fix, that re-projection went through `setDocument`, which UNCONDITIONALLY
/// `clearEditingWithoutReload()`d + full-`reloadData()`d — reverting the
/// just-reconciled island row to a read-only cell and dropping first responder +
/// caret, while the controller's `activeIsland` stayed set. The recycler and
/// controller were then DESYNCED: the next click on ANOTHER block ran
/// `activate → flushActiveIsland`, which read the (now-nil) editor cell and fell
/// back to `textView?.string ?? ""`, firing `onReconcile(range, "")` — an EMPTY
/// splice that DELETED the first block's content.
///
/// This test drives that exact revision-driven refresh — `apply(initial: false)`
/// with the reconciled document at a bumped revision — and asserts the island
/// SURVIVES, the document is intact, and a subsequent activation of a DIFFERENT
/// block does NOT empty-splice. It FAILS on the pre-fix code (the island is torn
/// down and the second click deletes "HelloX world.").
///
/// Headless, on the real `BlockRecyclerReaderView` wiring (`makeRecycler` installs
/// the `IslandController` on the Coordinator) in an offscreen borderless window so
/// first-responder handoff is real. The `onReconcile` stub mirrors
/// `ReaderModel.reconcileIsland`: it applies the `SourceEdit` through the real
/// incremental parse (`MarkdownConverter.parseAfterEdit`) and hands the resulting
/// document back through `applyReconciled`, tracking a monotonic revision so the
/// test can drive the projection refresh exactly as SwiftUI would.
@MainActor
final class IslandRefreshSurvivalTests: XCTestCase {

    /// Mutable box holding the app-owned document + a monotonic revision, so the
    /// synchronous reconcile stub can update both and the test can build the
    /// refreshed representable.
    @MainActor
    private final class DocBox {
        var doc: QuoinDocument
        var revision: Int
        var reconcileCount = 0
        init(_ d: QuoinDocument, revision: Int) { self.doc = d; self.revision = revision }

        /// Synchronous mirror of `ReaderModel.reconcileIsland`: apply the edit
        /// through the real incremental parse and bump the revision, returning the
        /// new document.
        func reconcileSync(range: ByteRange, text: String) -> QuoinDocument {
            reconcileCount += 1
            let edit = SourceEdit(range: range, replacement: text)
            let result = try! MarkdownConverter.parseAfterEdit(previous: doc, edit: edit)
            doc = result.document
            revision += 1
            return result.document
        }
    }

    private func rendered(revision: Int) -> RenderedDocument {
        RenderedDocument(attributed: NSAttributedString(), blockRanges: [:], revision: revision)
    }

    private func repr(document: QuoinDocument, revision: Int,
                      onReconcile: @escaping (ByteRange, String) async -> QuoinDocument
    ) -> BlockRecyclerReaderView {
        BlockRecyclerReaderView(
            document: document,
            rendered: rendered(revision: revision),
            theme: Theme(),
            renderer: AttributedRenderer(theme: Theme()),
            scrollTarget: nil,
            onTopBlockChange: nil,
            searchQuery: nil,
            onReconcile: onReconcile)
    }

    func testIslandSurvivesItsOwnReconcileProjectionRefresh() {
        let source = "# Title\n\nHello world.\n\nTail."
        let doc0 = MarkdownConverter.parse(source)
        // Sanity: block[1] is the middle paragraph "Hello world." at byte offset 9.
        XCTAssertEqual(doc0.source.substring(in: doc0.blocks[1].range), "Hello world.")
        XCTAssertEqual(doc0.blocks[1].range.offset, 9)

        let box = DocBox(doc0, revision: 1)

        // The app closure passed to the representable. The synchronous
        // `controller.onReconcile` override below is what actually drives the
        // reconcile deterministically (the installed async `Task` hop is
        // non-deterministic under `flushPendingReconcile`), so this only needs to
        // satisfy the wiring signature.
        let appReconcile: (ByteRange, String) async -> QuoinDocument = { _, _ in box.doc }

        // Stand up the REAL reader wiring: `makeRecycler` installs the
        // `IslandController` on the Coordinator and applies the initial document.
        let coordinator = BlockRecyclerReaderView.Coordinator()
        let view = repr(document: doc0, revision: 1, onReconcile: appReconcile)
            .makeRecycler(coordinator: coordinator)
        let window = OffscreenTestWindow.make(width: 640, height: 480)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        view.layoutSubtreeIfNeeded()

        let controller = coordinator.islandController!

        // Replace the installed async `onReconcile` with its synchronous
        // equivalent so the reconcile → re-anchor is deterministic under
        // `flushPendingReconcile()`. The body mirrors `ReaderModel.reconcileIsland`
        // (parse + bump), and this leaves the CRITICAL path under test — `apply`'s
        // projection refresh — fully intact.
        controller.onReconcile = { [weak controller] range, text, _ in
            let result = box.reconcileSync(range: range, text: text)
            controller?.applyReconciled(result)
        }

        // 1) Activate block[1] and type "X" after "Hello" (island-local offset 5).
        controller.activate(blockID: doc0.blocks[1].id, localPoint: .zero, in: doc0, baseRevision: 1)
        let islandID = controller.activeIsland!.id
        let cell = view.editorCellForEditingRow()!
        XCTAssertTrue(window.firstResponder === cell.islandTextView,
                      "the island cell should be first responder after activation")
        cell.islandTextView.insertText("X", replacementRange: NSRange(location: 5, length: 0))

        // 2) The reconcile fires (debounce flushed deterministically): the edit is
        // applied byte-exactly, the revision bumps, and the island re-anchors.
        controller.flushPendingReconcile()
        XCTAssertEqual(box.doc.source, "# Title\n\nHelloX world.\n\nTail.",
                       "the typed edit is spliced byte-exactly by the app")
        XCTAssertNotNil(controller.activeIsland, "island survives the reconcile (controller side)")
        XCTAssertEqual(controller.activeIsland?.id, islandID, "the IslandUnit.id is preserved")

        // 3) THE CRITICAL STEP: drive the SwiftUI-equivalent projection refresh —
        // `apply(initial: false)` with the reconciled document at the bumped
        // revision. Pre-fix this ran `setDocument` → cleared editing + full reload,
        // tearing the island down.
        XCTAssertGreaterThan(box.revision, 1, "the reconcile bumped the revision")
        repr(document: box.doc, revision: box.revision, onReconcile: appReconcile)
            .apply(to: view, coordinator: coordinator, initial: false)

        // (a) The island SURVIVES the refresh: the live editor cell is still there,
        // still first responder, and the controller's island is still set and
        // re-anchored onto the edited block ("HelloX world." — 13 bytes at 9).
        XCTAssertNotNil(view.currentEditorCell,
                        "the live island cell must survive the revision-driven refresh")
        XCTAssertTrue(window.firstResponder === view.currentEditorCell?.islandTextView,
                      "the island cell must remain first responder across the refresh")
        XCTAssertNotNil(controller.activeIsland,
                        "the controller's island must remain active across the refresh")
        XCTAssertEqual(controller.activeIsland?.byteRange.lowerBound, 9)
        XCTAssertEqual(controller.activeIsland?.byteRange.count, "HelloX world.".utf8.count,
                       "the island re-anchored onto the edited block's new range")
        XCTAssertTrue(view.currentEditorCell?.islandTextView.string == "HelloX world.",
                      "the live island still hosts the typed text")

        // (b) The document is NOT corrupted.
        XCTAssertEqual(box.doc.source, "# Title\n\nHelloX world.\n\nTail.")

        // (c) Activating a DIFFERENT block must NOT empty-splice / delete block[1]'s
        // content. Pre-fix, block[1]'s island was orphaned (cell nil, island still
        // set), so this `activate → flushActiveIsland` fired `onReconcile(range, "")`
        // and deleted "HelloX world.". Post-fix the live cell is present, so the
        // flush reads the real text (an idempotent re-splice) and the content stays.
        let block0ID = box.doc.blocks[0].id
        controller.activate(blockID: block0ID, localPoint: .zero, in: box.doc, baseRevision: box.revision)
        XCTAssertTrue(box.doc.source.contains("HelloX world."),
                      "activating another block must NOT empty-splice the first block's content")
        XCTAssertEqual(box.doc.source, "# Title\n\nHelloX world.\n\nTail.",
                       "the document is unchanged by the block switch")
    }
}
#endif
