#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 3 — **RETURN UNIFICATION**: every Return whose new paragraph would be
/// EMPTY now takes the ONE mechanism Task 5b built for the interior case (a
/// transient, byte-less virtual line that materializes on the first keystroke),
/// wherever it happens and whatever it replaces.
///
/// Three gaps closed here, all of them the same gap:
///
///  • **R1 — TERMINAL.** Task 5's own branch handled Return at the end of the
///    LAST block by WRITING `"\n\n"` and keeping the island alive on the extended
///    last block. Correct final bytes, but the file grew by two bytes the instant
///    Return was pressed: press Return at the end of the document, click away
///    without typing, and the file is two bytes bigger with nothing to show for
///    it. The terminal branch in `applyReconciled` is now DELETED and terminal
///    behaves exactly like interior.
///  • **R2 — BLOCK START, and RETURN OVER A SELECTION.** Both still wrote `\n\n`
///    ("harmless, not byte-lossless, untested"). Return at a block's START now
///    opens the empty paragraph ABOVE — byte-lessly, with the caret staying in the
///    original block as it is pushed down — and a Return that replaces a selection
///    deletes the selection first and then applies the same rules to the caret's
///    resulting position, as ONE edit and ONE undo step.
///  • **R3 — THE ASYNC WINDOW.** In the app `onReconcile` is a `Task`, so a
///    keystroke can land between a virtual-line flush and its apply. That used to
///    DROP the virtual state, which was not merely a lost blank line: the affix
///    newlines were still on screen, so the next flush wrote them as REAL bytes.
///    The interleaving is now driven explicitly, through a DEFERRED-apply stub,
///    and both the blank line and the typing survive.
///
/// Conventions: `AppKitWindowTestCase` (offscreen `(-20000,-20000)` `.prohibited`
/// windows, mouse-event drain in tearDown), the real incremental parse for every
/// edit, and a real `DocumentSession` wherever undo/autosave is the subject.
@MainActor
final class IslandReturnUnificationTests: AppKitWindowTestCase {

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

    private final class StubSession {
        var doc: QuoinDocument
        var rev = 0
        var fires: [(range: ByteRange, text: String, caret: Int)] = []
        init(_ d: QuoinDocument) { doc = d }
    }

    /// Synchronous stub: applies each `SourceEdit` through the REAL incremental
    /// parse and hands the new document + flush-time `caretDocByte` straight back.
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

    /// DEFERRED stub — the app's real shape. The edit is applied to the document
    /// immediately (that is what `DocumentSession` does), but the `applyReconciled`
    /// handoff is QUEUED, so a test can land keystrokes in the window between the
    /// two exactly as the app's `Task` does.
    private final class DeferredStub {
        var doc: QuoinDocument
        var rev = 0
        var fires: [(range: ByteRange, text: String, caret: Int)] = []
        var pendingApplies: [(document: QuoinDocument, caretDocByte: Int?)] = []
        init(_ d: QuoinDocument) { doc = d }
    }

    private func installDeferredStub(_ controller: IslandController,
                                     startingFrom doc: QuoinDocument) -> DeferredStub {
        let box = DeferredStub(doc)
        controller.onReconcile = { range, newText, caret in
            box.fires.append((range, newText, caret))
            let edit = SourceEdit(range: range, replacement: newText)
            let result = try! MarkdownConverter.parseAfterEdit(previous: box.doc, edit: edit)
            box.doc = result.document
            box.rev += 1
            let caretDocByte = IslandCaretMapping.documentByte(
                localUTF16: caret, islandSource: newText, islandByteStart: range.offset)
            box.pendingApplies.append((result.document, caretDocByte))
        }
        return box
    }

    private func deliverNextApply(_ box: DeferredStub, to controller: IslandController) {
        guard !box.pendingApplies.isEmpty else { return XCTFail("no apply was pending") }
        let next = box.pendingApplies.removeFirst()
        controller.applyReconciled(next.document, caretDocByte: next.caretDocByte)
    }

    private func slice(_ doc: QuoinDocument, _ range: Range<Int>) -> String? {
        doc.source.substring(in: ByteRange(range))
    }

