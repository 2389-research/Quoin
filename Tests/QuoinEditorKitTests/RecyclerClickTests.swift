#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

@MainActor
final class RecyclerClickTests: XCTestCase {

    /// Dispatch a genuine left click at `winPoint` through the window's real
    /// event path — the same hit-test/route AppKit uses at runtime — NOT a
    /// direct `view.mouseDown(with:)` call (which bypasses dispatch and would
    /// not prove the click reaches the view AppKit actually hit-tests). A
    /// mouseUp is queued first so the table's internal tracking loop, entered by
    /// `super.mouseDown`, finds its terminator and returns instead of blocking.
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

    func testResolvesClickToBlockAndLocalPoint() {
        let doc = MarkdownConverter.parse("First para.\n\nSecond para.\n\nThird para.")
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = OffscreenTestWindow.make(width: 640, height: 480)
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

    /// A REAL click — routed through `window.sendEvent`, hit-tested to the table
    /// AppKit dispatches to, NOT `v.mouseDown(...)` directly — fires
    /// `onBlockClicked` with the clicked block. This is the regression guard for
    /// the dead-ancestor-override bug: the seam only counts if a genuine click
    /// reaches it.
    func testRealClickFiresOnBlockClicked() {
        let doc = MarkdownConverter.parse("First para.\n\nSecond para.\n\nThird para.")
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = OffscreenTestWindow.make(width: 640, height: 480)
        window.contentView = v
        window.makeKeyAndOrderFront(nil)
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()

        var clicked: BlockID?
        v.onBlockClicked = { id, _ in clicked = id }
        let row0H = v.rowHeightForTest(0)
        let winPoint = v.windowPointForTableY(CGPoint(x: 40, y: row0H + 6))
        dispatchRealClick(at: winPoint, in: window)
        XCTAssertEqual(clicked, doc.blocks[1].id,
                       "a real dispatched click over row 1 must fire onBlockClicked with blocks[1]")
    }

    /// After scrolling a tall document, a real click at a now-visible deep row's
    /// on-screen center resolves to THAT block — proving the window→table
    /// conversion honours the scroll offset (the resolver's scroll-correctness
    /// claim).
    func testRealClickAfterScrollResolvesVisibleRow() {
        var md = ""
        for i in 0..<40 { md += "Paragraph number \(i).\n\n" }
        let doc = MarkdownConverter.parse(md)
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = OffscreenTestWindow.make(width: 640, height: 300)
        window.contentView = v
        window.makeKeyAndOrderFront(nil)
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()

        let target = 25
        v.scroll(to: doc.blocks[target].id)
        v.layoutSubtreeIfNeeded()

        var clicked: BlockID?
        v.onBlockClicked = { id, _ in clicked = id }
        let rect = v.rowRectForTest(target)
        let winPoint = v.windowPointForTableY(CGPoint(x: 40, y: rect.midY))
        dispatchRealClick(at: winPoint, in: window)
        XCTAssertEqual(clicked, doc.blocks[target].id,
                       "after scroll, a real click over row \(target) must resolve to blocks[\(target)]")
    }
}
#endif
