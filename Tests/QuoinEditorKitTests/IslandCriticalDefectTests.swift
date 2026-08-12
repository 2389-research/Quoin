#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

// MARK: - Shared harness

/// The falsifier gates for the five CRITICAL island defects found by the Phase-3
/// whole-phase review (plus the two IMPORTANTs of the same class). Every one of
/// them shipped green because NO test in the suite exercised the seam:
///
///  • **C1** byte corruption — a flush with an apply already in flight applied the
///    same island text twice (`"Helloabc"` → `"Helloabcabc"`).
///  • **C2** wrong-block merge — a deferred Backspace-merge was an unkeyed `Bool`,
///    so it merged whatever island happened to be current when it was consumed.
///  • **C3** spurious file rewrite — a click-in/click-away with ZERO typing wrote a
///    byte-identical edit: dead undo step, autosave rewrite of the user's file.
///  • **C4** event to the wrong text view — the click seam forwarded a window point
///    to a stale island when `activate` refused (IME) or bailed.
///  • **C5** typing silently discarded — an `activate` early return left a focused
///    editable cell with `activeIsland == nil`, and every keystroke was dropped.
///  • **I2** the merge raced an in-flight (not merely pending) apply.
///
/// All of these are ASYNC-SEAM bugs, so the stubs here model the real app's seam
/// (`Task { @MainActor in let doc = await onReconcile(...); applyReconciled(doc) }`)
/// — a DEFERRED apply, never an inline synchronous one. An inline stub cannot
/// express "an apply is in flight" at all, which is precisely how these got past
/// the existing suites.
@MainActor
class IslandDefectTestCase: AppKitWindowTestCase {

    /// Controllers are referenced weakly by the click/reconcile closures (as the
    /// app's wiring does); keep them alive for the test's duration.
    private var retained: [IslandController] = []

    override func tearDown() {
        retained.removeAll()
        super.tearDown()
    }

    func makeStack(_ markdown: String)
        -> (recycler: BlockRecyclerView, controller: IslandController,
            doc: QuoinDocument, window: NSWindow)
    {
        let doc = MarkdownConverter.parse(markdown)
        return makeStack(document: doc)
    }

    func makeStack(document doc: QuoinDocument)
        -> (recycler: BlockRecyclerView, controller: IslandController,
            doc: QuoinDocument, window: NSWindow)
    {
        let recycler = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = makeTestWindow(width: 640, height: 480)
        window.contentView = recycler
        recycler.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        recycler.setDocument(doc, contentWidth: 600)
        recycler.layoutSubtreeIfNeeded()
        let controller = IslandController(recycler: recycler)
        retained.append(controller)
        recycler.onBlockClicked = { [weak controller] blockID, point in
            controller?.activate(blockID: blockID, localPoint: point, in: doc, baseRevision: 0)
        }
        return (recycler, controller, doc, window)
    }

    /// What every stub reports back to the test.
    final class ReconcileLog {
        /// Documents produced by each landed apply, in landing order.
        var doc: QuoinDocument
        /// Every `(range, text)` the controller FIRED, in fire order — the
        /// interaction counter. A defect that fires twice shows up here even when
        /// the resulting document happens to look plausible.
        var fires: [(range: ByteRange, text: String)] = []
        /// Applies that have LANDED (i.e. `applyReconciled` returned).
        var applied = 0
        init(_ d: QuoinDocument) { doc = d }
    }

    /// The ASYNC stub: models the real app's deferred apply. `parseAfterEdit` reads
    /// the box's document at TASK-RUN time, so an edit fired out of order splices
    /// against the wrong bytes exactly as it would in the app.
    func installAsyncStub(_ controller: IslandController,
                          startingFrom doc: QuoinDocument) -> ReconcileLog {
        let log = ReconcileLog(doc)
        controller.onReconcile = { [weak controller] range, newText, caret in
            log.fires.append((range, newText))
            let edit = SourceEdit(range: range, replacement: newText)
            let caretDocByte = IslandCaretMapping.documentByte(
                localUTF16: caret, islandSource: newText, islandByteStart: range.offset)
            Task { @MainActor in
                let result = try! MarkdownConverter.parseAfterEdit(previous: log.doc, edit: edit)
                log.doc = result.document
                controller?.applyReconciled(result.document, caretDocByte: caretDocByte)
                log.applied += 1
            }
        }
        return log
    }