    @discardableResult
    private func activate(_ controller: IslandController, _ recycler: BlockRecyclerView,
                          _ doc: QuoinDocument, index: Int, caret: CaretSeat) throws
        -> BlockEditorCell
    {
        controller.activate(blockID: doc.blocks[index].id, localPoint: .zero,
                            in: doc, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell, "the island's editor cell is live")
        let length = (cell.islandTextView.string as NSString).length
        switch caret {
        case .start:
            cell.islandTextView.setSelectedRange(NSRange(location: 0, length: 0))
        case .end:
            cell.islandTextView.setSelectedRange(NSRange(location: length, length: 0))
        case .endOfLastNonEmptyLine:
            var end = length
            let ns = cell.islandTextView.string as NSString
            while end > 0, ns.substring(with: NSRange(location: end - 1, length: 1)) == "\n" {
                end -= 1
            }
            cell.islandTextView.setSelectedRange(NSRange(location: end, length: 0))
        case .range(let range):
            cell.islandTextView.setSelectedRange(range)
        }
        return cell
    }

    enum CaretSeat { case start, end, endOfLastNonEmptyLine, range(NSRange) }

    private func type(_ text: String, into recycler: BlockRecyclerView,
                      _ controller: IslandController, at location: Int) throws {
        let cell = try XCTUnwrap(recycler.currentEditorCell, "the island is live")
        cell.islandTextView.insertText(text, replacementRange: NSRange(location: location, length: 0))
        cell.islandTextView.setSelectedRange(
            NSRange(location: location + (text as NSString).length, length: 0))
        controller.flushPendingReconcile()
    }

    // MARK: - R1. TERMINAL Return: abandoned leaves NOT ONE byte behind

    /// Return at the end of the document's LAST paragraph, then click away without
    /// typing. Driven through a REAL `DocumentSession`, so an edit would produce a
    /// real undo entry and a real autosave schedule.
    ///
    /// PRE-FIX: the Return flushed `"Hello"` → `"Hello\n\n"`, so the file grew two
    /// bytes and the undo stack grew an entry for a paragraph that was never typed.
    func testAbandonedTerminalReturnLeavesTheDocumentByteIdentical() async throws {
        let original = "First\n\nHello"
        let session = DocumentSession(source: original)
        let doc = await session.document
        let (v, _, controller) = makeStack(original)

        var fires = 0
        controller.onReconcile = { range, text, _ in
            fires += 1
            Task { try? await session.applyEdit(SourceEdit(range: range, replacement: text)) }
        }

        let cell = try activate(controller, v, doc, index: 1, caret: .end)
        XCTAssertEqual(cell.islandTextView.string, "Hello", "precondition: the LAST block")
        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { 0 }).pressReturn()

