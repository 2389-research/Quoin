#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 3: the CLICK-SEAM RE-SHAPE — "promote, then forward; never call
/// `super`".
///
/// The old seam fired `onBlockClicked` (→ `IslandController.activate`) and then
/// called `super.mouseDown`, handing the click to `NSTableView`'s modal tracking
/// loop. In a KEY window that loop reclaims first responder for the TABLE
/// (`NSWindow._realMakeFirstResponder` at the base of the live trace's stack:
/// island focused at `activate.madeFirstResponder`, then
/// `click.mouseDown.post firstResponder=ClickReportingTableView`) — the "never
/// becomes editable" half of the bug. The new seam promotes the row
/// SYNCHRONOUSLY and forwards the ORIGINAL event to the island's text view, so
/// the table never processes the click at all.
///
/// These are DISCRIMINATORS, not smoke tests — each one fails on the old
/// architecture and can only pass on the new one:
///
///  1. **Ownership**: first responder is the island AND `selectedRow == -1`. The
///     table cannot have run its tracking loop without selecting the row.
///  2. **Drag-select**: a press-drag-release across the island leaves a non-empty
///     selection. Only reachable if the text view runs its OWN native tracking on
///     the promoting click; the old seam gave that event to the table.
///  3. **Caret accuracy**: the caret the click produced equals
///     `characterIndexForInsertion(at:)` computed independently IN THE TEXT
///     VIEW'S OWN coordinate space — i.e. the caret comes from the text view, not
///     from the controller's row-local `placeCaret` math (which measures from the
///     ROW's top-left while the text view carries its own insets).
///  4. **No animation**: every table op that can change a row's height runs at
///     `NSAnimationContext.duration == 0` (spec §4 steps 3/6). A bare
///     `noteHeightOfRows` inherits the ambient 0.25 s and ANIMATES the
///     read-height↔island-height flip — the visible grow/shrink jiggle.
///
/// ## Key window: MEASURED, NOT ACHIEVED (read this before "fixing" the harness)
///
/// The brief asked for a KEY test window, because the borderless windows the rest
/// of the suite uses report `canBecomeKey == false` and so never exercised the
/// first-responder-theft candidate. It is not reachable in this process, and the
/// reason is not the style mask:
///
///  • `KeyableOffscreenWindow` (borderless + `canBecomeKey` overridden to `true`)
///    still reports `isKeyWindow == false`: the test process runs under a
///    `.prohibited`/`.accessory` activation policy, is never ACTIVE, and an
///    inactive app has no key window. `NSApp.activate(ignoringOtherApps:)` does
///    not change that (measured).
///  • Worse, a window that CAN become key but ISN'T swallows every dispatched
///    `leftMouseDown` — AppKit spends the click on the activation it can never
///    complete. Measured directly: the same click that a non-keyable borderless
///    window delivers (`downs=1`, then `2`) yields `downs=0` on the keyable one,
///    twice in a row. That is the real mechanism behind the "a `.titled` window
///    swallows the click" pitfall in `IslandActivationChurnTests` — keyability,
///    not the title bar.
///
/// So making the harness keyable would cost every click test and buy nothing.
/// These tests therefore run on the delivering (non-key) window, and
/// `testKeyWindowIsUnreachableInThisProcess` pins BOTH measurements so the note
/// above stays true. What remains unproven headlessly: that `NSTableView` would
/// not reclaim first responder inside `super.mouseDown`'s tracking loop **in a
/// genuinely key window**. That path is closed three ways instead —
/// `super.mouseDown` is never called on the promote path (asserted directly via
/// `tableSuperMouseDownCountForTest`), the table `refusesFirstResponder`, and
/// `validateProposedFirstResponder` approves the island — and each of those IS
/// asserted here.
@MainActor
final class IslandClickSeamTests: AppKitWindowTestCase {

    // MARK: - Harness

    /// The click closure holds its `IslandController` WEAKLY (as the app's wiring
    /// does), so a test that discards the returned controller would silently click
    /// into a dead seam. Keep them alive for the duration of the test.
    private var retainedControllers: [IslandController] = []