    /// Drain queued `@MainActor` apply Tasks until `applied` reaches `count`.
    func drain(_ log: ReconcileLog, until count: Int) async {
        var spins = 0
        while log.applied < count && spins < 2_000 {
            await Task.yield()
            spins += 1
        }
    }

    /// Give every already-queued `@MainActor` Task a chance to run, so a test that
    /// asserts "nothing MORE happened" is not just asserting "nothing has run yet".
    func settleTasks(spins: Int = 200) async {
        for _ in 0..<spins { await Task.yield() }
    }
}

// MARK: - C3: a click-in/click-away with zero typing must write NOTHING

@MainActor
final class IslandNoOpFlushTests: IslandDefectTestCase {

    /// C3. The island is seeded from the block's OWN bytes and
    /// `island.byteRange == block.range`, so a flush with no typing replays
    /// byte-identical bytes. `applyEdit` cannot tell, so it records an undo step
    /// (⌘Z that visibly does nothing), schedules an autosave that REWRITES the
    /// user's real file and moves its mtime, and bumps the revision (full recycler
    /// refresh). Nothing may be fired.
    ///
    /// PRE-FIX: `reconciles == 1` at the first assertion.
    func testActivateThenDeactivateWithNoTypingFiresNoReconcile() throws {
        let (recycler, controller, doc, _) = makeStack("# Heading\n\nFirst para.\n\nSecond para.")
        var reconciles = 0
        controller.onReconcile = { _, _, _ in reconciles += 1 }

        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        // ANTI-VACUITY: the activation genuinely happened, on a REAL island seeded
        // with the block's bytes. "Zero reconciles" is trivially true if nothing
        // was ever activated.
        let cell = try XCTUnwrap(recycler.currentEditorCell, "precondition: the row was promoted")
        XCTAssertNotNil(controller.activeIsland, "precondition: an island is live")
        XCTAssertEqual(cell.islandTextView.string, "First para.",
                       "precondition: the island is seeded with the block's own bytes")

        controller.deactivate()

        XCTAssertEqual(reconciles, 0,
                       "a click-in/click-away with ZERO typing must write NO edit — "
                       + "a byte-identical replay costs a dead undo step and an "
                       + "autosave rewrite of the user's file")
        XCTAssertNil(controller.activeIsland)
        XCTAssertFalse(recycler.isEditingRow(1), "the row swapped back to read-only")

        // ANTI-VACUITY (the counter can count): the SAME path with a real change
        // does fire exactly once.
        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        let again = try XCTUnwrap(recycler.currentEditorCell)
        again.islandTextView.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        controller.deactivate()
        XCTAssertEqual(reconciles, 1,
                       "control: the same swap-out WITH a change fires exactly one reconcile")
    }

    /// The debounced KEEP path has the same duty: typing that lands the island back
    /// on its original bytes (type then delete) must not fire either.
    func testDebouncedReconcileSkipsTextThatIsBackToTheOriginal() throws {
        let (recycler, controller, doc, _) = makeStack("Alpha\n\nBravo")
        var reconciles = 0
        controller.onReconcile = { _, _, _ in reconciles += 1 }

        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell)
        cell.islandTextView.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        cell.islandTextView.insertText("", replacementRange: NSRange(location: 0, length: 1))
        XCTAssertEqual(cell.islandTextView.string, "Alpha",
                       "precondition: the island text is back to the block's own bytes")

        controller.flushPendingReconcile()
        XCTAssertEqual(reconciles, 0, "text identical to the document's own bytes is not an edit")

        // ANTI-VACUITY: the debounce path itself is alive.
        cell.islandTextView.insertText("Z", replacementRange: NSRange(location: 0, length: 0))
        controller.flushPendingReconcile()
        XCTAssertEqual(reconciles, 1, "control: a real change on the same path fires once")
    }
}

// MARK: - C1: no double-apply when a flush races an in-flight apply

@MainActor
final class IslandDeferredFlushTests: IslandDefectTestCase {

