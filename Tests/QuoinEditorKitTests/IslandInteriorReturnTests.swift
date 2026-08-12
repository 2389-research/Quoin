#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 3, Task 5b: **INTERIOR END-OF-PARAGRAPH RETURN** — the last §14
/// Definition-of-Done functional gap, and the canonical bug the whole
/// rearchitecture exists to fix.
///
/// ## The gap
///
/// `First\n\nMiddle\n\nLast`, caret at the END of `Middle`, Return. Pre-fix:
/// `handleReturn` inserted `\n\n` into the island, the flush wrote `"Middle\n\n"`
/// over Middle's range (source grew two bytes), and the reconcile-time
/// `caretDocByte` landed in the INTER-BLOCK GAP — where `BlockListModel.record(at:)`
/// answers nil and the terminal-block carve-out does not apply. `applyReconciled`
/// fell through to `teardownIsland()`: **nothing appeared to happen, focus was
/// lost, and the file had silently grown two bytes.**
///
/// ## The fix: a transient VIRTUAL LINE, written only when it earns bytes
///
/// Markdown has no empty-paragraph node, so a new empty paragraph between two
/// existing blocks cannot be represented in the source or the AST until it has
/// content. The controller therefore does NOT write anything at Return time. It
/// puts the island into a **virtual-line** state: the island's text view shows
/// `hostSlice + "\n\n"` — the host block's real bytes plus a byte-less trailing
/// blank line — with the caret on that line, while the island's `byteRange`,
/// `anchoredSource` and flush baseline all still describe the host block ALONE.
///
///  • Abandon it (blur / click away / Escape) → the flush's effective text is the
///    host slice, which the document already holds → the unchanged-text
///    short-circuit fires → **no edit, no undo entry, no autosave, zero bytes
///    written.**
///  • Type into it → the virtual tail materializes: the flush replaces the HOST
///    BLOCK's range with `hostSlice + "\n\n" + typed`, which re-emits the
///    still-untouched inter-block separator after it. ONE edit, ONE undo step,
///    and the reconcile-time caret lands in the freshly parsed block, where the
///    existing Task-4 re-home path picks it up.
///
/// Every counter/geometry assertion here is paired with an "it actually happened"
/// assertion (the emitted `SourceEdit`s, the live island string, the caret, the
/// measured row growth), so an implementation that simply stopped flushing — or a
/// geometry that is zero for free — would not pass.
@MainActor
final class IslandInteriorReturnTests: AppKitWindowTestCase {

    /// Controllers are referenced weakly by the recycler; keep them alive.
    private var retained: [IslandController] = []

    override func tearDown() {
        retained.removeAll()
        super.tearDown()
    }

    // MARK: - Stack

    private func makeStack(_ md: String)
        -> (recycler: BlockRecyclerView, document: QuoinDocument, controller: IslandController)
    {
        let doc = MarkdownConverter.parse(md)
        let recycler = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = makeTestWindow(width: 640, height: 480)
        window.contentView = recycler
        recycler.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        recycler.setDocument(doc, contentWidth: 600)
        recycler.layoutSubtreeIfNeeded()
        let controller = IslandController(recycler: recycler)
        retained.append(controller)
        return (recycler, doc, controller)
    }

    /// The Task-4 stub session: applies each `SourceEdit` through the REAL
    /// incremental parse, records the fire, and hands the new document plus the
    /// flush-time `caretDocByte` back — exactly what the app's wiring does.
    private final class StubSession {
        var doc: QuoinDocument
        var rev = 0
        var fires: [(range: ByteRange, text: String, caret: Int)] = []
        init(_ d: QuoinDocument) { doc = d }
    }

    @discardableResult
    private func installStub(_ controller: IslandController,
                             startingFrom doc: QuoinDocument) -> StubSession {
        let box = StubSession(doc)
        controller.onReconcile = { [weak controller] range, newText, caret in
            box.fires.append((range, newText, caret))
            let edit = SourceEdit(range: range, replacement: newText)
            let result = try! MarkdownConverter.parseAfterEdit(previous: box.doc, edit: edit)
            box.doc = result.document
            box.rev += 1
            let caretDocByte = IslandCaretMapping.documentByte(
                localUTF16: caret, islandSource: newText, islandByteStart: range.offset)
            controller?.applyReconciled(result.document, caretDocByte: caretDocByte)
        }
        return box
    }

    private func slice(_ doc: QuoinDocument, _ range: Range<Int>) -> String? {
        doc.source.substring(in: ByteRange(range))
    }

    /// Which of the app's two independently-scheduled main-actor jobs wins.
    ///
    /// In the app the reconcile continuation (`applyReconciled`) and SwiftUI's
    /// projection refresh (`updateDocumentPreservingEditing`) are separate jobs —
    /// `ReaderModel.reconcileIsland` publishes the new document from inside the
    /// edit pipeline task, and the controller's `applyReconciled` runs when the
    /// awaiting `Task` resumes. Neither order is guaranteed, so BOTH have to be
    /// correct.
    enum RefreshOrder { case applyThenRefresh, refreshThenApply }

