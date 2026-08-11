#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

@MainActor
final class RecyclerClickTests: XCTestCase {
    func testResolvesClickToBlockAndLocalPoint() {
        let doc = MarkdownConverter.parse("First para.\n\nSecond para.\n\nThird para.")
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = v
        window.makeKeyAndOrderFront(nil)
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()
        // A window point inside the 2nd row: below the first row's height, small x.
        let row0H = v.rowHeightForTest(0)
        let p = CGPoint(x: 40, y: row0H + 6)   // flipped/table coords — helper converts
        let hit = v.blockAndPoint(forWindowPoint: v.windowPointForTableY(p))   // helper maps table-y → window
        XCTAssertEqual(hit?.0, doc.blocks[1].id)
        // Cell-local point: y is measured from the top of the 2nd row (~6pt in),
        // x carries through the fixed content column offset.
        if let local = hit?.1 {
            XCTAssertEqual(local.y, 6, accuracy: 1.0)
            XCTAssertGreaterThanOrEqual(local.x, 0)
        } else {
            XCTFail("expected a hit")
        }
    }

    func testOnBlockClickedFiresForRow() {
        let doc = MarkdownConverter.parse("First para.\n\nSecond para.\n\nThird para.")
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = v
        window.makeKeyAndOrderFront(nil)
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()

        var clicked: BlockID?
        v.onBlockClicked = { id, _ in clicked = id }
        let row0H = v.rowHeightForTest(0)
        let winPoint = v.windowPointForTableY(CGPoint(x: 40, y: row0H + 6))
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: winPoint, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        v.mouseDown(with: down)
        XCTAssertEqual(clicked, doc.blocks[1].id)
    }
}
#endif