    /// C1, the brief's exact repro. Type, let the debounce fire, then — while the
    /// apply is still in flight — click another block. `activate` calls
    /// `flushActiveIsland`, which (pre-fix) had NO in-flight guard and no
    /// unchanged-text short-circuit, so it fired a SECOND `onReconcile` with the
    /// SAME range and the SAME text against the un-re-anchored island range. Both
    /// applied.
    ///
    /// PRE-FIX: `fires.count == 2` and the source becomes `"Helloabcabc\n\nWorld"`.
    func testActivateDuringInFlightApplyDoesNotDoubleApply() async throws {
        let (recycler, controller, doc, _) = makeStack("Hello\n\nWorld")
        let log = installAsyncStub(controller, startingFrom: doc)

        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell)
        cell.islandTextView.insertText("abc", replacementRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(cell.islandTextView.string, "Helloabc")

        controller.flushPendingReconcile()
        // ANTI-VACUITY: the reconcile really fired, and its apply is really still
        // IN FLIGHT. Without both, "no double apply" is true because nothing
        // happened at all.
        XCTAssertEqual(log.fires.count, 1, "precondition: the debounced reconcile fired")
        XCTAssertEqual(log.applied, 0, "precondition: its apply has NOT landed yet (in flight)")

        // Click another block INSIDE that window. The app hands the click the
        // document it has published, which is still the PRE-apply one.
        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        XCTAssertEqual(log.fires.count, 1,
                       "the swap-out must NOT fire a second edit for the same island text — "
                       + "fires=\(log.fires.map { "\($0.range)/\($0.text)" })")

        await drain(log, until: 1)
        await settleTasks()

        XCTAssertEqual(log.doc.source, "Helloabc\n\nWorld",
                       "the typed text is applied EXACTLY ONCE")
        XCTAssertEqual(log.applied, 1, "exactly one edit was applied for that island")
        XCTAssertEqual(log.fires.count, 1)
    }

    /// The other half of C1: the island text CHANGED again after the in-flight
    /// reconcile, so the swap-out has something real to write but MUST NOT write it
    /// against the range the in-flight apply is about to move. The flush is
    /// deferred behind that apply and fired against the range the apply actually
    /// wrote — so the outgoing island's last keystroke is never lost and never
    /// double-applied.
    ///
    /// PRE-FIX: two edits fire immediately, both computed against `[0,5)`; the
    /// second overwrites the first's result → `"HelloabcdWorld"`-class corruption.
    func testFlushDeferredBehindInFlightApplyLandsExactlyOnceAndInOrder() async throws {
        let (recycler, controller, doc, _) = makeStack("Hello\n\nWorld")
        let log = installAsyncStub(controller, startingFrom: doc)

        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell)
        cell.islandTextView.insertText("abc", replacementRange: NSRange(location: 5, length: 0))
        controller.flushPendingReconcile()
        XCTAssertEqual(log.fires.count, 1, "precondition: the KEEP reconcile fired")
        XCTAssertEqual(log.applied, 0, "precondition: it is in flight")

        // One more keystroke, still inside the in-flight window, then swap away.
        cell.islandTextView.insertText("d", replacementRange: NSRange(location: 8, length: 0))
        XCTAssertEqual(cell.islandTextView.string, "Helloabcd")
        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)

        // The interaction, not just the outcome: the flush was DEFERRED, not fired.
        XCTAssertEqual(log.fires.count, 1, "the terminal flush must not fire while an apply is in flight")
        XCTAssertEqual(controller.deferredOpCountForTest, 1,
                       "…it must be queued behind that apply, not dropped")

        await drain(log, until: 1)
        XCTAssertEqual(log.doc.source, "Helloabc\n\nWorld",
                       "ordering: the in-flight KEEP edit lands FIRST")

        await drain(log, until: 2)
        await settleTasks()
        XCTAssertEqual(log.fires.count, 2,
                       "…then the deferred terminal flush fires exactly once")
        XCTAssertEqual(log.fires[1].range, ByteRange(offset: 0, length: 8),
                       "the deferred flush splices the range the in-flight apply actually WROTE "
                       + "([0,8) = \"Helloabc\"), not the stale pre-apply [0,5)")
        XCTAssertEqual(log.doc.source, "Helloabcd\n\nWorld",
                       "the outgoing island's final keystroke reached the document, exactly once")
        XCTAssertEqual(log.applied, 2)
        XCTAssertEqual(controller.deferredOpCountForTest, 0, "the queue drained")
    }
}

// MARK: - C2 / I2: the deferred Backspace-merge is bound to its island

