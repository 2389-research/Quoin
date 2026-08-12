#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 3, Task 7: BACKSPACE-MERGE — Backspace at a block's START merges it into
/// the previous block, the caret landing at the join (where the predecessor's
/// content ends and the merged-in text begins). This is the last structural op of
/// the original-bug fixes.
///
/// Backspace routes through the REAL command path
/// (`IslandTextView.doCommand(by: deleteBackward:)` → `onDeleteBackward` →
/// `IslandController.handleBackspace`) — the test drives it via
/// `harness.pressBackspace()` so the subclass override is genuinely exercised.
///
/// ## JOIN RULE
///
/// The merge deletes the INTER-BLOCK SEPARATOR — `[prev.upperBound, islandStart)`
/// — replacing it with `""`. For `"First\n\nSecond"` the separator is the `\n\n`
/// gap, so the merge yields `"FirstSecond"` (ONE block); the reparse decides the
/// merged block's kind. The separator lives OUTSIDE the island's own text, so the
/// merge is emitted directly through the controller's `onReconcile` seam (NOT a
/// native in-island edit), and Task-4's `applyReconciled` re-homes the island onto
/// the merged block with the caret at the join (island-local offset 5, after
/// "First").
///
/// Headless, on a real recycler in an offscreen borderless window; the stub
/// `onReconcile` applies the `SourceEdit` through the real incremental parse and
/// hands the new document + flush-time `caretDocByte` back (the Task-4 stub wiring,
/// shared verbatim with `IslandReturnSplitTests`).
@MainActor
final class IslandBackspaceMergeTests: XCTestCase {

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

    /// The Task-4 stub, shared with `IslandReturnSplitTests`. Applies each
    /// `SourceEdit` through the real incremental parse, computes `caretDocByte` at
    /// flush, and hands the result back. For the merge the controller fires
    /// `onReconcile(separator, "", 0)`, so this builds
    /// `SourceEdit(range: separator, replacement: "")` and
    /// `caretDocByte == separator.offset` (the join).
    private func installStub(
        _ controller: IslandController, startingFrom doc: QuoinDocument
    ) -> (doc: () -> QuoinDocument, rev: () -> Int) {
        final class Box { var doc: QuoinDocument; var rev = 0; init(_ d: QuoinDocument) { doc = d } }
        let box = Box(doc)
        controller.onReconcile = { [weak controller] range, newText, caret in
            let edit = SourceEdit(range: range, replacement: newText)
            let result = try! MarkdownConverter.parseAfterEdit(previous: box.doc, edit: edit)
            box.doc = result.document
            box.rev += 1
            let caretDocByte = IslandCaretMapping.documentByte(
                localUTF16: caret, islandSource: newText, islandByteStart: range.offset)
            controller?.applyReconciled(result.document, caretDocByte: caretDocByte)
        }
        return ({ box.doc }, { box.rev })
    }

    // MARK: - The merge: Backspace at block start joins into the predecessor

    func testBackspaceAtBlockStartMergesIntoPrevious() {
        let (v, doc, window) = makeRecycler("First\n\nSecond")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let stub = installStub(controller, startingFrom: doc)

        // Activate the SECOND block, caret at its very start ({0,0}).
        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        XCTAssertNotNil(controller.activeIsland)
        let cell = v.editorCellForEditingRow()!
        XCTAssertEqual(cell.islandTextView.string, "Second")
        cell.islandTextView.setSelectedRange(NSRange(location: 0, length: 0))

        // Press Backspace through the REAL command path.
        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: stub.rev)
        harness.pressBackspace()
        controller.flushPendingReconcile()