    override func tearDown() {
        retainedControllers.removeAll()
        super.tearDown()
    }

    private func makeStack(_ markdown: String)
        -> (recycler: BlockRecyclerView, controller: IslandController,
            doc: QuoinDocument, window: NSWindow)
    {
        let doc = MarkdownConverter.parse(markdown)
        let recycler = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = makeTestWindow(width: 640, height: 480)
        window.contentView = recycler
        recycler.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        recycler.setDocument(doc, contentWidth: 600)
        recycler.layoutSubtreeIfNeeded()

        let controller = IslandController(recycler: recycler)
        retainedControllers.append(controller)
        recycler.onBlockClicked = { [weak controller] blockID, point in
            controller?.activate(blockID: blockID, localPoint: point,
                                 in: doc, baseRevision: 0)
        }
        return (recycler, controller, doc, window)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint,
                       in window: NSWindow, clickCount: Int = 1,
                       modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// A genuine click through the window's real event path. The mouseUp is
    /// QUEUED FIRST so whichever modal tracking loop the down enters (the text
    /// view's, now) finds its terminator instead of blocking.
    private func dispatchClick(at point: CGPoint, in window: NSWindow,
                               clickCount: Int = 1,
                               modifiers: NSEvent.ModifierFlags = []) {
        // A stale posted event from an earlier dispatch would be pulled off the
        // application-wide queue by this click's tracking loop and silently turn it
        // into a drag (see `drainPendingMouseEvents`).
        Self.drainPendingMouseEvents()
        window.postEvent(mouse(.leftMouseUp, at: point, in: window,
                               clickCount: clickCount, modifiers: modifiers),
                         atStart: false)
        window.sendEvent(mouse(.leftMouseDown, at: point, in: window,
                               clickCount: clickCount, modifiers: modifiers))
    }

    /// A press-drag-release. Every follow-up event is queued BEFORE the down is
    /// sent, because the down enters a tracking loop that pulls them off the
    /// queue itself.
    private func dispatchDrag(from start: CGPoint, through points: [CGPoint],
                              in window: NSWindow) {
        Self.drainPendingMouseEvents()
        for point in points {
            window.postEvent(mouse(.leftMouseDragged, at: point, in: window),
                             atStart: false)
        }
        window.postEvent(mouse(.leftMouseUp, at: points.last ?? start, in: window),
                         atStart: false)
        window.sendEvent(mouse(.leftMouseDown, at: start, in: window))
    }

    private func settle(_ root: NSView, in window: NSWindow, spins: Int = 4) {
        for _ in 0..<spins {
            root.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// A window point over row `row`, `dx` points in from the row's left edge and
    /// `dy` down from its top (a point ON the first text line, not the row's
    /// vertical middle, so the caret index is a real column).
    private func point(row: Int, dx: CGFloat, dy: CGFloat,
                       in recycler: BlockRecyclerView) -> CGPoint {
        let rect = recycler.rowRectForTest(row)
        return recycler.windowPointForTableY(CGPoint(x: rect.minX + dx, y: rect.minY + dy))
    }

    // MARK: - 0. The key-window gap: measured, not hand-waved

    /// Pins the two measurements behind this file's "key window is unreachable"
    /// note (see the type comment), so the note cannot rot into a guess:
    ///
    ///  1. a window that CAN become key still is NOT key here (the process is
    ///     never active), and
    ///  2. that non-key-but-keyable window SWALLOWS dispatched clicks, while the
    ///     non-keyable one delivers them.
    ///
    /// If a future macOS/xctest ever hands a non-activating process a key window,
    /// assertion 1 fails — which is the signal to move these tests onto
    /// `makeKeyTestWindow` and finally exercise the FR-theft path for real.
    func testKeyWindowIsUnreachableInThisProcess() {
        final class ProbeView: NSView {
            var downs = 0
            override func mouseDown(with event: NSEvent) { downs += 1 }
        }

        let keyable = makeKeyTestWindow(width: 320, height: 240)
        XCTAssertTrue(keyable.canBecomeKey, "KeyableOffscreenWindow must be keyABLE")
        NSApp.activate(ignoringOtherApps: true)
        keyable.makeKeyAndOrderFront(nil)
        XCTAssertFalse(
            keyable.isKeyWindow,
            "a non-activating (.prohibited/.accessory) process has no key window — if this "
            + "now PASSES, key windows are available and the click-seam tests should move "
            + "onto makeKeyTestWindow to cover the first-responder-theft path")

        let deliveringProbe = ProbeView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let delivering = makeTestWindow(width: 320, height: 240)
        delivering.contentView = deliveringProbe
        dispatchClick(at: CGPoint(x: 100, y: 100), in: delivering)
        XCTAssertEqual(deliveringProbe.downs, 1,
                       "the non-keyable window must DELIVER dispatched clicks")

        let swallowedProbe = ProbeView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        keyable.contentView = swallowedProbe
        XCTAssertNotNil(keyable.contentView?.hitTest(CGPoint(x: 100, y: 100)),
                        "precondition: the point hit-tests to the probe view")
        dispatchClick(at: CGPoint(x: 100, y: 100), in: keyable)
        dispatchClick(at: CGPoint(x: 100, y: 100), in: keyable)
        XCTAssertEqual(swallowedProbe.downs, 0,
                       "a keyable-but-not-key window swallows dispatched clicks (twice over) "
                       + "— this, not the title bar, is why the harness stays non-keyable")
    }

    /// The FR-theft defenses that ARE testable without a key window: the table
    /// refuses first responder outright, and it approves the island (and anything
    /// inside a `BlockEditorCell`) when AppKit asks who may take focus for a click.
    func testTableRefusesFirstResponderAndApprovesTheIsland() throws {
        let (recycler, _, _, window) = makeStack("First para.\n\nSecond para.")
        dispatchClick(at: point(row: 0, dx: 40, dy: 6, in: recycler), in: window)
        settle(recycler, in: window)
        let cell = try XCTUnwrap(recycler.currentEditorCell)

        XCTAssertFalse(recycler.tableAcceptsFirstResponderForTest,
                       "the table must refuse first responder — every keystroke belongs to the island")
        XCTAssertTrue(recycler.tableValidatesFirstResponderForTest(cell.islandTextView),
                      "the table must approve the island as first responder")
        XCTAssertTrue(recycler.tableValidatesFirstResponderForTest(cell),
                      "…and anything inside the editor cell")
    }

    // MARK: - 1. Ownership

    /// THE OWNERSHIP DISCRIMINATOR. After a full click round trip on a paragraph:
    /// the island holds first responder, the block is editable, and the table's
    /// `selectedRow` is still -1 — positive proof `super.mouseDown` never ran, so
    /// the table never got the chance to steal focus.
    func testClickLeavesFirstResponderOnTheIslandAndTheTableUntouched() throws {
        let (recycler, controller, doc, window) =
            makeStack("First para.\n\nSecond paragraph with a fair few words in it.\n\nThird para.")

        let clickedRow = 1
        dispatchClick(at: point(row: clickedRow, dx: 40, dy: 6, in: recycler), in: window)
        settle(recycler, in: window)

        let cell = try XCTUnwrap(recycler.currentEditorCell, "the click must promote a live island")
        let fr = window.firstResponder
        let trace = """
            firstResponder=\(fr.map { String(describing: type(of: $0)) } ?? "nil") \
            selectedRow=\(recycler.selectedRowForTest) \
            superMouseDowns=\(recycler.tableSuperMouseDownCountForTest) \
            editingBlockID=\(recycler.editingBlockID.map { "\($0)" } ?? "nil") \
            isKey=\(window.isKeyWindow)
            """

        XCTAssertTrue(fr === cell.islandTextView,
                      "the island text view owns first responder at the end of the click — \(trace)")
        XCTAssertEqual(recycler.tableSuperMouseDownCountForTest, 0,
                       "the promoting click must NEVER reach super.mouseDown — \(trace)")
        XCTAssertEqual(recycler.selectedRowForTest, -1,
                       "the table must never have processed the click (a run of "
                       + "super.mouseDown would have selected the row) — \(trace)")
        XCTAssertEqual(recycler.editingBlockID, doc.blocks[clickedRow].id,
                       "the clicked block is the editable one — \(trace)")
        XCTAssertNotNil(controller.activeIsland, "the island is live — \(trace)")
        XCTAssertTrue(cell.islandTextView.isEditable, "the island is editable — \(trace)")
    }

    /// The seam still DEFERS to the table where table semantics belong: a
    /// modifier-click (reserved for future block selection) must not promote and
    /// must not be swallowed.
    func testModifierClickFallsThroughToTheTable() {
        let (recycler, controller, _, window) = makeStack("First para.\n\nSecond para.")

        let event = mouse(.leftMouseDown, at: point(row: 1, dx: 40, dy: 6, in: recycler),
                          in: window, modifiers: .command)
        XCTAssertFalse(recycler.handleTableMouseDown(event),
                       "a ⌘-click must fall through to super.mouseDown (table semantics)")
        XCTAssertNil(controller.activeIsland, "a ⌘-click must not promote an island")
        XCTAssertNil(recycler.editingBlockID)
    }

    /// A click that resolves to NO block (below the last row) also falls through.
    func testClickOnEmptyAreaFallsThroughToTheTable() {
        let (recycler, controller, _, window) = makeStack("First para.\n\nSecond para.")

        // Far below the last row: `blockAndPoint` returns nil there.
        let far = recycler.windowPointForTableY(CGPoint(x: 40, y: 100_000))
        let event = mouse(.leftMouseDown, at: far, in: window)
        XCTAssertFalse(recycler.handleTableMouseDown(event),
                       "a click that resolves to no block must fall through to the table")
        XCTAssertNil(controller.activeIsland)
    }

    /// A DOUBLE click is forwarded too (documented choice): word-select belongs to
    /// the text view, and the table has no double-click action.
    func testDoubleClickIsForwardedToTheIsland() throws {
        let (recycler, _, _, window) =
            makeStack("First para.\n\nSecond paragraph with a fair few words in it.\n\nThird.")

        dispatchClick(at: point(row: 1, dx: 60, dy: 6, in: recycler),
                      in: window, clickCount: 2)
        settle(recycler, in: window)

        let cell = try XCTUnwrap(recycler.currentEditorCell,
                                 "a double-click must still promote the row")
        XCTAssertTrue(window.firstResponder === cell.islandTextView,
                      "the double-click reaches the text view, not the table")
        XCTAssertGreaterThan(cell.islandTextView.selectedRange().length, 0,
                             "a double-click inside the island selects a word "
                             + "(sel=\(NSStringFromRange(cell.islandTextView.selectedRange())))")
    }

    // MARK: - 2. Drag-select

    /// THE CLEANEST DISCRIMINATOR: press on a not-yet-editable block, drag across
    /// it, release — and end up with a real SELECTION. This is impossible unless
    /// the promoting event itself is handed to the island's text view, because the
    /// text view's own tracking loop is what turns the subsequent drags into a
    /// selection. Under the old seam the event went to `NSTableView`, which would
    /// have interpreted the drag as a row drag.
    func testDragSelectsTextOnThePromotingClick() throws {
        let (recycler, _, _, window) = makeStack(
            "First para.\n\nSecond paragraph with a fair few words in it so a drag "
            + "across it has somewhere to go.\n\nThird para.")

        let row = 1
        let start = point(row: row, dx: 20, dy: 6, in: recycler)
        let drags = (1...6).map { point(row: row, dx: 20 + CGFloat($0) * 30, dy: 6, in: recycler) }
        dispatchDrag(from: start, through: drags, in: window)
        settle(recycler, in: window)

        let cell = try XCTUnwrap(recycler.currentEditorCell,
                                 "the press must promote the row to an island")
        let selection = cell.islandTextView.selectedRange()
        XCTAssertGreaterThan(
            selection.length, 0,
            "dragging across the promoting click must select text — sel="
            + "\(NSStringFromRange(selection)) fr="
            + "\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
    }

    // MARK: - 3. Caret accuracy

    /// The caret produced by a click must be the caret the TEXT VIEW itself would
    /// place for that point, in ITS OWN coordinate space — i.e. it comes from the
    /// forwarded event, not from the controller's row-local `placeCaret` math
    /// (which measures from the ROW's top-left and is bypassed on the click path).
    ///
    /// Anti-vacuity: the expected index must be strictly inside the text, so a
    /// caret stuck at 0 or clamped to the end cannot pass by accident.
    func testCaretComesFromTheTextViewsOwnHitTest() throws {
        let (recycler, _, _, window) = makeStack(
            "First para.\n\nSecond paragraph with a fair few words in it so a click "
            + "lands in the middle of a line.\n\nThird para.")

        let row = 1
        let winPoint = point(row: row, dx: 90, dy: 6, in: recycler)
        dispatchClick(at: winPoint, in: window)
        settle(recycler, in: window)

        let cell = try XCTUnwrap(recycler.currentEditorCell)
        let textView = cell.islandTextView
        let localToTextView = textView.convert(winPoint, from: nil)
        let expected = textView.characterIndexForInsertion(at: localToTextView)
        let actual = textView.selectedRange().location
        let length = (textView.string as NSString).length

        let trace = "expected=\(expected) actual=\(actual) length=\(length) "
            + "pointInTextView=\(NSStringFromPoint(localToTextView))"
        XCTAssertGreaterThan(expected, 0, "anti-vacuity: the click must land inside the line — \(trace)")
        XCTAssertLessThan(expected, length, "anti-vacuity: the click must not land at the end — \(trace)")
        XCTAssertEqual(actual, expected,
                       "the caret must be the text view's own hit test for the click point — \(trace)")
        XCTAssertEqual(textView.selectedRange().length, 0, "a plain click leaves no selection — \(trace)")
    }

    // MARK: - 4. No animation on the promote

    /// Spec §4 steps 3/6. Every table op that can change a row's height runs
    /// inside a zero-duration `NSAnimationContext`; a bare
    /// `noteHeightOfRows(withIndexesChanged:)` inherits the ambient duration
    /// (0.25 s) and AppKit animates the read-height↔island-height flip — which is
    /// exactly the grow/shrink the user sees. Also pins the viewport half: the
    /// clicked row must not move on screen and the list must not scroll.
    func testPromotionIsUnanimatedAndDoesNotMoveTheClickedRow() throws {
        let (recycler, _, doc, window) = makeStack(
            (0..<40).map { "Paragraph number \($0) with a little text." }
                .joined(separator: "\n\n"))
        // Scrolled into the BODY of the document: at origin, a bug that scrolls to
        // the top is invisible.
        recycler.scroll(to: doc.blocks[10].id)
        settle(recycler, in: window, spins: 2)

        let row = 12
        let beforeOrigin = recycler.scrollOriginForTest
        let beforeRowTop = recycler.windowPointForTableY(
            CGPoint(x: 0, y: recycler.rowRectForTest(row).minY)).y

        recycler.resetChurnCountersForTest()
        // Ambient animation ON, the way AppKit leaves it: if the recycler did not
        // explicitly zero the duration, the height flip would animate.
        NSAnimationContext.current.duration = 0.25
        dispatchClick(at: point(row: row, dx: 40, dy: 6, in: recycler), in: window)
        settle(recycler, in: window)

        let durations = recycler.animationDurationsForTest
        let afterOrigin = recycler.scrollOriginForTest
        let afterRowTop = recycler.windowPointForTableY(
            CGPoint(x: 0, y: recycler.rowRectForTest(row).minY)).y
        let trace = "durations=\(durations) origin \(NSStringFromPoint(beforeOrigin))"
            + "→\(NSStringFromPoint(afterOrigin)) rowTop \(beforeRowTop)→\(afterRowTop)"

        XCTAssertFalse(durations.isEmpty,
                       "anti-vacuity: the promote must actually run height work — \(trace)")
        XCTAssertTrue(durations.allSatisfy { $0 == 0 },
                      "every height/reload op in the swap must be zero-duration — \(trace)")
        XCTAssertNotNil(recycler.currentEditorCell, "the promote path ran — \(trace)")
        XCTAssertEqual(afterOrigin.y, beforeOrigin.y, accuracy: 0.5,
                       "promoting must not scroll the list — \(trace)")
        XCTAssertEqual(afterRowTop, beforeRowTop, accuracy: 4.0,
                       "the clicked row must not move on screen (spec §4 drift < 4pt) — \(trace)")
    }

    // MARK: - 5. Block-to-block swap through the REAL click path

    /// Clicking a DIFFERENT block deactivates the old island and activates the new
    /// one — through the forwarding seam, in a key window (the regression the
    /// re-shape must not introduce).
    func testClickingAnotherBlockMovesTheIsland() throws {
        let (recycler, controller, doc, window) =
            makeStack("First para.\n\nSecond para.\n\nThird para.")

        dispatchClick(at: point(row: 1, dx: 40, dy: 6, in: recycler), in: window)
        settle(recycler, in: window)
        XCTAssertEqual(recycler.editingBlockID, doc.blocks[1].id, "precondition: row 1 is the island")
        let firstCell = try XCTUnwrap(recycler.currentEditorCell)

        dispatchClick(at: point(row: 2, dx: 40, dy: 6, in: recycler), in: window)
        settle(recycler, in: window)

        let secondCell = try XCTUnwrap(recycler.currentEditorCell)
        let trace = """
            editingBlockID=\(recycler.editingBlockID.map { "\($0)" } ?? "nil") \
            activeIsland=\(controller.activeIsland != nil) \
            fr=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")
            """
        XCTAssertEqual(recycler.editingBlockID, doc.blocks[2].id,
                       "the second click moves the island to row 2 — \(trace)")
        XCTAssertNotNil(controller.activeIsland, "the new island is live — \(trace)")
        XCTAssertTrue(window.firstResponder === secondCell.islandTextView,
                      "first responder follows the new island — \(trace)")
        XCTAssertFalse(recycler.isEditingRow(1), "row 1 went back to read-only — \(trace)")
        XCTAssertEqual(recycler.selectedRowForTest, -1,
                       "neither click reached the table — \(trace)")
        _ = firstCell   // (the editor cell is recycled; identity is not the assertion)
    }

    /// A genuine blur still deactivates, in a KEY window and after a real
    /// forwarding click (the `IslandBlurTests` property, re-proved on the new
    /// seam and in the regime where first-responder traffic actually happens).
    func testGenuineBlurStillDeactivatesAfterAForwardedClick() {
        let doc = MarkdownConverter.parse("First para.\n\nSecond para.")
        let recycler = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = makeTestWindow(width: 640, height: 480)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let other = NSTextField(frame: NSRect(x: 0, y: 450, width: 200, height: 24))
        recycler.frame = NSRect(x: 0, y: 0, width: 640, height: 440)
        host.addSubview(recycler)
        host.addSubview(other)
        window.contentView = host
        recycler.setDocument(doc, contentWidth: 600)
        recycler.layoutSubtreeIfNeeded()

        let controller = IslandController(recycler: recycler)
        retainedControllers.append(controller)
        recycler.onBlockClicked = { [weak controller] blockID, point in
            controller?.activate(blockID: blockID, localPoint: point, in: doc, baseRevision: 0)
        }

        dispatchClick(at: point(row: 0, dx: 40, dy: 6, in: recycler), in: window)
        settle(recycler, in: window)
        XCTAssertNotNil(controller.activeIsland, "precondition: the click produced an island")

        window.makeFirstResponder(other)

        XCTAssertNil(controller.activeIsland, "a genuine blur still deactivates the island")
        XCTAssertFalse(recycler.isEditingRow(0), "the row swapped back to read-only")
    }
}
#endif