@MainActor
final class IslandDeferredMergeKeyTests: IslandDefectTestCase {

    private let source = "One\n\nTwo\n\nThree\n\nFour\n\nFive"

    /// C2. Arm a Backspace-merge on island A (unflushed typing + caret 0 +
    /// Backspace), then activate island B before the flush lands. Pre-fix the
    /// pending merge was a bare `Bool` that nothing reset on `activate`, and
    /// `fireBackspaceMerge` re-resolved the predecessor from whatever island was
    /// CURRENT at consume time — so the flush's `applyReconciled` merged B into
    /// ITS predecessor: two untouched blocks joined, and A's merge never happened.
    ///
    /// PRE-FIX: the source ends `"...\n\nFourFive"` and `blocks.count == 4`.
    func testDeferredMergeDoesNotFireOnADifferentIsland() async throws {
        let (recycler, controller, doc, _) = makeStack(source)
        let log = installAsyncStub(controller, startingFrom: doc)

        // Island A = "Three" (block 2). Type, then Backspace at {0,0}.
        controller.activate(blockID: doc.blocks[2].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cellA = try XCTUnwrap(recycler.currentEditorCell)
        XCTAssertEqual(cellA.islandTextView.string, "Three")
        cellA.islandTextView.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        cellA.islandTextView.setSelectedRange(NSRange(location: 0, length: 0))
        let harness = EditorTestHarness(adopting: cellA.islandTextView, appliedRevision: { 0 })
        harness.pressBackspace()

        // ANTI-VACUITY: the merge was genuinely ARMED (deferred behind the flush),
        // and the flush genuinely fired. Without this the test could pass because
        // Backspace did nothing at all.
        XCTAssertEqual(controller.deferredOpCountForTest, 1,
                       "precondition: a Backspace-merge is queued behind the flush")
        XCTAssertEqual(log.fires.count, 1, "precondition: the KEEP flush fired")
        XCTAssertEqual(log.applied, 0, "precondition: the flush's apply is in flight")

        // Click into island B = "Five" (the LAST block) before the flush lands.
        controller.activate(blockID: doc.blocks[4].id, localPoint: .zero, in: doc, baseRevision: 0)
        XCTAssertEqual(controller.deferredOpCountForTest, 0,
                       "the outgoing island's merge must be discarded, not inherited by B")

        await drain(log, until: 1)
        await settleTasks()

        XCTAssertEqual(log.doc.source, "One\n\nTwo\n\nXThree\n\nFour\n\nFive",
                       "no merge may run: B's neighbours are untouched")
        XCTAssertEqual(log.doc.blocks.count, 5, "still five blocks — nothing was joined")
        XCTAssertEqual(log.fires.count, 1, "only the KEEP flush ever fired")
    }

    /// POSITIVE CONTROL for the test above: the identical setup WITHOUT the swap
    /// really does merge. Without this, "no merge occurred" would also pass against
    /// a build where the Backspace-merge is broken outright.
    func testControlDeferredMergeStillFiresWhenTheIslandStays() async throws {
        let (recycler, controller, doc, _) = makeStack(source)
        let log = installAsyncStub(controller, startingFrom: doc)

        controller.activate(blockID: doc.blocks[2].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cellA = try XCTUnwrap(recycler.currentEditorCell)
        cellA.islandTextView.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        cellA.islandTextView.setSelectedRange(NSRange(location: 0, length: 0))
        EditorTestHarness(adopting: cellA.islandTextView, appliedRevision: { 0 }).pressBackspace()
        XCTAssertEqual(controller.deferredOpCountForTest, 1, "precondition: merge armed")

        await drain(log, until: 2)
        await settleTasks()

        XCTAssertEqual(log.doc.source, "One\n\nTwoXThree\n\nFour\n\nFive",
                       "control: with the island still on \"XThree\", the merge joins it "
                       + "into ITS OWN predecessor")
        XCTAssertEqual(log.doc.blocks.count, 4)
    }

    /// I2. `reconcileInFlight == true && pendingReconcile == false` at Backspace.
    /// Pre-fix that combination skipped the deferral entirely and fired the merge
    /// IMMEDIATELY, as a sibling `Task` racing the in-flight KEEP apply: if the
    /// merge landed first everything shifted left by the separator length and the
    /// flush then spliced at offsets short by exactly that much.
    ///
    /// The gate is the ORDERING MECHANISM, asserted synchronously (a race's outcome
    /// is not a reliable assertion): after Backspace, no merge may have been FIRED
    /// — it must be sitting on the deferral queue.
    ///
    /// PRE-FIX: `fires.count == 2` immediately after `pressBackspace`.
    func testBackspaceWithApplyInFlightDefersInsteadOfRacing() async throws {
        let (recycler, controller, doc, _) = makeStack("First\n\nSecond")
        let log = installAsyncStub(controller, startingFrom: doc)

        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell)
        cell.islandTextView.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        // Flush FIRST, so at Backspace time the state is exactly
        // `reconcileInFlight && !pendingReconcile`.
        controller.flushPendingReconcile()
        XCTAssertEqual(log.fires.count, 1, "precondition: the KEEP edit fired")
        XCTAssertEqual(log.applied, 0, "precondition: it is IN FLIGHT")
        XCTAssertEqual(controller.deferredOpCountForTest, 0,
                       "precondition: nothing is pending — this is the I2 combination")

        cell.islandTextView.setSelectedRange(NSRange(location: 0, length: 0))
        EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { 0 }).pressBackspace()

        XCTAssertEqual(log.fires.count, 1,
                       "the merge must NOT fire as a sibling of the in-flight apply — "
                       + "fires=\(log.fires.map { "\($0.range)/\($0.text)" })")
        XCTAssertEqual(controller.deferredOpCountForTest, 1, "…it must be queued behind it")

        await drain(log, until: 2)
        await settleTasks()

        XCTAssertEqual(log.fires.count, 2, "the merge fired once, after the apply landed")
        XCTAssertEqual(log.fires[1].range, ByteRange(offset: 5, length: 2),
                       "the merge deletes the separator computed against the POST-flush "
                       + "document, not a pre-flush offset")
        XCTAssertEqual(log.doc.source, "FirstXSecond", "ordered, correct bytes")
        XCTAssertEqual(log.doc.blocks.count, 1)
        XCTAssertNotNil(controller.activeIsland, "the island survives on the merged block")
        XCTAssertEqual(recycler.currentEditorCell?.islandTextView.selectedRange().location, 5,
                       "caret at the join, after \"First\"")
    }
}

