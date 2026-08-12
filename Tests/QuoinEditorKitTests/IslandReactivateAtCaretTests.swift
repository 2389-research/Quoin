#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 3, Task 4: the RE-ACTIVATE-AT-CARET primitive.
///
/// Phase 2 refused structural ops: an interior newline that split the island's
/// block tore the island down (`teardownIsland`). Task 4 inverts that: when a
/// reconcile SPLITS the block, the controller RE-HOMES the island into the block
/// that CONTAINS the reconcile-time caret and keeps editing. This is the shared
/// spine of Return-split (Task 5) and Backspace-merge (Task 7).
///
/// The stub `onReconcile` mirrors the app: it applies the `SourceEdit` through the
/// real incremental parse (`MarkdownConverter.parseAfterEdit`), computes
/// `caretDocByte` at FLUSH time (bytes before the caret don't move —
/// `range.offset + UTF8IndexMap(flushedText).utf8(fromUTF16: caret)`), and hands
/// the new document + `caretDocByte` back through `applyReconciled`.
///
/// Headless, on a real recycler in an offscreen borderless window (same recipe as
/// `IslandReconcileTests`). Flushing is deterministic via `flushPendingReconcile()`.
@MainActor
final class IslandReactivateAtCaretTests: XCTestCase {

    private func makeRecycler(_ md: String) -> (BlockRecyclerView, QuoinDocument, NSWindow) {
        let doc = MarkdownConverter.parse(md)
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = v
        window.makeKeyAndOrderFront(nil)
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()
        return (v, doc, window)
    }

    /// Stub that applies the edit, computes `caretDocByte` at flush, and re-anchors.
    private func installReconcileStub(
        _ controller: IslandController, startingFrom doc: QuoinDocument
    ) -> () -> QuoinDocument {
        final class Box { var doc: QuoinDocument; init(_ d: QuoinDocument) { doc = d } }
        let box = Box(doc)
        controller.onReconcile = { [weak controller] range, newText, caret in
            let edit = SourceEdit(range: range, replacement: newText)
            let result = try! MarkdownConverter.parseAfterEdit(previous: box.doc, edit: edit)
            box.doc = result.document
            let caretDocByte = IslandCaretMapping.documentByte(
                localUTF16: caret, islandSource: newText, islandByteStart: range.offset)
            controller?.applyReconciled(result.document, caretDocByte: caretDocByte)
        }
        return { box.doc }
    }

    // MARK: - SPLIT: an interior \n\n re-homes the island into the caret's new block