    /// The app's wiring, headless and complete: apply the edit through the real
    /// incremental parse, then drive BOTH seams the app drives — the controller's
    /// re-anchor AND the recycler's projection refresh — in `order`.
    ///
    /// The Task-4 stub (`installStub`) drives only the controller. That is the
    /// hole the materialization row-model defect shipped through: every
    /// controller-state assertion passed while the TABLE was displaying the wrong
    /// blocks.
    @discardableResult
    private func installAppLikeStub(
        _ controller: IslandController, recycler: BlockRecyclerView,
        startingFrom doc: QuoinDocument, order: RefreshOrder
    ) -> StubSession {
        let box = StubSession(doc)
        controller.onReconcile = { [weak controller, weak recycler] range, newText, caret in
            box.fires.append((range, newText, caret))
            let edit = SourceEdit(range: range, replacement: newText)
            let result = try! MarkdownConverter.parseAfterEdit(previous: box.doc, edit: edit)
            box.doc = result.document
            box.rev += 1
            let caretDocByte = IslandCaretMapping.documentByte(
                localUTF16: caret, islandSource: newText, islandByteStart: range.offset)
            // Exactly what `BlockRecyclerReaderView.apply` passes: the island's
            // CURRENT start byte, read at refresh time.
            let refresh = {
                recycler?.updateDocumentPreservingEditing(
                    result.document, contentWidth: 600,
                    islandStartByte: controller?.activeIsland?.byteRange.lowerBound)
            }
            switch order {
            case .applyThenRefresh:
                controller?.applyReconciled(result.document, caretDocByte: caretDocByte)
                refresh()
            case .refreshThenApply:
                refresh()
                controller?.applyReconciled(result.document, caretDocByte: caretDocByte)
            }
        }
        return box
    }

    /// Activate `index`'s block with the caret at the very END of its source.
    private func activateAtEnd(
        _ controller: IslandController, _ recycler: BlockRecyclerView,
        _ doc: QuoinDocument, index: Int
    ) throws -> BlockEditorCell {
        controller.activate(blockID: doc.blocks[index].id, localPoint: .zero,
                            in: doc, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell, "the island's editor cell is live")
        let end = (cell.islandTextView.string as NSString).length
        cell.islandTextView.setSelectedRange(NSRange(location: end, length: 0))
        return cell
    }

    /// Activate `index`'s block with the caret at the end of its last non-empty
    /// LINE. For a list — whose cmark range includes the block's trailing newline —
    /// that is where a click at "the end of the list" actually lands, and it is the
    /// position the Return rules are written for.
    private func activateAtEndOfLastItem(
        _ controller: IslandController, _ recycler: BlockRecyclerView,
        _ doc: QuoinDocument, index: Int
    ) throws -> BlockEditorCell {
        controller.activate(blockID: doc.blocks[index].id, localPoint: .zero,
                            in: doc, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell, "the island's editor cell is live")
        var end = (cell.islandTextView.string as NSString).length
        let ns = cell.islandTextView.string as NSString
        while end > 0, ns.substring(with: NSRange(location: end - 1, length: 1)) == "\n" {
            end -= 1
        }
        cell.islandTextView.setSelectedRange(NSRange(location: end, length: 0))
        return cell
    }

    // MARK: - 1. THE CANONICAL BUG: interior Return, then materialize