        // JOIN RULE = separator → "": the two blocks merged into "FirstSecond",
        // ONE block. The island survived and re-homed onto the merged block, caret
        // at the join (island-local offset 5, after "First").
        XCTAssertEqual(stub.doc().source, "FirstSecond")
        XCTAssertEqual(stub.doc().blocks.count, 1, "the two blocks merged into one")
        XCTAssertNotNil(controller.activeIsland, "the island stays active on the merged block")
        XCTAssertEqual(stub.doc().source.substring(in: ByteRange(controller.activeIsland!.byteRange)),
                       "FirstSecond", "island re-homed onto the merged block")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "FirstSecond")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 5,
                       "caret at the join, after \"First\"")

        // Typing "X" lands at the join → "FirstXSecond".
        let c2 = v.editorCellForEditingRow()!
        c2.islandTextView.insertText("X", replacementRange: NSRange(location: 5, length: 0))
        c2.islandTextView.setSelectedRange(NSRange(location: 6, length: 0))
        controller.flushPendingReconcile()

        XCTAssertEqual(stub.doc().source, "FirstXSecond",
                       "the caret sat at the join; the X landed there")
        XCTAssertEqual(stub.doc().blocks.count, 1)
    }

    // MARK: - Counter-test: Backspace NOT at offset 0 is a normal within-island delete

    func testBackspaceMidTextDoesNotMerge() {
        let (v, doc, window) = makeRecycler("First\n\nSecond")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let stub = installStub(controller, startingFrom: doc)

        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = v.editorCellForEditingRow()!
        // Caret AFTER "Se" (offset 2), mid-text. Drive the REAL native Backspace via
        // the command path: the hook returns false, so `super` deletes the "e".
        cell.islandTextView.setSelectedRange(NSRange(location: 2, length: 0))
        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: stub.rev)
        harness.pressBackspace()

        // Native single-char delete ran ("Second" → "Scond"), proving the hook fell
        // through; NO merge fired (the debounce did not flush), so the document is
        // untouched and the island stays on the SAME second block.
        XCTAssertEqual(cell.islandTextView.string, "Scond",
                       "native deleteBackward removed the 'e' (hook returned false)")
        XCTAssertEqual(stub.doc().source, "First\n\nSecond", "no merge fired")
        XCTAssertNotNil(controller.activeIsland)
        XCTAssertEqual(stub.doc().source.substring(in: ByteRange(controller.activeIsland!.byteRange)),
                       "Second", "island still on the second block")
    }

    // MARK: - Counter-test: a non-empty selection at location 0 is a native delete

    func testBackspaceWithSelectionAtStartDoesNotMerge() {
        let (v, doc, window) = makeRecycler("First\n\nSecond")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let stub = installStub(controller, startingFrom: doc)

        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = v.editorCellForEditingRow()!
        // A NON-EMPTY selection anchored AT location 0 ({0,3} = "Sec"). This pins the
        // `== NSRange(0,0)` guard comparing BOTH location and length: a selection
        // must NOT be read as a caret-at-start merge.
        cell.islandTextView.setSelectedRange(NSRange(location: 0, length: 3))
        let handled = controller.handleBackspace()
        XCTAssertFalse(handled,
                       "a non-empty selection at location 0 is a native selection-delete, not a merge")

        // The merge did NOT fire — the document is untouched and the island stays put.
        XCTAssertEqual(stub.doc().source, "First\n\nSecond", "no merge fired for a selection-delete")
        XCTAssertNotNil(controller.activeIsland)
        XCTAssertEqual(stub.doc().source.substring(in: ByteRange(controller.activeIsland!.byteRange)),
                       "Second", "island still on the second block")
    }

    // MARK: - Nearest predecessor across 3 blocks

    func testBackspaceMergesIntoNearestPredecessor() {
        let (v, doc, window) = makeRecycler("First\n\nSecond\n\nThird")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let stub = installStub(controller, startingFrom: doc)

        // Activate the THIRD block, caret at {0,0}. The merge must target the NEAREST
        // predecessor ("Second"), not "First".
        controller.activate(blockID: doc.blocks[2].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = v.editorCellForEditingRow()!
        XCTAssertEqual(cell.islandTextView.string, "Third")
        cell.islandTextView.setSelectedRange(NSRange(location: 0, length: 0))
        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: stub.rev)
        harness.pressBackspace()
        controller.flushPendingReconcile()

        // "Third" merged into "Second" (the nearest predecessor); "First" untouched.
        XCTAssertEqual(stub.doc().source, "First\n\nSecondThird")
        XCTAssertEqual(stub.doc().blocks.count, 2, "First stays; Second+Third merged")
        XCTAssertNotNil(controller.activeIsland)
        XCTAssertEqual(stub.doc().source.substring(in: ByteRange(controller.activeIsland!.byteRange)),
                       "SecondThird", "island re-homed onto the merged Second+Third block")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 6,
                       "caret at the join, after \"Second\"")
    }

    // MARK: - Multi-byte predecessor: the join maps in UTF-16, not bytes

    func testBackspaceMergeJoinMapsMultibytePredecessor() {
        let (v, doc, window) = makeRecycler("Café\n\nSecond")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let stub = installStub(controller, startingFrom: doc)

        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = v.editorCellForEditingRow()!
        cell.islandTextView.setSelectedRange(NSRange(location: 0, length: 0))
        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: stub.rev)
        harness.pressBackspace()
        controller.flushPendingReconcile()

        // "é" is 2 UTF-8 bytes but 1 UTF-16 unit: the join byte (5, after "Café") maps
        // to island-local UTF-16 offset 4.
        XCTAssertEqual(stub.doc().source, "CaféSecond")
        XCTAssertEqual(stub.doc().blocks.count, 1)
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "CaféSecond")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 4,
                       "caret at the join in UTF-16 units (after the 4-glyph \"Café\")")
    }

    // MARK: - Counter-test: Backspace at {0,0} on the FIRST block has no predecessor

    func testBackspaceAtStartOfFirstBlockIsNoOp() {
        let (v, doc, window) = makeRecycler("First\n\nSecond")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let stub = installStub(controller, startingFrom: doc)

        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = v.editorCellForEditingRow()!
        XCTAssertEqual(cell.islandTextView.string, "First")
        cell.islandTextView.setSelectedRange(NSRange(location: 0, length: 0))

        let handled = controller.handleBackspace()
        XCTAssertFalse(handled, "no predecessor → native no-op, never a splice")

        XCTAssertEqual(stub.doc().source, "First\n\nSecond", "document unchanged")
        XCTAssertNotNil(controller.activeIsland, "island still active on the first block")
        XCTAssertEqual(stub.doc().source.substring(in: ByteRange(controller.activeIsland!.byteRange)),
                       "First", "island still on the first block")
    }

    // MARK: - Async ordering: type-then-immediately-Backspace-at-0

    /// An ASYNC stub that models the REAL app's `onReconcile` seam
    /// (`Task { @MainActor in let doc = await onReconcile(range, text);
    /// applyReconciled(doc, ...) }`): each reconcile's apply is DEFERRED onto a
    /// fresh `@MainActor` Task rather than applied inline. `parseAfterEdit` reads
    /// `box.doc` at TASK-RUN time (not enqueue time), and `applyReconciled` runs
    /// only when that Task runs — so a merge fired as a SIBLING Task before the
    /// flush's apply landed would parse+splice against the WRONG (pre-flush)
    /// document. `applied` counts landed applies so the test can drain.
    private func installAsyncStub(
        _ controller: IslandController, startingFrom doc: QuoinDocument
    ) -> (doc: () -> QuoinDocument, applied: () -> Int) {
        final class Box { var doc: QuoinDocument; var applied = 0; init(_ d: QuoinDocument) { doc = d } }
        let box = Box(doc)
        controller.onReconcile = { [weak controller] range, newText, caret in
            let edit = SourceEdit(range: range, replacement: newText)
            let caretDocByte = IslandCaretMapping.documentByte(
                localUTF16: caret, islandSource: newText, islandByteStart: range.offset)
            Task { @MainActor in
                let result = try! MarkdownConverter.parseAfterEdit(previous: box.doc, edit: edit)
                box.doc = result.document
                controller?.applyReconciled(result.document, caretDocByte: caretDocByte)
                box.applied += 1
            }
        }
        return ({ box.doc }, { box.applied })
    }

    /// Drain queued `@MainActor` reconcile Tasks until `applied()` reaches `count`
    /// (or a generous spin cap), yielding between polls so enqueued Tasks can run.
    @MainActor
    private func drain(until count: Int, _ applied: () -> Int) async {
        var spins = 0
        while applied() < count && spins < 500 {
            await Task.yield()
            spins += 1
        }
    }

    func testTypeThenBackspaceAtZeroOrdersFlushBeforeMerge() async {
        let (v, doc, window) = makeRecycler("First\n\nSecond")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)
        let stub = installAsyncStub(controller, startingFrom: doc)

        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = v.editorCellForEditingRow()!
        // Type "X" at the START of the second block → island "XSecond", a PENDING
        // debounced KEEP edit (the 200ms timer will not fire in-test).
        cell.islandTextView.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "XSecond")

        // Move the caret to {0,0} and Backspace-at-0 WHILE the typed edit is still
        // unflushed. `handleBackspace` decides consume synchronously, flushes the
        // typed edit, and DEFERS the merge behind the flush's async apply.
        cell.islandTextView.setSelectedRange(NSRange(location: 0, length: 0))
        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { 0 })
        harness.pressBackspace()

        // Two applies must land IN ORDER: (1) the typed KEEP edit
        // ("First\n\nSecond" → "First\n\nXSecond"), then (2) the merge fired from the
        // flush's applyReconciled ("First\n\nXSecond" → "FirstXSecond"). If they
        // raced and the merge parsed first, the stub's `try!` parseAfterEdit would
        // splice the flush's whole-island range past document end and crash.
        await drain(until: 2, stub.applied)

        XCTAssertEqual(stub.doc().source, "FirstXSecond",
                       "flush landed before the merge; the typed X survived the merge")
        XCTAssertEqual(stub.doc().blocks.count, 1)
        XCTAssertNotNil(controller.activeIsland, "island active on the merged block")
        XCTAssertEqual(stub.doc().source.substring(in: ByteRange(controller.activeIsland!.byteRange)),
                       "FirstXSecond")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "FirstXSecond")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 5,
                       "caret at the join (after \"First\", before the typed X)")
    }
}
#endif