    func testInteriorSplitReactivatesAtCaretBlock() {
        // "HelloWorld" (no interior spaces) keeps the split boundaries free of the
        // leading/trailing-space ambiguity in a paragraph's source range.
        let (v, doc, window) = makeRecycler("# Title\n\nHelloWorld\n\nTail.")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let currentDoc = installReconcileStub(controller, startingFrom: doc)

        XCTAssertEqual(doc.source.substring(in: doc.blocks[1].range), "HelloWorld")
        XCTAssertEqual(doc.blocks[1].range.offset, 9)

        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        XCTAssertNotNil(controller.activeIsland)

        // Type "\n\n" after "Hello" (island-local offset 5): "HelloWorld" splits into
        // "Hello" + "World"; the caret lands at the START of the second paragraph.
        // (Headless `insertText` inserts the text but does not advance the selection,
        // so seat the post-type caret explicitly — the real first responder does this.)
        let cell = v.editorCellForEditingRow()!
        cell.islandTextView.insertText("\n\n", replacementRange: NSRange(location: 5, length: 0))
        cell.islandTextView.setSelectedRange(NSRange(location: 7, length: 0))
        controller.flushPendingReconcile()

        // The document split byte-exactly.
        XCTAssertEqual(currentDoc().source, "# Title\n\nHello\n\nWorld\n\nTail.")

        let newDoc = currentDoc()
        // caretDocByte = island start (9) + local caret (5 + 2 typed) = 16.
        let caretDocByte = 16
        let caretRec = BlockListModel(document: newDoc).record(at: caretDocByte)!
        XCTAssertEqual(newDoc.source.substring(in: ByteRange(caretRec.byteRange)), "World",
                       "the caret's block is the SECOND paragraph")
        XCTAssertEqual(caretRec.byteRange.lowerBound, 16)

        // RE-ACTIVATED, not torn down: the island stays active and re-homed onto the
        // caret's block.
        XCTAssertNotNil(controller.activeIsland, "a split RE-HOMES the island (no teardown)")
        XCTAssertEqual(controller.activeIsland?.byteRange, caretRec.byteRange,
                       "the island re-anchored onto the block CONTAINING the caret")
        XCTAssertNotNil(v.editingRowForTest, "the editing row is preserved (not swapped to read-only)")

        // The live island cell hosts the caret block's source with the caret at its
        // start (caretDocByte maps to island-local 0).
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "World")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 0,
                       "the caret sits at the caret block's start")
    }

    // MARK: - KEEP: a typed char (no split) still re-anchors 1:1 with caret preserved

    func testTypedCharKeepsAndReseatsCaret() {
        let (v, doc, window) = makeRecycler("# Title\n\nHelloWorld\n\nTail.")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let currentDoc = installReconcileStub(controller, startingFrom: doc)

        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        let islandID = controller.activeIsland!.id

        // Type "X" after "Hello" (island-local offset 5) → "HelloXWorld"; no split.
        // (Seat the post-type caret explicitly — see the split test's note.)
        let cell = v.editorCellForEditingRow()!
        cell.islandTextView.insertText("X", replacementRange: NSRange(location: 5, length: 0))
        cell.islandTextView.setSelectedRange(NSRange(location: 6, length: 0))
        controller.flushPendingReconcile()

        XCTAssertEqual(currentDoc().source, "# Title\n\nHelloXWorld\n\nTail.")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNotNil(controller.activeIsland, "no split → island kept")
        XCTAssertEqual(controller.activeIsland?.id, islandID, "the IslandUnit.id is preserved")
        XCTAssertEqual(controller.activeIsland?.byteRange.lowerBound, 9)
        XCTAssertEqual(controller.activeIsland?.byteRange.count, "HelloXWorld".utf8.count)
        // The caret is re-seated 1:1 from caretDocByte (15) → island-local 6 (after
        // the typed "X").
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 6,
                       "the caret re-seats 1:1 through caretDocByte")
    }

    // MARK: - No caret → safe teardown fallback

    func testSplitWithNilCaretTearsDown() {
        let (v, doc, window) = makeRecycler("# Title\n\n## Section\n\nTail.")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        final class Box { var doc: QuoinDocument; init(_ d: QuoinDocument) { doc = d } }
        let box = Box(doc)
        // Legacy stub: no caretDocByte handed back (the pre-Task-4 signature).
        controller.onReconcile = { [weak controller] range, newText, _ in
            let edit = SourceEdit(range: range, replacement: newText)
            let result = try! MarkdownConverter.parseAfterEdit(previous: box.doc, edit: edit)
            box.doc = result.document
            controller?.applyReconciled(result.document)   // caretDocByte defaults nil
        }

        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = v.editorCellForEditingRow()!
        cell.islandTextView.insertText("\n", replacementRange: NSRange(location: 6, length: 0))
        controller.flushPendingReconcile()

        // Without a caret to re-home, a split falls back to the safe teardown.
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.activeIsland, "no caret → split tears the island down (safe fallback)")
    }

    // MARK: - Both orders converge on the caret's block (the projection-refresh race)

    /// Drive the flush WITHOUT auto-applying, so the test can run the refresh
    /// (`updateDocumentPreservingEditing`) and `applyReconciled` in a chosen order.
    private struct Flush { var range: ByteRange; var text: String; var caret: Int; var newDoc: QuoinDocument }

    private func activateTypeAndCaptureFlush(
        _ v: BlockRecyclerView, _ doc: QuoinDocument, _ controller: IslandController
    ) -> Flush {
        final class Cap { var range = ByteRange(offset: 0, length: 0); var text = ""; var caret = 0 }
        let cap = Cap()
        var newDocBox: QuoinDocument?
        controller.onReconcile = { range, text, caret in
            cap.range = range; cap.text = text; cap.caret = caret
            let edit = SourceEdit(range: range, replacement: text)
            newDocBox = try! MarkdownConverter.parseAfterEdit(previous: doc, edit: edit).document
        }
        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = v.editorCellForEditingRow()!
        cell.islandTextView.insertText("\n\n", replacementRange: NSRange(location: 5, length: 0))
        cell.islandTextView.setSelectedRange(NSRange(location: 7, length: 0))
        controller.flushPendingReconcile()
        return Flush(range: cap.range, text: cap.text, caret: cap.caret, newDoc: newDocBox!)
    }

    func testBothOrders_refreshBeforeApplyReconciled_survives() {
        let (v, doc, window) = makeRecycler("# Title\n\nHelloWorld\n\nTail.")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let flush = activateTypeAndCaptureFlush(v, doc, controller)
        let caretDocByte = IslandCaretMapping.documentByte(
            localUTF16: flush.caret, islandSource: flush.text, islandByteStart: flush.range.offset)!
        let caretRec = BlockListModel(document: flush.newDoc).record(at: caretDocByte)!

        // ORDER 2 (the defensive race): the SwiftUI-equivalent refresh runs FIRST,
        // with the STALE island start (applyReconciled has not re-homed yet)…
        let staleStart = controller.activeIsland!.byteRange.lowerBound   // 9
        v.updateDocumentPreservingEditing(flush.newDoc, contentWidth: 600, islandStartByte: staleStart)
        // …then the controller re-homes at the caret.
        controller.applyReconciled(flush.newDoc, caretDocByte: caretDocByte)

        // The island SURVIVES and ends re-homed onto the caret's block; the live cell
        // is still there and still first responder (never torn down).
        XCTAssertNotNil(controller.activeIsland)
        XCTAssertEqual(controller.activeIsland?.byteRange, caretRec.byteRange)
        XCTAssertNotNil(v.currentEditorCell)
        XCTAssertTrue(window.firstResponder === v.currentEditorCell?.islandTextView)
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "World")
    }

    func testBothOrders_applyReconciledBeforeRefresh_survives() {
        let (v, doc, window) = makeRecycler("# Title\n\nHelloWorld\n\nTail.")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let flush = activateTypeAndCaptureFlush(v, doc, controller)
        let caretDocByte = IslandCaretMapping.documentByte(
            localUTF16: flush.caret, islandSource: flush.text, islandByteStart: flush.range.offset)!
        let caretRec = BlockListModel(document: flush.newDoc).record(at: caretDocByte)!

        // ORDER 1 (the real common case): the controller re-homes FIRST…
        controller.applyReconciled(flush.newDoc, caretDocByte: caretDocByte)
        // …then the refresh runs with the now-updated island start.
        let islandStart = controller.activeIsland!.byteRange.lowerBound   // 16 (caret block)
        v.updateDocumentPreservingEditing(flush.newDoc, contentWidth: 600, islandStartByte: islandStart)

        // Fully converged: island on the caret's block, editing cell at the caret
        // block's row, first responder preserved.
        XCTAssertNotNil(controller.activeIsland)
        XCTAssertEqual(controller.activeIsland?.byteRange, caretRec.byteRange)
        XCTAssertNotNil(v.currentEditorCell)
        XCTAssertTrue(window.firstResponder === v.currentEditorCell?.islandTextView)
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "World")
        // The recycler shows the new (4-block) document with the editing row on the
        // caret's block.
        XCTAssertEqual(v.numberOfRowsForTest, flush.newDoc.blocks.count)
        let caretRow = v.rowForBlockID(caretRec.blockID)
        XCTAssertNotNil(caretRow)
        XCTAssertEqual(v.editingRowForTest, caretRow, "editing row is the caret's block row")
    }
}
#endif