        // Precondition (anti-vacuity): the Return DID do something observable.
        XCTAssertTrue(controller.hasVirtualLineForTest, "the Return opened a virtual line")
        XCTAssertEqual(controller.virtualLineEnteredCountForTest, 1)
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "Hello\n\n")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 7)

        controller.deactivate()

        XCTAssertNil(controller.activeIsland, "the island is gone")
        XCTAssertFalse(controller.hasVirtualLineForTest, "the virtual line is gone with it")
        XCTAssertFalse(controller.hasOrphanedEditorCell)
        XCTAssertEqual(fires, 0, "the abandoned terminal Return fired NO reconcile")

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

    /// Terminal Return → type: exact bytes, two blocks, island re-homed, caret right.
    func testTerminalReturnThenTypingWritesExactlyOneNewBlock() throws {
        let (v, doc, controller) = makeStack("First\n\nHello")
        let stub = installStub(controller, startingFrom: doc)
        let cell = try activate(controller, v, doc, index: 1, caret: .end)
        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev }).pressReturn()
        controller.flushPendingReconcile()

        XCTAssertEqual(stub.fires.count, 0, "the Return alone writes nothing")
        XCTAssertEqual(stub.doc.source, "First\n\nHello")

        try type("X", into: v, controller, at: 7)

        XCTAssertEqual(stub.fires.count, 1, "ONE edit for the whole op")
        XCTAssertEqual(stub.fires.first?.range, ByteRange(offset: 7, length: 5),
                       "the edit replaces the HOST BLOCK's range only")
        XCTAssertEqual(stub.fires.first?.text, "Hello\n\nX")
        XCTAssertEqual(stub.doc.source, "First\n\nHello\n\nX")
        XCTAssertEqual(stub.doc.blocks.map { stub.doc.source.substring(in: $0.range) },
                       ["First", "Hello", "X"])
        XCTAssertFalse(controller.hasVirtualLineForTest)
        XCTAssertEqual(controller.virtualLineMaterializedCountForTest, 1,
                       "the line MATERIALIZED (it was not dropped)")
        let island = try XCTUnwrap(controller.activeIsland)
        XCTAssertEqual(slice(stub.doc, island.byteRange), "X", "the island re-homed onto the new block")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "X")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 1)
        XCTAssertFalse(controller.hasOrphanedEditorCell)
    }

    // MARK: - R1. Terminal and interior are ONE code path

    /// Everything observable about a Return at the end of the LAST block and a
    /// Return at the end of an INTERIOR block is now the SAME — that is what
    /// "unified onto one mechanism" means, and it is the assertion the deleted
    /// terminal branch cannot satisfy (pre-fix the terminal trace fired an edit at
    /// Return time and reported the extended `"Body.\n\n"` slice).
    private struct ReturnTrace: Equatable {
        var firesAfterReturn = 0
        var documentUnchangedAfterReturn = false
        var islandTextAfterReturn = ""
        var caretAfterReturn = 0
        var hasVirtualLine = false
        var virtualLinesEntered = 0
        var firesAfterTyping = 0
        var editOffsetFromIslandStart = -1
        var editLength = -1
        var editText = ""
        var materialized = 0
        var islandSliceAfterTyping = ""
        var islandTextAfterTyping = ""
        var caretAfterTyping = 0
    }

    private func traceEndOfBlockReturn(_ markdown: String, blockIndex: Int) throws -> ReturnTrace {
        let (v, doc, controller) = makeStack(markdown)
        let stub = installStub(controller, startingFrom: doc)
        let islandStart = doc.blocks[blockIndex].range.offset
        let cell = try activate(controller, v, doc, index: blockIndex, caret: .end)
        let before = stub.doc.source
        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev }).pressReturn()
        controller.flushPendingReconcile()

        var trace = ReturnTrace()
        trace.firesAfterReturn = stub.fires.count
        trace.documentUnchangedAfterReturn = stub.doc.source == before
        trace.islandTextAfterReturn = v.currentEditorCell?.islandTextView.string ?? "<no island>"
        trace.caretAfterReturn = v.currentEditorCell?.islandTextView.selectedRange().location ?? -1
        trace.hasVirtualLine = controller.hasVirtualLineForTest
        trace.virtualLinesEntered = controller.virtualLineEnteredCountForTest

        let caret = v.currentEditorCell?.islandTextView.selectedRange().location ?? 0
        try type("X", into: v, controller, at: caret)

        trace.firesAfterTyping = stub.fires.count
        if let fire = stub.fires.last {
            trace.editOffsetFromIslandStart = fire.range.offset - islandStart
            trace.editLength = fire.range.length
            trace.editText = fire.text
        }
        trace.materialized = controller.virtualLineMaterializedCountForTest
        trace.islandSliceAfterTyping = controller.activeIsland
            .flatMap { slice(stub.doc, $0.byteRange) } ?? "<no island>"
        trace.islandTextAfterTyping = v.currentEditorCell?.islandTextView.string ?? "<no island>"
        trace.caretAfterTyping = v.currentEditorCell?.islandTextView.selectedRange().location ?? -1
        return trace
    }

    func testTerminalAndInteriorEndOfBlockReturnAreObservablyIdentical() throws {
        let terminal = try traceEndOfBlockReturn("Intro\n\nBody.", blockIndex: 1)
        let interior = try traceEndOfBlockReturn("Intro\n\nBody.\n\nAfter", blockIndex: 1)

        // ANTI-VACUITY: the trace is not a row of defaults — the interaction
        // genuinely happened on BOTH runs.
        XCTAssertTrue(interior.hasVirtualLine, "the Return really opened a line")
        XCTAssertTrue(interior.documentUnchangedAfterReturn)
        XCTAssertEqual(interior.virtualLinesEntered, 1)
        XCTAssertEqual(interior.materialized, 1)
        XCTAssertEqual(interior.firesAfterReturn, 0)
        XCTAssertEqual(interior.firesAfterTyping, 1)
        XCTAssertEqual(interior.islandTextAfterReturn, "Body.\n\n")
        XCTAssertEqual(interior.editText, "Body.\n\nX")
        XCTAssertEqual(interior.islandSliceAfterTyping, "X")

        XCTAssertEqual(terminal, interior,
                       "terminal and interior end-of-block Return must be the SAME code path: "
                       + "same edits, same island text, same caret, same materialization")
    }

    // MARK: - R2. Return at a block's START

    /// The block is pushed DOWN and the caret goes with it; the empty paragraph
    /// above exists only in the island until something is typed into it.
    func testBlockStartReturnPushesTheBlockDownWithoutWriting() throws {
        let (v, doc, controller) = makeStack("First\n\nMiddle\n\nLast")
        let stub = installStub(controller, startingFrom: doc)
        let cell = try activate(controller, v, doc, index: 1, caret: .start)
        XCTAssertEqual(cell.islandTextView.string, "Middle")

        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev }).pressReturn()
        controller.flushPendingReconcile()

        XCTAssertEqual(stub.fires.count, 0, "Return at a block's START writes nothing either")
        XCTAssertEqual(stub.doc.source, "First\n\nMiddle\n\nLast")
        XCTAssertTrue(controller.hasVirtualLineForTest)
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "\n\nMiddle",
                       "the byte-less blank line sits ABOVE the block")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 2,
                       "the caret stays with the BLOCK, which has been pushed down")
        XCTAssertEqual(controller.activeIsland?.byteRange, 7..<13,
                       "the island is still anchored to Middle's real bytes ONLY")

        // Typing at the caret continues in the ORIGINAL block; the blank line above
        // is still byte-less.
        try type("X", into: v, controller, at: 2)
        XCTAssertEqual(stub.fires.count, 1)
        XCTAssertEqual(stub.fires.first?.text, "XMiddle",
                       "the empty paragraph above contributed NOT ONE byte")
        XCTAssertEqual(stub.doc.source, "First\n\nXMiddle\n\nLast")
        XCTAssertTrue(controller.hasVirtualLineForTest, "…and it is still open above the block")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "\n\nXMiddle")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 3)
    }

    /// Abandoning it leaves NO trace — the same rule the interior and terminal
    /// Returns obey. Real `DocumentSession`: no bytes, no undo entry, no autosave.
    func testAbandonedBlockStartReturnLeavesTheDocumentByteIdentical() async throws {
        let original = "First\n\nMiddle\n\nLast"
        let session = DocumentSession(source: original)
        let doc = await session.document
        let (v, _, controller) = makeStack(original)

        var fires = 0
        controller.onReconcile = { range, text, _ in
            fires += 1
            Task { try? await session.applyEdit(SourceEdit(range: range, replacement: text)) }
        }

        let cell = try activate(controller, v, doc, index: 1, caret: .start)
        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { 0 }).pressReturn()
        XCTAssertTrue(controller.hasVirtualLineForTest, "the Return opened a line ABOVE")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "\n\nMiddle")

        controller.deactivate()

        XCTAssertEqual(fires, 0, "the abandoned line above fired NO reconcile")
        XCTAssertNil(controller.activeIsland)
        XCTAssertFalse(controller.hasOrphanedEditorCell)
        await Task.yield()
        let after = await session.document
        let canUndo = await session.canUndo
        XCTAssertEqual(after.source, original, "byte-identical")
        XCTAssertEqual(after.sourceHash, doc.sourceHash)
        XCTAssertFalse(canUndo, "no undo entry, therefore no autosave")
    }

    /// Going UP onto the blank line and typing materializes it as a real paragraph
    /// ABOVE the block, with the block itself untouched.
    func testTypingOnTheLineAboveMaterializesItAsANewBlock() throws {
        let (v, doc, controller) = makeStack("First\n\nMiddle\n\nLast")
        let stub = installStub(controller, startingFrom: doc)
        let cell = try activate(controller, v, doc, index: 1, caret: .start)
        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev }).pressReturn()

        try type("X", into: v, controller, at: 0)   // arrow up onto the blank line, type

        XCTAssertEqual(stub.fires.count, 1)
        XCTAssertEqual(stub.fires.first?.range, ByteRange(offset: 7, length: 6),
                       "the edit replaces Middle's range; the separators around it are untouched")
        XCTAssertEqual(stub.fires.first?.text, "X\n\nMiddle")
        XCTAssertEqual(stub.doc.source, "First\n\nX\n\nMiddle\n\nLast")
        XCTAssertEqual(stub.doc.blocks.map { stub.doc.source.substring(in: $0.range) },
                       ["First", "X", "Middle", "Last"])
        XCTAssertEqual(controller.virtualLineMaterializedCountForTest, 1)
        let island = try XCTUnwrap(controller.activeIsland)
        XCTAssertEqual(slice(stub.doc, island.byteRange), "X",
                       "the island followed the caret into the NEW block above")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "X")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 1)
    }

    /// Backspace at the start of the block closes the line above — the exact
    /// inverse of the Return — instead of MERGING the block into its predecessor
    /// (which is what a caret at island-local 0 means when no line is open).
    func testBackspaceClosesTheLineAboveInsteadOfMerging() throws {
        let (v, doc, controller) = makeStack("First\n\nMiddle\n\nLast")
        let stub = installStub(controller, startingFrom: doc)
        let cell = try activate(controller, v, doc, index: 1, caret: .start)
        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev }).pressReturn()
        XCTAssertTrue(controller.hasVirtualLineForTest, "precondition")

        EditorTestHarness(adopting: try XCTUnwrap(v.currentEditorCell).islandTextView,
                          appliedRevision: { stub.rev }).pressBackspace()
        controller.flushPendingReconcile()

        XCTAssertFalse(controller.hasVirtualLineForTest, "the line above collapsed")
        XCTAssertNotNil(controller.activeIsland, "the island is still open on Middle")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "Middle")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 0)
        XCTAssertEqual(stub.fires.count, 0, "nothing was written at any point")
        XCTAssertEqual(stub.doc.source, "First\n\nMiddle\n\nLast",
                       "and First and Middle were NOT merged")
        XCTAssertEqual(stub.doc.blocks.count, 3)
    }

    // MARK: - R2. Return over a SELECTION

    /// Selection + Return = replace the selection, then apply the normal Return
    /// semantics at the resulting caret. The deletion is real bytes so it IS
    /// written — once — and the empty paragraph it leaves the caret on is not.
    func testSelectionReplacingReturnIsOneEditAndOneUndoStep() async throws {
        let original = "First\n\nMiddle\n\nLast"
        let session = DocumentSession(source: original)
        let doc = await session.document
        let (v, _, controller) = makeStack(original)

        var pending: [(range: ByteRange, text: String, caret: Int)] = []
        var editsApplied = 0
        controller.onReconcile = { range, text, caret in pending.append((range, text, caret)) }
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

        // Select "dle" (the tail of Middle) and press Return.
        let cell = try activate(controller, v, doc, index: 1,
                                caret: .range(NSRange(location: 3, length: 3)))
        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { editsApplied })
            .pressReturn()

        // The selection is gone from the island and the caret sits on a new blank
        // line below what is left.
        XCTAssertTrue(controller.hasVirtualLineForTest,
                      "the Return opened a virtual line at the caret the deletion left")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "Mid\n\n")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 5)

        try await settle()
        XCTAssertEqual(editsApplied, 1, "the selection removal is ONE edit")
        let midway = await session.document
        XCTAssertEqual(midway.source, "First\n\nMid\n\nLast",
                       "…and it wrote EXACTLY the deletion — not one byte for the blank line")
        XCTAssertEqual(midway.blocks.count, 3, "no phantom block was created")
        XCTAssertTrue(controller.hasVirtualLineForTest,
                      "the blank line survived the apply, still byte-less")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "Mid\n\n")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 5,
                       "the caret is still on the blank line")

        // Type into it: the new paragraph materializes.
        try type("X", into: v, controller, at: 5)
        try await settle()

        XCTAssertEqual(editsApplied, 2, "one edit for the deletion, one for the new paragraph")
        let edited = await session.document
        XCTAssertEqual(edited.source, "First\n\nMid\n\nX\n\nLast")
        XCTAssertEqual(edited.blocks.map { edited.source.substring(in: $0.range) },
                       ["First", "Mid", "X", "Last"])
        let island = try XCTUnwrap(controller.activeIsland)
        XCTAssertEqual(slice(edited, island.byteRange), "X")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "X")

        // UNDO GRANULARITY: the new-paragraph-with-content op is ONE step, and the
        // step before it is the selection removal — nothing extra for the Return.
        let firstUndoResult = try await session.undo()
        let firstUndo = try XCTUnwrap(firstUndoResult)
        XCTAssertEqual(firstUndo.source, "First\n\nMid\n\nLast",
                       "one step reverses the whole new-paragraph op")
        let secondUndoResult = try await session.undo()
        let secondUndo = try XCTUnwrap(secondUndoResult)
        XCTAssertEqual(secondUndo.source, original, "the step before it is the deletion")
        let canUndo = await session.canUndo
        XCTAssertFalse(canUndo, "two steps for two operations — the Return added none")
    }

    /// A selection whose deletion would leave the caret at the block's START gets
    /// the line ABOVE, same as a bare Return there.
    func testSelectionReplacingReturnAtTheBlockStartOpensTheLineAbove() throws {
        let (v, doc, controller) = makeStack("First\n\nMiddle\n\nLast")
        let stub = installStub(controller, startingFrom: doc)
        let cell = try activate(controller, v, doc, index: 1,
                                caret: .range(NSRange(location: 0, length: 3)))
        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev }).pressReturn()
        controller.flushPendingReconcile()

        XCTAssertTrue(controller.hasVirtualLineForTest)
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "\n\ndle")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 2,
                       "the caret is at the start of what remains, pushed down")
        XCTAssertEqual(stub.fires.count, 1, "ONE edit: the selection removal")
        XCTAssertEqual(stub.fires.first?.text, "dle")
        XCTAssertEqual(stub.doc.source, "First\n\ndle\n\nLast",
                       "no byte was written for the empty paragraph above")
        XCTAssertEqual(stub.doc.blocks.count, 3)
    }

    /// NEGATIVE CONTROL: a selection in the MIDDLE of a block is a REAL split —
    /// both halves have content, so both are representable and nothing is deferred.
    func testSelectionReplacingReturnMidBlockStillSplitsForReal() throws {
        let (v, doc, controller) = makeStack("First\n\nMiddle\n\nLast")
        let stub = installStub(controller, startingFrom: doc)
        let cell = try activate(controller, v, doc, index: 1,
                                caret: .range(NSRange(location: 2, length: 2)))  // "Mi[dd]le"
        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev }).pressReturn()
        controller.flushPendingReconcile()

        XCTAssertFalse(controller.hasVirtualLineForTest, "a real split, not a virtual line")
        XCTAssertEqual(stub.doc.source, "First\n\nMi\n\nle\n\nLast")
        XCTAssertEqual(stub.doc.blocks.count, 4)
        let island = try XCTUnwrap(controller.activeIsland)
        XCTAssertEqual(slice(stub.doc, island.byteRange), "le",
                       "the island followed the caret into the second half")
    }

    /// NEGATIVE CONTROL / documented limit: selecting the WHOLE block and pressing
    /// Return is a block DELETION, not a Return — there is no remaining text to
    /// host a byte-less line — so it stays on the native `\n\n` path. Pinned so the
    /// behaviour is a decision, not an accident.
    func testWholeBlockSelectionReturnStaysOnTheNativePath() throws {
        let (v, doc, controller) = makeStack("First\n\nMiddle\n\nLast")
        let stub = installStub(controller, startingFrom: doc)
        let cell = try activate(controller, v, doc, index: 1,
                                caret: .range(NSRange(location: 0, length: 6)))
        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev }).pressReturn()
        controller.flushPendingReconcile()

        XCTAssertFalse(controller.hasVirtualLineForTest,
                       "no virtual line: there is no block left to host one")
        XCTAssertEqual(stub.doc.source, "First\n\n\n\n\n\nLast",
                       "the block's content is replaced by the break (the blank lines are "
                       + "not representable as a block, so the reparse drops them)")
        XCTAssertEqual(stub.doc.blocks.map { stub.doc.source.substring(in: $0.range) },
                       ["First", "Last"])
    }

    // MARK: - R3. A keystroke landing INSIDE the apply window

    /// The list-exit flush (the empty item's removal is real bytes) with the blank
    /// line open, and a keystroke into the BLOCK's text before the apply lands.
    ///
    /// PRE-FIX: `restoreVirtualTailIfNeeded` dropped the virtual state — and the
    /// affix newlines were still displayed, so the very next flush wrote them as
    /// REAL bytes (`"Intro\n\n- aQ\n\n\nEnd"`).
    func testTypingDuringAnInFlightApplyKeepsTheBlankLineByteLess() throws {
        let (v, doc, controller) = makeStack("Intro\n\n- a\n\nEnd")
        let stub = installDeferredStub(controller, startingFrom: doc)
        let cell = try activate(controller, v, doc, index: 1, caret: .endOfLastNonEmptyLine)

        // Return #1 continues the list (real bytes), delivered normally.
        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev }).pressReturn()
        controller.flushPendingReconcile()
        deliverNextApply(stub, to: controller)
        XCTAssertEqual(stub.doc.source, "Intro\n\n- a\n- \n\nEnd", "precondition")

        // Return #2 exits the list: the item's removal is flushed, the blank line
        // is byte-less — and the apply is HELD.
        EditorTestHarness(adopting: try XCTUnwrap(v.currentEditorCell).islandTextView,
                          appliedRevision: { stub.rev }).pressReturn()
        controller.flushPendingReconcile()
        XCTAssertEqual(stub.pendingApplies.count, 1, "precondition: an apply is in flight")
        XCTAssertTrue(controller.hasVirtualLineForTest)
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "- a\n\n")

        // THE INTERLEAVING: a keystroke into the block's own text lands first.
        let live = try XCTUnwrap(v.currentEditorCell)
        live.islandTextView.insertText("Q", replacementRange: NSRange(location: 3, length: 0))
        live.islandTextView.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertEqual(live.islandTextView.string, "- aQ\n\n", "precondition: typed mid-flight")

        deliverNextApply(stub, to: controller)

        XCTAssertTrue(controller.hasVirtualLineForTest,
                      "the blank line survives the interleaving (it was dropped pre-fix)")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string, "- aQ\n\n",
                       "the typing survives too")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.selectedRange().location, 4,
                       "…and so does the caret the user left it at")

        controller.flushPendingReconcile()
        XCTAssertEqual(stub.pendingApplies.count, 1)
        deliverNextApply(stub, to: controller)
        XCTAssertEqual(stub.doc.source, "Intro\n\n- aQ\n\nEnd",
                       "the blank line contributed NOT ONE byte "
                       + "(pre-fix it wrote \"Intro\\n\\n- aQ\\n\\n\\nEnd\")")
        XCTAssertEqual(stub.doc.blocks.count, 3, "no phantom block")
    }

    /// The same window, but the keystroke lands ON the blank line: it has earned
    /// bytes, so it MATERIALIZES — with the separation top-up computed against the
    /// document the apply just produced.
    ///
    /// PRE-FIX: the virtual state was dropped, so the top-up never ran and the
    /// flush wrote `"- a\n\nZ"` — one newline short of the next block, which cmark
    /// then MERGED into the new paragraph.
    func testTypingOnTheBlankLineDuringAnInFlightApplyMaterializesIt() throws {
        let (v, doc, controller) = makeStack("Intro\n\n- a\n\nEnd")
        let stub = installDeferredStub(controller, startingFrom: doc)
        let cell = try activate(controller, v, doc, index: 1, caret: .endOfLastNonEmptyLine)
        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { stub.rev }).pressReturn()
        controller.flushPendingReconcile()
        deliverNextApply(stub, to: controller)
        EditorTestHarness(adopting: try XCTUnwrap(v.currentEditorCell).islandTextView,
                          appliedRevision: { stub.rev }).pressReturn()
        controller.flushPendingReconcile()
        XCTAssertEqual(stub.pendingApplies.count, 1, "precondition: an apply is in flight")

        let live = try XCTUnwrap(v.currentEditorCell)
        live.islandTextView.insertText("Z", replacementRange: NSRange(location: 5, length: 0))
        live.islandTextView.setSelectedRange(NSRange(location: 6, length: 0))

        deliverNextApply(stub, to: controller)

        XCTAssertFalse(controller.hasVirtualLineForTest, "the line is real content now")
        XCTAssertEqual(controller.virtualLineMaterializedCountForTest, 1,
                       "it MATERIALIZED — it was not dropped")

        controller.flushPendingReconcile()
        XCTAssertEqual(stub.pendingApplies.count, 1)
        deliverNextApply(stub, to: controller)

        XCTAssertEqual(stub.doc.source, "Intro\n\n- a\n\nZ\n\nEnd",
                       "the typing AND the blank line both landed, with the separator "
                       + "the next block needs (pre-fix: \"Intro\\n\\n- a\\n\\nZ\\nEnd\", "
                       + "which merges Z and End into one paragraph)")
        XCTAssertEqual(stub.doc.blocks.map { stub.doc.source.substring(in: $0.range) },
                       ["Intro", "- a\n", "Z", "End"])
        let island = try XCTUnwrap(controller.activeIsland)
        XCTAssertEqual(slice(stub.doc, island.byteRange), "Z")
    }
}
#endif
