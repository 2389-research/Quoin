#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 3 hotfix repro (harness-gap closer). A real click promotes a block to an
/// editable island, but the island tears ITSELF down: `editingBlockID`'s
/// `reloadData(forRowIndexes:)` DEFERS the read→edit row rebuild; when that
/// deferred layout commits (in the app, inside `super.mouseDown`'s tracking loop),
/// the table re-vends the editing row's view, REMOVING the first-responder
/// `IslandTextView` from the window → `resignFirstResponder` → the controller's
/// blur seam → `deactivate()` → the row reverts to read-only. Net: clicking a
/// block briefly grows an editor then snaps back; nothing stays editable.
///
/// The earlier click tests missed this because they assert first responder
/// SYNCHRONOUSLY (before the deferred reload commits) or use a no-op
/// `onBlockClicked`. This test wires the REAL `IslandController.activate(...)`, on
/// a KEY window, and — crucially — SPINS THE RUNLOOP / forces a layout pass after
/// the click so the deferred reload commits exactly as the app's tracking loop
/// gives it the chance to. Pre-fix this FAILS (island torn down: FR is the table,
/// `editingBlockID` nil). Post-fix the activation survives the transient resign.
@MainActor
final class IslandActivationSurvivesReloadTests: XCTestCase {

    /// Dispatch a genuine left click at `winPoint` through the window's real event
    /// path (queue mouseUp first so the table's `super.mouseDown` tracking loop
    /// terminates instead of blocking).
    private func dispatchRealClick(at winPoint: CGPoint, in window: NSWindow) {
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: winPoint, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: winPoint, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0)!
        window.postEvent(up, atStart: false)
        window.sendEvent(down)
    }

    /// Reproduce the app's teardown seam headless. In the app the read→edit
    /// `reloadData(forRowIndexes:)` armed by `editingBlockID` is DEFERRED and
    /// commits inside `super.mouseDown`'s tracking loop, re-vending the editing row
    /// AFTER first responder was handed to the island — evicting it. Headless the
    /// activation's `editorCellForEditingRow()` (makeIfNecessary) already consumes
    /// that deferred reload and a runloop spin does NOT re-vend, so we trigger the
    /// SAME `reloadData(forRowIndexes:[editingRow])` explicitly via
    /// `reloadEditingRow()`: it commits the identical table op after first
    /// responder is live, exactly as the tracking-loop commit does. Pre-fix this
    /// re-vend fires `resignFirstResponder` → the blur seam → `deactivate()`; the
    /// island tears itself down.
    private func commitDeferredReload(_ recycler: BlockRecyclerView) {
        recycler.reloadEditingRow()
        recycler.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    /// Stand up a real recycler + controller in a KEY window and return them along
    /// with the parsed document. Mirrors the app's wiring: `onBlockClicked` →
    /// `controller.activate(...)`.
    private func makeStack(_ markdown: String)
        -> (recycler: BlockRecyclerView, controller: IslandController,
            doc: QuoinDocument, window: NSWindow)
    {
        let doc = MarkdownConverter.parse(markdown)
        let recycler = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = recycler
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        recycler.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        recycler.setDocument(doc, contentWidth: 600)
        recycler.layoutSubtreeIfNeeded()

        let controller = IslandController(recycler: recycler)
        recycler.onBlockClicked = { [weak controller] blockID, point in
            controller?.activate(blockID: blockID, localPoint: point,
                                 in: doc, baseRevision: 0)
        }
        return (recycler, controller, doc, window)
    }

    /// THE REPRO (paragraph — the 1:1-seeding priority path). A real click on a
    /// PARAGRAPH block, wired to the live controller, must leave that block the
    /// active, first-responder island AFTER the deferred reload commits.
    func testParagraphClickStaysEditableAcrossDeferredReload() {
        let (recycler, controller, doc, window) =
            makeStack("First para.\n\nSecond para.\n\nThird para.")
        defer { window.orderOut(nil) }

        let clickedBlockID = doc.blocks[1].id
        let row0H = recycler.rowHeightForTest(0)
        let winPoint = recycler.windowPointForTableY(CGPoint(x: 40, y: row0H + 6))
        dispatchRealClick(at: winPoint, in: window)

        // Give the deferred read→edit reload the chance the app's tracking loop
        // gives it. This is where the pre-fix teardown fires.
        commitDeferredReload(recycler)

        let island = recycler.currentEditorCell?.islandTextView
        XCTAssertNotNil(controller.activeIsland,
                        "the paragraph island survives the deferred reload (not torn down)")
        XCTAssertEqual(recycler.editingBlockID, clickedBlockID,
                       "the clicked row stays the editable island")
        XCTAssertNotNil(island, "the editing cell still hosts an island text view")
        XCTAssertTrue(window.firstResponder === island,
                      "the island text view keeps window first responder across the reload")
        XCTAssertTrue(island?.isEditable ?? false, "the island is editable")
    }

    /// Regression: clicking a DIFFERENT block after activating one must DEACTIVATE
    /// the first and ACTIVATE the second (proves the transient-resign suppression
    /// did NOT over-suppress a genuine block-to-block move).
    func testClickingDifferentBlockMovesTheIsland() {
        let (recycler, controller, doc, window) =
            makeStack("First para.\n\nSecond para.\n\nThird para.")
        defer { window.orderOut(nil) }

        // Activate block 1.
        let row0H = recycler.rowHeightForTest(0)
        let p1 = recycler.windowPointForTableY(CGPoint(x: 40, y: row0H + 6))
        dispatchRealClick(at: p1, in: window)
        commitDeferredReload(recycler)
        XCTAssertEqual(recycler.editingBlockID, doc.blocks[1].id,
                       "precondition: block 1 is the active island")

        // Click block 2.
        let row1H = recycler.rowHeightForTest(1)
        let p2 = recycler.windowPointForTableY(CGPoint(x: 40, y: row0H + row1H + 6))
        dispatchRealClick(at: p2, in: window)
        commitDeferredReload(recycler)

        XCTAssertEqual(recycler.editingBlockID, doc.blocks[2].id,
                       "clicking block 2 moves the island to it")
        XCTAssertNotNil(controller.activeIsland, "the new island is active")
        let island = recycler.currentEditorCell?.islandTextView
        XCTAssertTrue(window.firstResponder === island,
                      "the new island holds first responder")
    }

    /// Regression: a GENUINE blur (window hands first responder to another view)
    /// STILL deactivates the island — the suppression only spares a reload-induced
    /// resign, never a real focus change.
    func testGenuineBlurStillDeactivates() {
        let doc = MarkdownConverter.parse("First para.\n\nSecond para.")
        let recycler = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let other = NSTextField(frame: NSRect(x: 0, y: 370, width: 200, height: 24))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        host.addSubview(recycler)
        host.addSubview(other)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        recycler.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        recycler.setDocument(doc, contentWidth: 600)
        recycler.layoutSubtreeIfNeeded()

        let controller = IslandController(recycler: recycler)
        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero,
                            in: doc, baseRevision: 0)
        // A transient editing-row reload must be SURVIVED (fix), leaving the island
        // active — so the genuine blur below is the ONLY thing that deactivates it.
        recycler.reloadEditingRow()
        recycler.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        XCTAssertNotNil(controller.activeIsland, "precondition: island survives a transient reload")

        // Genuine focus change to a DIFFERENT, non-island view.
        window.makeFirstResponder(other)

        XCTAssertNil(controller.activeIsland,
                     "a genuine blur to another view still deactivates the island")
        XCTAssertFalse(recycler.isEditingRow(0), "row swapped back to read-only")
    }
}
#endif