// MARK: - C4: the click seam never forwards to a stale island

@MainActor
final class IslandStaleClickForwardTests: IslandDefectTestCase {

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private func point(row: Int, dx: CGFloat, dy: CGFloat,
                       in recycler: BlockRecyclerView) -> CGPoint {
        let rect = recycler.rowRectForTest(row)
        return recycler.windowPointForTableY(CGPoint(x: rect.minX + dx, y: rect.minY + dy))
    }

    /// Drive the click seam directly and report what it decided. A terminator
    /// `leftMouseUp` is QUEUED FIRST — the defect under test is precisely that the
    /// seam FORWARDS the event into a text view's modal tracking loop, which blocks
    /// forever without one (a pre-fix run of this test hangs instead of failing).
    /// `AppKitWindowTestCase` drains the queue around every test, so an unconsumed
    /// terminator cannot leak into the next one.
    private func runSeam(at point: CGPoint, in window: NSWindow,
                         on recycler: BlockRecyclerView) -> Bool {
        Self.drainPendingMouseEvents()
        window.postEvent(mouse(.leftMouseUp, at: point, in: window), atStart: false)
        return recycler.handleTableMouseDown(mouse(.leftMouseDown, at: point, in: window))
    }

    /// C4. An IME composition is live in the island on block 3; the user clicks
    /// block 10. `IslandController.activate` parks the intent and returns WITHOUT
    /// promoting, so back in the seam `liveEditorCell`/`_editingBlockID` still point
    /// at BLOCK 3. The old guard only checked `cell.blockID == editing` — never
    /// `editing == blockID` (the block actually clicked) — so it passed, and a
    /// block-10 window point was delivered to block 3's text view: the caret jumps,
    /// a drag-select can start, and the composition is destroyed. `return true`
    /// then swallowed the click so `super` never ran either.
    ///
    /// PRE-FIX: `hasMarkedText()` is false afterwards and the selection has moved.
    func testClickDuringCompositionIsNotForwardedToTheComposingIsland() throws {
        let (recycler, controller, doc, window) = makeStack(
            (0..<14).map { "Paragraph number \($0) with a fair few words in it." }
                .joined(separator: "\n\n"))

        controller.activate(blockID: doc.blocks[3].id, localPoint: .zero, in: doc, baseRevision: 0)
        let composing = try XCTUnwrap(recycler.currentEditorCell)
        XCTAssertEqual(composing.blockID, doc.blocks[3].id, "precondition: block 3 is the island")

        // A REAL IME composition on the real text view (not the controller's probe
        // seam): `hasMarkedText()` is what the click seam consults.
        let textView = composing.islandTextView
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.hasMarkedText(),
                      "precondition: a live composition (marked text) exists in block 3's island")
        let markedBefore = textView.markedRange()
        let selectionBefore = textView.selectedRange()
        let stringBefore = textView.string

