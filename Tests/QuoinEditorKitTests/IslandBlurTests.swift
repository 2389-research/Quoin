#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 3, Task 1: blur deactivates the editable island. The island's text view
/// is an `IslandTextView` (the responder seam); when it resigns first responder —
/// a click outside the island, or the window handing first responder to another
/// view — the controller flushes and swaps the row back to read-only.
@MainActor
final class IslandBlurTests: AppKitWindowTestCase {

    func testResigningFirstResponderDeactivatesIsland() throws {
        // Stand up recycler + controller (mirror IslandControllerTests setup),
        // plus a second focusable view to steal first responder.
        let doc = MarkdownConverter.parse("First para.\n\nSecond para.")
        let recycler = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = makeTestWindow(width: 640, height: 400)
        let other = NSTextField(frame: NSRect(x: 0, y: 370, width: 200, height: 24))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        host.addSubview(recycler)
        host.addSubview(other)
        window.contentView = host
        recycler.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        recycler.setDocument(doc, contentWidth: 600)
        recycler.layoutSubtreeIfNeeded()

        let controller = IslandController(recycler: recycler)
        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero,
                            in: doc, baseRevision: 0)
        XCTAssertNotNil(controller.activeIsland)
        XCTAssertTrue(recycler.isEditingRow(0), "the clicked row is the editable island")
        // The BLUR must be a genuine responder handoff, not a bookkeeping change:
        // if the island never held first responder, `makeFirstResponder(other)`
        // fires no `resignFirstResponder` and the deactivation below would be
        // proving nothing about the blur seam.
        let island = try XCTUnwrap(recycler.currentEditorCell?.islandTextView)
        XCTAssertTrue(window.firstResponder === island,
                      "precondition: the island actually holds first responder")

        // Move first responder away → the island's resignFirstResponder fires →
        // deactivate runs.
        XCTAssertTrue(window.makeFirstResponder(other),
                      "precondition: first responder really moved to the other view")

        XCTAssertNil(controller.activeIsland,
                     "resigning first responder deactivates the island")
        XCTAssertFalse(recycler.isEditingRow(0), "row swapped back to read-only")
    }
}
#endif
