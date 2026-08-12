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
final class IslandBlurTests: XCTestCase {

    func testResigningFirstResponderDeactivatesIsland() {
        // Stand up recycler + controller (mirror IslandControllerTests setup),
        // plus a second focusable view to steal first responder.
        let doc = MarkdownConverter.parse("First para.\n\nSecond para.")
        let recycler = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = OffscreenTestWindow.make(width: 640, height: 400)
        defer { window.orderOut(nil) }
        let other = NSTextField(frame: NSRect(x: 0, y: 370, width: 200, height: 24))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        host.addSubview(recycler)
        host.addSubview(other)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        recycler.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        recycler.setDocument(doc, contentWidth: 600)
        recycler.layoutSubtreeIfNeeded()

        let controller = IslandController(recycler: recycler)
        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero,
                            in: doc, baseRevision: 0)
        XCTAssertNotNil(controller.activeIsland)
        XCTAssertTrue(recycler.isEditingRow(0), "the clicked row is the editable island")

        // Move first responder away → the island's resignFirstResponder fires →
        // deactivate runs.
        window.makeFirstResponder(other)

        XCTAssertNil(controller.activeIsland,
                     "resigning first responder deactivates the island")
        XCTAssertFalse(recycler.isEditingRow(0), "row swapped back to read-only")
    }
}
#endif