    /// `First\n\nMiddle\n\nLast`, caret at the end of `Middle`, Return.
    ///
    /// PRE-FIX: the island was torn down (`activeIsland == nil`, no editing row)
    /// and the source had grown to `First\n\nMiddle\n\n\n\nLast`.
    func testInteriorReturnKeepsTheIslandOnAVirtualLineThenMaterializesOnTyping() throws {
        let (v, doc, controller) = makeStack("First\n\nMiddle\n\nLast")
        let stub = installStub(controller, startingFrom: doc)
        let cell = try activateAtEnd(controller, v, doc, index: 1)
        XCTAssertEqual(cell.islandTextView.string, "Middle", "precondition: the island opened on Middle")

        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev })
        harness.pressReturn()
        controller.flushPendingReconcile()

        // (a) NOT A BYTE WAS WRITTEN. The Return alone is not an edit.
        XCTAssertEqual(stub.fires.count, 0,
                       "an interior Return writes NOTHING until the new line earns content; got \(stub.fires)")
        XCTAssertEqual(stub.doc.source, "First\n\nMiddle\n\nLast",
                       "the document is byte-identical after the Return")

        // (b) THE ISLAND SURVIVED, on a new empty editable line below Middle.
        XCTAssertNotNil(controller.activeIsland,
                        "interior Return keeps the island alive (pre-fix it tore down)")
        XCTAssertTrue(controller.hasVirtualLineForTest,
                      "the island hosts a transient virtual line")
        XCTAssertEqual(controller.virtualLineEnteredCountForTest, 1,
                       "…opened exactly once by this Return")
        XCTAssertEqual(controller.virtualLineMaterializedCountForTest, 0,
                       "…and not yet materialized")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "Middle\n\n",
                       "the island shows the host block plus the byte-less blank line")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 8,
                       "the caret sits ON the new empty line")
        XCTAssertEqual(controller.activeIsland?.byteRange, 7..<13,
                       "the island is still anchored to Middle's real bytes ONLY")

        // (c) TYPE — the virtual line materializes into a real block.
        let live = try XCTUnwrap(v.currentEditorCell)
        live.islandTextView.insertText("X", replacementRange: NSRange(location: 8, length: 0))
        live.islandTextView.setSelectedRange(NSRange(location: 9, length: 0))
        controller.flushPendingReconcile()

        XCTAssertEqual(stub.fires.count, 1,
                       "exactly ONE edit for the whole new-paragraph-with-content op; got \(stub.fires)")
        XCTAssertEqual(stub.fires.first?.range, ByteRange(offset: 7, length: 6),
                       "the edit replaces the HOST BLOCK's range — the separator after it is untouched")
        XCTAssertEqual(stub.fires.first?.text, "Middle\n\nX")

        let newDoc = stub.doc
        XCTAssertEqual(newDoc.source, "First\n\nMiddle\n\nX\n\nLast",
                       "the exact expected bytes: one new paragraph between Middle and Last")
        XCTAssertEqual(newDoc.blocks.count, 4, "four blocks: First, Middle, X, Last")
        XCTAssertEqual(slice(newDoc, 7..<13), "Middle")
        XCTAssertEqual(newDoc.blocks.map { newDoc.source.substring(in: $0.range) },
                       ["First", "Middle", "X", "Last"])

        // (d) The island RE-HOMED onto the new block, caret after the X.
        XCTAssertNotNil(controller.activeIsland, "the island is still alive after materializing")
        XCTAssertFalse(controller.hasVirtualLineForTest,
                       "the virtual line is gone — it is a real block now")
        XCTAssertEqual(controller.virtualLineMaterializedCountForTest, 1,
                       "…because the keystroke MATERIALIZED it (not because it was dropped)")
        let island = try XCTUnwrap(controller.activeIsland)
        XCTAssertEqual(slice(newDoc, island.byteRange), "X",
                       "the island re-homed onto the NEW block")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "X")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 1,
                       "caret after the typed X, in the new block")
        XCTAssertFalse(controller.hasOrphanedEditorCell)
    }

    // MARK: - 2. ABANDONED EMPTY RETURN — byte-losslessness

    /// The Return the user did not type into must leave NO TRACE: same bytes, no
    /// undo entry, no autosave. Driven through a REAL `DocumentSession`.
    func testAbandonedInteriorReturnLeavesTheDocumentByteIdentical() async throws {
        let original = "First\n\nMiddle\n\nLast"
        let session = DocumentSession(source: original)
        let doc = await session.document
        let (v, _, controller) = makeStack(original)

        // Wire the island to the REAL session, so an edit would produce a real
        // undo entry and a real autosave schedule.
        var fires = 0
        controller.onReconcile = { range, text, _ in
            fires += 1
            Task { try? await session.applyEdit(SourceEdit(range: range, replacement: text)) }
        }

        let cell = try activateAtEnd(controller, v, doc, index: 1)
        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { 0 })
        harness.pressReturn()

        // Precondition (anti-vacuity): the Return DID do something observable.
        XCTAssertTrue(controller.hasVirtualLineForTest, "the Return opened a virtual line")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "Middle\n\n")

        // Click away WITHOUT typing.
        controller.deactivate()

        XCTAssertNil(controller.activeIsland, "the island is gone")
        XCTAssertFalse(controller.hasVirtualLineForTest, "the virtual line is gone with it")
        XCTAssertFalse(controller.hasOrphanedEditorCell, "no orphaned editable cell left behind")
        XCTAssertEqual(fires, 0, "the abandoned virtual line fired NO reconcile")

        // Let any (wrongly) scheduled apply land before reading the session.
        await Task.yield()
        let after = await session.document
        let canUndo = await session.canUndo
        XCTAssertEqual(after.source, original,
                       "the document is BYTE-IDENTICAL to before the Return")
        XCTAssertEqual(after.sourceHash, doc.sourceHash, "…including its content hash")
        XCTAssertFalse(canUndo,
                       "no undo entry was recorded (and therefore no autosave was scheduled — "
                       + "`scheduleAutosave` is only reachable from `applyEdit`/undo/redo)")
    }

    // MARK: - 3. Return at the end of a HEADING that has body text below it

    /// The exact bug from the project's history: "Return at the end of a heading
    /// that has body text below it lands the caret on the wrong line and typing
    /// appends to the heading."
    func testReturnAtEndOfHeadingWithBodyBelowTypesIntoTheNewBlockNotTheHeading() throws {
        let (v, doc, controller) = makeStack("# Title\n\nBody.")
        let stub = installStub(controller, startingFrom: doc)
        let cell = try activateAtEnd(controller, v, doc, index: 0)
        XCTAssertEqual(cell.islandTextView.string, "# Title", "precondition: the heading's raw source")

        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev })
        harness.pressReturn()
        controller.flushPendingReconcile()

        XCTAssertNotNil(controller.activeIsland, "the island survives Return at the end of a heading")
        XCTAssertEqual(stub.doc.source, "# Title\n\nBody.", "no bytes written yet")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "# Title\n\n")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 9)

        let live = try XCTUnwrap(v.currentEditorCell)
        live.islandTextView.insertText("X", replacementRange: NSRange(location: 9, length: 0))
        live.islandTextView.setSelectedRange(NSRange(location: 10, length: 0))
        controller.flushPendingReconcile()

        let newDoc = stub.doc
        XCTAssertEqual(newDoc.source, "# Title\n\nX\n\nBody.")
        XCTAssertEqual(newDoc.blocks.count, 3)
        XCTAssertEqual(newDoc.source.substring(in: newDoc.blocks[0].range), "# Title",
                       "the HEADING is untouched — the X did NOT get appended to it")
        if case .heading = newDoc.blocks[0].kind {} else {
            XCTFail("block 0 is still a heading; got \(newDoc.blocks[0].kind)")
        }
        XCTAssertEqual(newDoc.source.substring(in: newDoc.blocks[1].range), "X",
                       "the typing landed in the NEW block")
        if case .paragraph = newDoc.blocks[1].kind {} else {
            XCTFail("the new block is a paragraph; got \(newDoc.blocks[1].kind)")
        }
        let island = try XCTUnwrap(controller.activeIsland)
        XCTAssertEqual(slice(newDoc, island.byteRange), "X", "the island followed the caret")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 1)
    }

    // MARK: - 4. MID-DOCUMENT empty-list-item EXIT

    /// Exiting a list in the MIDDLE of a document lands the caret in the same
    /// inter-block gap the interior Return does, and pre-fix tore the island down
    /// the same way. It gets the same virtual line — with one difference: the
    /// EMPTY ITEM itself is real bytes, so removing it IS an edit, and only the
    /// new blank line is deferred.
    func testMidDocumentEmptyListItemExitOpensAVirtualLineThenMaterializes() throws {
        let (v, doc, controller) = makeStack("Intro\n\n- a\n\nEnd")
        let stub = installStub(controller, startingFrom: doc)
        let cell = try activateAtEndOfLastItem(controller, v, doc, index: 1)
        // cmark's LIST block range INCLUDES the block's trailing newline, so the
        // island's slice is "- a\n" and the end of the last ITEM is offset 3.
        XCTAssertEqual(cell.islandTextView.string, "- a\n", "precondition: the island opened on the list")
        XCTAssertEqual(controller.activeIslandKind.map(ReturnSemantics.mode(for:)), .listAware)

        // Return #1: continue the list with a fresh empty item (real bytes).
        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev })
        harness.pressReturn()
        controller.flushPendingReconcile()
        XCTAssertEqual(stub.doc.source, "Intro\n\n- a\n- \n\nEnd",
                       "precondition: the empty item was really written")

        // Return #2 on the now-empty item: EXIT — the empty item is removed and
        // the caret moves to a new (byte-less) paragraph after the list.
        let cell2 = try XCTUnwrap(v.currentEditorCell)
        let harness2 = EditorTestHarness(adopting: cell2.islandTextView, appliedRevision: { stub.rev })
        harness2.pressReturn()
        controller.flushPendingReconcile()

        XCTAssertNotNil(controller.activeIsland,
                        "a mid-document list exit keeps the island alive (pre-fix it tore down)")
        XCTAssertTrue(controller.hasVirtualLineForTest)
        XCTAssertEqual(stub.doc.source, "Intro\n\n- a\n\nEnd",
                       "the empty item is gone and NOT ONE extra byte was written for the blank line")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "- a\n\n",
                       "the list's own trailing newline plus ONE byte-less blank line")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 5,
                       "the caret is on the new empty line, past the list")

        // Materialize.
        let live = try XCTUnwrap(v.currentEditorCell)
        live.islandTextView.insertText("X", replacementRange: NSRange(location: 5, length: 0))
        live.islandTextView.setSelectedRange(NSRange(location: 6, length: 0))
        controller.flushPendingReconcile()

        let newDoc = stub.doc
        XCTAssertEqual(newDoc.source, "Intro\n\n- a\n\nX\n\nEnd")
        XCTAssertEqual(newDoc.blocks.map { newDoc.source.substring(in: $0.range) },
                       ["Intro", "- a\n", "X", "End"],
                       "four blocks (a list block's range carries its trailing newline)")
        let island = try XCTUnwrap(controller.activeIsland)
        XCTAssertEqual(slice(newDoc, island.byteRange), "X")
        if case .list = newDoc.blocks[1].kind {} else {
            XCTFail("the list survived the exit; got \(newDoc.blocks[1].kind)")
        }
    }

    /// The same exit, ABANDONED: the empty item's removal is written (it was real),
    /// and the blank line leaves no trace.
    func testMidDocumentListExitAbandonedWritesOnlyTheItemRemoval() throws {
        let (v, doc, controller) = makeStack("Intro\n\n- a\n\nEnd")
        let stub = installStub(controller, startingFrom: doc)
        let cell = try activateAtEndOfLastItem(controller, v, doc, index: 1)
        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev })
        harness.pressReturn()
        controller.flushPendingReconcile()
        let cell2 = try XCTUnwrap(v.currentEditorCell)
        EditorTestHarness(adopting: cell2.islandTextView, appliedRevision: { stub.rev }).pressReturn()
        controller.flushPendingReconcile()
        XCTAssertTrue(controller.hasVirtualLineForTest, "precondition: the virtual line is open")

        let firesBefore = stub.fires.count
        controller.deactivate()

        XCTAssertEqual(stub.fires.count, firesBefore,
                       "blurring an empty virtual line fires nothing further")
        XCTAssertEqual(stub.doc.source, "Intro\n\n- a\n\nEnd",
                       "byte-identical to the original document")
        XCTAssertNil(controller.activeIsland)
        XCTAssertFalse(controller.hasOrphanedEditorCell)
    }

    // MARK: - 5. UNDO granularity

    /// "New paragraph with content" is ONE undo step, because it is one edit: the
    /// Return wrote nothing, so the typing carries the whole op.
    ///
    /// Driven the way the app drives it — every reconcile is applied through the
    /// REAL `DocumentSession` and handed back before the next keystroke, exactly as
    /// the 200 ms debounce does. That is what makes this test discriminate: PRE-FIX
    /// the Return's own `"Middle\n\n"` flush landed here as undo step #1 and tore
    /// the island down, so the assertions below failed on the edit count AND on the
    /// missing editor cell.
    func testMaterializedParagraphIsASingleUndoStep() async throws {
        let original = "First\n\nMiddle\n\nLast"
        let session = DocumentSession(source: original)
        let doc = await session.document
        let (v, _, controller) = makeStack(original)

        var pending: [(range: ByteRange, text: String, caret: Int)] = []
        var editsApplied = 0
        controller.onReconcile = { range, text, caret in
            pending.append((range, text, caret))
        }
        /// Fire the debounce and drive every resulting edit through the session,
        /// handing each new document back to the island — the app's own loop.
        func settle() async throws {
            controller.flushPendingReconcile()
            while !pending.isEmpty {
                let fire = pending.removeFirst()
                let newDoc = try await session.applyEdit(
                    SourceEdit(range: fire.range, replacement: fire.text))
                editsApplied += 1
                let caretDocByte = IslandCaretMapping.documentByte(
                    localUTF16: fire.caret, islandSource: fire.text,
                    islandByteStart: fire.range.offset)
                controller.applyReconciled(newDoc, caretDocByte: caretDocByte)
            }
        }

        let cell = try activateAtEnd(controller, v, doc, index: 1)
        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { editsApplied })
            .pressReturn()
        try await settle()

        XCTAssertEqual(editsApplied, 0, "the Return itself is not an edit")
        let midway = await session.canUndo
        XCTAssertFalse(midway, "…so it pushed nothing onto the undo stack")

        let live = try XCTUnwrap(v.currentEditorCell,
                                 "the island is still live after the Return (pre-fix: torn down)")
        live.islandTextView.insertText("X", replacementRange: NSRange(location: 8, length: 0))
        live.islandTextView.setSelectedRange(NSRange(location: 9, length: 0))
        try await settle()

        XCTAssertEqual(editsApplied, 1, "ONE edit for the whole new-paragraph-with-content op")
        let edited = await session.document
        XCTAssertEqual(edited.source, "First\n\nMiddle\n\nX\n\nLast",
                       "precondition: the op landed")
        let canUndoAfterEdit = await session.canUndo
        XCTAssertTrue(canUndoAfterEdit, "…and it is undoable")

        // ⌘Z — ONE step returns the document to exactly the pre-Return bytes.
        let undoResult = try await session.undo()
        let undone = try XCTUnwrap(undoResult, "the undo produced a document")
        XCTAssertEqual(undone.source, original,
                       "a SINGLE undo step reverses the whole new-paragraph-with-content op")
        let canUndoAfterUndo = await session.canUndo
        XCTAssertFalse(canUndoAfterUndo, "…and there is nothing else on the stack (one step, not two)")

        // Deliver the undo the way the app does, and assert the island/document
        // stay CONSISTENT (this is the path the re-seed fix guards).
        v.updateDocumentPreservingEditing(
            undone, contentWidth: 600,
            islandStartByte: controller.activeIsland?.byteRange.lowerBound)
        XCTAssertFalse(controller.hasOrphanedEditorCell, "the ⟺ invariant holds after the undo")
        XCTAssertFalse(controller.hasVirtualLineForTest,
                       "no phantom line survives an external rewrite")
        if let island = controller.activeIsland {
            XCTAssertEqual(undone.source.substring(in: ByteRange(island.byteRange)),
                           v.currentEditorCell?.islandTextView.string,
                           "a surviving island shows exactly the bytes it is anchored to")
        } else {
            XCTAssertNil(v.currentEditorCell, "a torn-down island leaves no editable cell")
        }
        XCTAssertEqual(pending.count, 0, "delivering the undo provoked no stale splice")
        let afterDelivery = await session.document
        XCTAssertEqual(afterDelivery.source, original,
                       "…and the document is still the undone one")
    }

    // MARK: - 7. THE ROW MODEL AFTER MATERIALIZATION (the live-app defect)
    //
    // Reported from the real app on the Task-5b build: click at the end of an
    // interior `## Front matter` heading, Return, type `c`, type `oi`.
    //  • after `c` the island row rendered the NEW block ("c") while still
    //    occupying the HEADING's row — the heading vanished from the screen and a
    //    SECOND "c" appeared in the row below it;
    //  • two keystrokes later the island CLOSED ITSELF (no click, no Escape).
    // The final BYTES were right the whole time, which is why every
    // controller-state test in this suite passed. These tests assert what the
    // TABLE is displaying.

    /// Type one character into the virtual line and assert the table's row model
    /// is intact: one row per block, each row showing its OWN block, the editing
    /// row on the block the caret is in, the island alive and focused.
    private func assertRowModelSurvivesMaterialization(_ order: RefreshOrder) throws {
        let (v, doc, controller) = makeStack("Intro\n\n## Front matter\n\nBody text.")
        let stub = installAppLikeStub(controller, recycler: v, startingFrom: doc, order: order)
        let cell = try activateAtEnd(controller, v, doc, index: 1)
        XCTAssertEqual(v.numberOfRowsForTest, 3, "precondition: three blocks, three rows")

        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev }).pressReturn()
        let live = try XCTUnwrap(v.currentEditorCell, "the island survives the Return")
        let end = (live.islandTextView.string as NSString).length
        live.islandTextView.insertText("c", replacementRange: NSRange(location: end, length: 0))
        live.islandTextView.setSelectedRange(NSRange(location: end + 1, length: 0))
        controller.flushPendingReconcile()

        // ANTI-VACUITY: the mutation really happened — one edit, a new block.
        XCTAssertEqual(stub.fires.count, 1, "the keystroke materialized the line as ONE edit")
        XCTAssertEqual(stub.doc.source, "Intro\n\n## Front matter\n\nc\n\nBody text.")
        XCTAssertEqual(stub.doc.blocks.count, 4, "the document really grew by a block")
        if order == .refreshThenApply {
            XCTAssertEqual(v.parkedRefreshReplayCountForTest, 1,
                           "the structural refresh that raced ahead of the apply was PARKED "
                           + "and replayed once the island had re-anchored")
        }

        // THE ROW MODEL.
        XCTAssertEqual(v.numberOfRowsForTest, stub.doc.blocks.count,
                       "one row per block")
        XCTAssertEqual(v.displayedRowTextsForTest(),
                       ["Intro", "Front matter", "c", "Body text."],
                       "every row shows its OWN block: the heading is still there and the "
                       + "typed character appears exactly once (the defect rendered "
                       + "[\"Intro\", \"c\", \"c\", \"Body text.\"])")
        XCTAssertEqual(v.editingRowForTest, 2, "the editing row is the NEW block's row")
        XCTAssertTrue(v.isEditingRow(2), "…and it is the row vending the editable cell")
        XCTAssertFalse(v.isEditingRow(1), "the heading's row is a read cell again")
        let newBlockID = stub.doc.blocks[2].id
        XCTAssertEqual(v.mappedRowForTest(newBlockID), 2,
                       "the row map points the new block at the row that displays it")

        // The island itself.
        let island = try XCTUnwrap(controller.activeIsland, "the island is still active")
        XCTAssertEqual(slice(stub.doc, island.byteRange), "c")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "c")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 1)
        XCTAssertFalse(controller.hasOrphanedEditorCell)
        XCTAssertTrue(
            v.window?.firstResponder === v.currentEditorCell?.islandTextView,
            "the island still holds first responder")
    }

    func testMaterializationRowModelWhenTheApplyLandsFirst() throws {
        try assertRowModelSurvivesMaterialization(.applyThenRefresh)
    }

    func testMaterializationRowModelWhenTheProjectionRefreshLandsFirst() throws {
        try assertRowModelSurvivesMaterialization(.refreshThenApply)
    }

    /// Step 4 of the report: two more keystrokes after the materialization closed
    /// the island with no user action at all (the projection refresh reloaded the
    /// row the editor cell was physically sitting in, destroying it).
    func testTypingOnAfterMaterializationKeepsTheIslandOpenAndTheRowsCorrect() throws {
        let (v, doc, controller) = makeStack("Intro\n\n## Front matter\n\nBody text.")
        let stub = installAppLikeStub(controller, recycler: v, startingFrom: doc,
                                      order: .refreshThenApply)
        let cell = try activateAtEnd(controller, v, doc, index: 1)
        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev }).pressReturn()

        for character in ["c", "o", "i"] {
            let editor = try XCTUnwrap(
                v.currentEditorCell,
                "the island closed itself while typing \"\(character)\" — no click, no Escape")
            let at = editor.islandTextView.selectedRange().location
            editor.islandTextView.insertText(character,
                                             replacementRange: NSRange(location: at, length: 0))
            editor.islandTextView.setSelectedRange(NSRange(location: at + 1, length: 0))
            controller.flushPendingReconcile()
        }

        XCTAssertEqual(stub.doc.source, "Intro\n\n## Front matter\n\ncoi\n\nBody text.",
                       "the bytes are right (they always were — the defect was in the view)")
        XCTAssertNotNil(controller.activeIsland, "the island is STILL open after three keystrokes")
        XCTAssertEqual(v.displayedRowTextsForTest(),
                       ["Intro", "Front matter", "coi", "Body text."])
        XCTAssertEqual(v.editingRowForTest, 2)
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "coi")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 3)
        XCTAssertTrue(
            v.window?.firstResponder === v.currentEditorCell?.islandTextView,
            "…and it still has the caret")
    }

    /// Step 2 of the report: after the Return the heading's `##` DISAPPEARED from
    /// the island (collapsed to the 0.1pt hidden face), so the heading text jumped
    /// left. The caret had left the heading's LINE but not the heading's BLOCK —
    /// and inside an island those are not the same thing.
    func testTheVirtualLineKeepsTheHeadingsHashMarksVisible() throws {
        let (v, doc, controller) = makeStack("Intro\n\n## Front matter\n\nBody text.")
        installStub(controller, startingFrom: doc)
        let cell = try activateAtEnd(controller, v, doc, index: 1)

        let sizeBefore = try headingMarkPointSize(cell)
        XCTAssertGreaterThan(sizeBefore, 6,
                             "precondition: the marks are faded-VISIBLE while the island is open")

        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { 0 }).pressReturn()

        // ANTI-VACUITY: the Return really opened the line and the island really
        // re-styled (the string it styled is the one with the blank line on it).
        XCTAssertTrue(controller.hasVirtualLineForTest)
        let live = try XCTUnwrap(v.currentEditorCell)
        XCTAssertEqual(live.styledTextForTest.string, "## Front matter\n\n",
                       "the styled string is 1:1 with the island's live source")

        let sizeAfter = try headingMarkPointSize(live)
        XCTAssertEqual(sizeAfter, sizeBefore, accuracy: 0.01,
                       "the `##` must stay faded-visible with the caret on the virtual line "
                       + "(it collapsed to the 0.1pt hidden face — the heading jumped left)")
    }

    /// The point size of the run covering the heading's `##` marker.
    private func headingMarkPointSize(_ cell: BlockEditorCell) throws -> CGFloat {
        let styled = cell.styledTextForTest
        XCTAssertTrue(styled.string.hasPrefix("## "), "the island holds the heading's raw source")
        let font = try XCTUnwrap(styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        return font.pointSize
    }

    // MARK: - 6. VIEWPORT: the interior Return must not move the caret's line

    /// The row that hosts the caret GROWS by the new empty line. Its TOP — the
    /// line the caret was on when Return was pressed — must not move on screen.
    ///
    /// Anti-vacuity: the same measurement proves the row genuinely grew (a
    /// non-zero delta, and the row BELOW moved down by exactly that much), so a
    /// "nothing happened" implementation cannot pass by holding everything still.
    func testInteriorReturnDoesNotMoveTheCaretsLineOnScreen() throws {
        // Enough blocks to scroll, with the island parked MID-viewport (a row at
        // the very top moves for free).
        let paragraphs = (0..<40).map { "Para \($0) body text." }.joined(separator: "\n\n")
        let (v, doc, controller) = makeStack(paragraphs)
        installStub(controller, startingFrom: doc)

        let islandRow = 20
        v.setScrollOriginForTest(v.rowRectForTest(islandRow).minY - 200)
        v.layoutSubtreeIfNeeded()

        let cell = try activateAtEnd(controller, v, doc, index: islandRow)
        v.layoutSubtreeIfNeeded()

        let topBefore = v.rowTopInWindowForTest(islandRow)
        let heightBefore = v.rowHeightForTest(islandRow)
        let belowBefore = v.rowTopInWindowForTest(islandRow + 1)
        let originBefore = v.scrollOriginForTest

        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { 0 }).pressReturn()
        v.layoutSubtreeIfNeeded()

        let topAfter = v.rowTopInWindowForTest(islandRow)
        let heightAfter = v.rowHeightForTest(islandRow)
        let belowAfter = v.rowTopInWindowForTest(islandRow + 1)

        // ANTI-VACUITY: the mutation really happened.
        XCTAssertTrue(controller.hasVirtualLineForTest, "the Return opened the virtual line")
        XCTAssertGreaterThan(heightAfter - heightBefore, 8,
                             "the island row grew by (at least) a line to host the new empty line")

        // THE INVARIANT: the caret's line did not move.
        XCTAssertEqual(topAfter, topBefore, accuracy: 1.0,
                       "the caret's row top must not move on screen")
        XCTAssertEqual(v.scrollOriginForTest.y, originBefore.y, accuracy: 1.0,
                       "…and the document must not scroll under the user")

        // FALSIFIER: the content BELOW did move, by exactly the growth — so the
        // assertion above is not passing because nothing changed at all. (Window
        // coordinates run y-UP while the table is flipped, so "moved down the page"
        // is a DECREASE in window y.)
        XCTAssertEqual(belowBefore - belowAfter, heightAfter - heightBefore, accuracy: 1.0,
                       "the following row moved down the page by exactly the row's growth")
        XCTAssertGreaterThan(belowBefore - belowAfter, 8)
    }

    /// Return → type → Return again → type: each Return opens a fresh virtual line
    /// on the block the previous one materialized into, so paragraphs chain without
    /// a single stray byte in between.
    ///
    /// The middle Return is the interesting one: it arrives while the FIRST virtual
    /// line is materialized-but-unflushed, so it falls through to the native `\n\n`
    /// — which the still-open virtual state then absorbs as the tail and
    /// re-establishes on the new block after the re-home. The document never sees it.
    func testReturnTypeReturnChainsParagraphsWithoutStrayBytes() throws {
        let (v, doc, controller) = makeStack("First\n\nMiddle\n\nLast")
        let stub = installStub(controller, startingFrom: doc)
        let cell = try activateAtEnd(controller, v, doc, index: 1)
        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev }).pressReturn()

        let first = try XCTUnwrap(v.currentEditorCell)
        first.islandTextView.insertText("X", replacementRange: NSRange(location: 8, length: 0))
        first.islandTextView.setSelectedRange(NSRange(location: 9, length: 0))
        controller.flushPendingReconcile()
        XCTAssertEqual(stub.doc.source, "First\n\nMiddle\n\nX\n\nLast")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "X",
                       "precondition: the island re-homed onto the new block")

        // Return again, on the block that was just created.
        let second = try XCTUnwrap(v.currentEditorCell)
        EditorTestHarness(adopting: second.islandTextView, appliedRevision: { stub.rev }).pressReturn()
        controller.flushPendingReconcile()
        XCTAssertTrue(controller.hasVirtualLineForTest, "a fresh virtual line, on the X block")
        XCTAssertEqual(stub.doc.source, "First\n\nMiddle\n\nX\n\nLast",
                       "the second Return wrote nothing either")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "X\n\n")

        let third = try XCTUnwrap(v.currentEditorCell)
        third.islandTextView.insertText("Y", replacementRange: NSRange(location: 3, length: 0))
        third.islandTextView.setSelectedRange(NSRange(location: 4, length: 0))
        controller.flushPendingReconcile()

        XCTAssertEqual(stub.doc.source, "First\n\nMiddle\n\nX\n\nY\n\nLast",
                       "two Returns, two typed paragraphs, zero stray bytes")
        XCTAssertEqual(stub.doc.blocks.count, 5)
        let island = try XCTUnwrap(controller.activeIsland)
        XCTAssertEqual(slice(stub.doc, island.byteRange), "Y")
    }

    // MARK: - Guards on the transient state itself

    /// Return AGAIN on an empty virtual line is a consumed no-op: two adjacent
    /// empty paragraphs are not representable either, and inserting `\n\n` here
    /// would push the caret into a gap `record(at:)` cannot resolve.
    func testSecondReturnOnAnEmptyVirtualLineIsANoOp() throws {
        let (v, doc, controller) = makeStack("First\n\nMiddle\n\nLast")
        let stub = installStub(controller, startingFrom: doc)
        let cell = try activateAtEnd(controller, v, doc, index: 1)
        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev })
        harness.pressReturn()
        let textAfterFirst = v.currentEditorCell?.islandTextView.string
        let caretAfterFirst = v.currentEditorCell?.islandTextView.selectedRange().location

        EditorTestHarness(adopting: try XCTUnwrap(v.currentEditorCell).islandTextView,
                          appliedRevision: { stub.rev }).pressReturn()
        controller.flushPendingReconcile()

        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, textAfterFirst,
                       "a second Return on the empty line changes nothing")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, caretAfterFirst)
        XCTAssertEqual(stub.fires.count, 0, "and writes nothing")
        XCTAssertTrue(controller.hasVirtualLineForTest, "the island is still on the virtual line")
        XCTAssertEqual(stub.doc.source, "First\n\nMiddle\n\nLast")
    }

    /// Backspace on an empty virtual line COLLAPSES it (undoes the Return) rather
    /// than eating the real separator underneath — which would merge two blocks
    /// the user never touched.
    func testBackspaceOnAnEmptyVirtualLineCollapsesItWithoutWriting() throws {
        let (v, doc, controller) = makeStack("First\n\nMiddle\n\nLast")
        let stub = installStub(controller, startingFrom: doc)
        let cell = try activateAtEnd(controller, v, doc, index: 1)
        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev })
        harness.pressReturn()
        XCTAssertTrue(controller.hasVirtualLineForTest, "precondition")

        EditorTestHarness(adopting: try XCTUnwrap(v.currentEditorCell).islandTextView,
                          appliedRevision: { stub.rev }).pressBackspace()
        controller.flushPendingReconcile()

        XCTAssertFalse(controller.hasVirtualLineForTest, "the virtual line collapsed")
        XCTAssertNotNil(controller.activeIsland, "the island is still open on Middle")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "Middle",
                       "back to the host block's exact bytes")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 6,
                       "caret back at the end of Middle")
        XCTAssertEqual(stub.fires.count, 0, "nothing was written at any point")
        XCTAssertEqual(stub.doc.source, "First\n\nMiddle\n\nLast")
    }

    /// A Return in the MIDDLE of an interior paragraph is a REAL split, not a
    /// virtual line — both halves have content, so both are representable.
    /// (Regression guard for the new branch's entry condition.)
    func testInteriorReturnMidParagraphStillSplitsForReal() throws {
        let (v, doc, controller) = makeStack("First\n\nMiddle\n\nLast")
        let stub = installStub(controller, startingFrom: doc)
        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = try XCTUnwrap(v.currentEditorCell)
        cell.islandTextView.setSelectedRange(NSRange(location: 3, length: 0))  // "Mid|dle"
        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev }).pressReturn()
        controller.flushPendingReconcile()

        XCTAssertFalse(controller.hasVirtualLineForTest, "a real split, not a virtual line")
        XCTAssertEqual(stub.doc.source, "First\n\nMid\n\ndle\n\nLast")
        XCTAssertEqual(stub.doc.blocks.count, 4)
        let island = try XCTUnwrap(controller.activeIsland)
        XCTAssertEqual(slice(stub.doc, island.byteRange), "dle",
                       "the island followed the caret into the second half")
    }
}
#endif