        // Click block 10.
        let clickPoint = point(row: 10, dx: 40, dy: 6, in: recycler)
        XCTAssertEqual(recycler.blockAndPoint(forWindowPoint: clickPoint)?.0, doc.blocks[10].id,
                       "precondition: the point really resolves to block 10")
        let handled = runSeam(at: clickPoint, in: window, on: recycler)

        // The refusal happened, and the composing island was left completely alone.
        XCTAssertEqual(controller.state, .blockedIME(doc.blocks[10].id),
                       "the controller parked the activation intent (no promotion)")
        XCTAssertEqual(recycler.editingBlockID, doc.blocks[3].id,
                       "block 3 is still the island — the click promoted nothing")
        XCTAssertTrue(textView.hasMarkedText(),
                      "the composition must survive: no event may reach block 3's text view")
        XCTAssertEqual(textView.markedRange(), markedBefore, "the marked range is undisturbed")
        XCTAssertEqual(textView.selectedRange(), selectionBefore, "the caret did not move")
        XCTAssertEqual(textView.string, stringBefore, "the island's text is unchanged")
        XCTAssertTrue(handled,
                      "the click is SWALLOWED rather than handed to super: letting the table "
                      + "run its tracking loop would reclaim first responder and kill the "
                      + "composition the .blockedIME refusal exists to protect")

        // ANTI-VACUITY / discrimination proof: the assertions above are only
        // meaningful if forwarding that very event to that very text view WOULD
        // disturb the composition. Do it explicitly and watch it break.
        Self.drainPendingMouseEvents()
        window.postEvent(mouse(.leftMouseUp, at: clickPoint, in: window), atStart: false)
        textView.mouseDown(with: mouse(.leftMouseDown, at: clickPoint, in: window))
        XCTAssertFalse(textView.hasMarkedText(),
                       "control: a forwarded mouseDown DOES destroy the composition — so the "
                       + "assertions above genuinely discriminate")
    }

    /// The non-IME half of C4: a stale editor cell with NO composition must fall
    /// through to `super` (the standing "never swallow a click that promoted
    /// nothing" rule), and still must not be forwarded to.
    func testStaleCellWithoutCompositionFallsThroughInsteadOfForwarding() throws {
        let (recycler, controller, doc, window) = makeStack(
            (0..<8).map { "Paragraph number \($0) with a fair few words." }
                .joined(separator: "\n\n"))

        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell)
        let selectionBefore = cell.islandTextView.selectedRange()

        // Refuse the swap without a real composition, via the controller's probe
        // seam: `activate` bails, leaving `editingBlockID` on block 1.
        controller.hasMarkedTextProbe = { true }
        let clickPoint = point(row: 5, dx: 40, dy: 6, in: recycler)
        let handled = runSeam(at: clickPoint, in: window, on: recycler)

        XCTAssertFalse(handled,
                       "with no live composition on the stale cell the seam defers to super")
        XCTAssertEqual(recycler.editingBlockID, doc.blocks[1].id, "nothing was promoted")
        XCTAssertEqual(cell.islandTextView.selectedRange(), selectionBefore,
                       "the stale island's caret was not moved by the click")
    }
}

// MARK: - C5: an activate bail never leaves an orphaned editable cell

@MainActor
final class IslandActivateBailInvariantTests: IslandDefectTestCase {

    /// C5, path 1: the requested block is not in the document. `flushActiveIsland`
    /// has already nil'd `activeIsland`, but pre-fix the recycler still pointed at
    /// the OUTGOING block with its `IslandTextView` first responder — so
    /// `islandTextDidChange` (which guards on `activeIsland != nil`) DROPPED every
    /// subsequent keystroke.
    ///
    /// PRE-FIX: `hasOrphanedEditorCell == true`, and a keystroke into the still-
    /// focused text view produces no reconcile at all.
    func testActivateWithBlockNotInDocumentLeavesNoOrphanedEditorCell() throws {
        let (recycler, controller, doc, window) = makeStack("Alpha\n\nBravo\n\nCharlie")
        var reconciles = 0
        controller.onReconcile = { _, _, _ in reconciles += 1 }

        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        let outgoing = try XCTUnwrap(recycler.currentEditorCell)
        XCTAssertTrue(window.firstResponder === outgoing.islandTextView,
                      "precondition: the outgoing island holds first responder")

        // A block id that is genuinely absent from `doc`.
        let stranger = MarkdownConverter.parse("Zulu quebec.").blocks[0].id
        XCTAssertNil(doc.blocks.first(where: { $0.id == stranger }),
                     "precondition: the id really is not in this document")

        controller.activate(blockID: stranger, localPoint: .zero, in: doc, baseRevision: 0)

        XCTAssertNil(controller.activeIsland, "the swap was abandoned")
        XCTAssertFalse(controller.hasOrphanedEditorCell,
                       "INVARIANT: a live editable cell exists ⟺ an island is active "
                       + "(editingBlockID=\(recycler.editingBlockID.map { "\($0)" } ?? "nil") "
                       + "cell=\(recycler.currentEditorCell != nil))")
        XCTAssertNil(recycler.editingBlockID)
        XCTAssertFalse(window.firstResponder === outgoing.islandTextView,
                       "the abandoned island must not keep first responder — otherwise the "
                       + "user types into a live-looking editor and every keystroke is dropped")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(reconciles, 0, "no typing happened, so nothing was written")

        // ANTI-VACUITY: the machine still works afterwards — a normal activation
        // succeeds, so the clean-up is not "everything is broken".
        controller.activate(blockID: doc.blocks[2].id, localPoint: .zero, in: doc, baseRevision: 0)
        XCTAssertNotNil(controller.activeIsland, "control: a valid activation still promotes")
        XCTAssertFalse(controller.hasOrphanedEditorCell)
    }

    /// C5, path 2: the mint fails. Built by handing the controller a document whose
    /// middle block carries a ZERO-LENGTH range, which `BlockListModel.record(at:)`
    /// cannot resolve (a half-open empty range contains nothing), so
    /// `mintIsland(at:)` returns nil — the second `activate` early return.
    func testActivateWithFailedMintLeavesNoOrphanedEditorCell() throws {
        let base = MarkdownConverter.parse("Alpha\n\nBravo\n\nCharlie")
        var blocks = base.blocks
        let middle = blocks[1]
        blocks[1] = Block(id: middle.id, kind: middle.kind,
                          range: ByteRange(offset: middle.range.offset, length: 0))
        let doc = QuoinDocument(source: base.source, blocks: blocks, outline: base.outline,
                                stats: base.stats, sourceHash: base.sourceHash)
        var model = BlockListModel(document: doc)
        XCTAssertNil(model.mintIsland(at: middle.range.offset, baseRevision: 0),
                     "precondition: this block's mint genuinely fails")

        let (recycler, controller, _, window) = makeStack(document: doc)
        controller.activate(blockID: blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)
        let outgoing = try XCTUnwrap(recycler.currentEditorCell)
        XCTAssertTrue(window.firstResponder === outgoing.islandTextView,
                      "precondition: the outgoing island holds first responder")

        controller.activate(blockID: blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)

        XCTAssertNil(controller.activeIsland, "a failed mint abandons the swap")
        XCTAssertFalse(controller.hasOrphanedEditorCell,
                       "INVARIANT: no focused editable cell may outlive its island "
                       + "(editingBlockID=\(recycler.editingBlockID.map { "\($0)" } ?? "nil") "
                       + "cell=\(recycler.currentEditorCell != nil))")
        XCTAssertNil(recycler.editingBlockID)
        XCTAssertFalse(window.firstResponder === outgoing.islandTextView,
                       "first responder was dropped with the abandoned island")
        XCTAssertEqual(controller.state, .idle)
    }
}
#endif
