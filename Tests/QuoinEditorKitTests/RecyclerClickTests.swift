#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Inherits `AppKitWindowTestCase` for its two hygiene properties, both of which
/// this suite needs and neither of which a bare `XCTestCase` provides: the
/// offscreen windows are CLOSED at teardown (they were only ever `orderOut`, so
/// with `isReleasedWhenClosed == false` they leaked for the whole run), and the
/// application-wide mouse queue is DRAINED around each test. This suite POSTS a
/// `leftMouseUp` per click; when the click resolves to no live island the seam
/// falls through to `super.mouseDown`, and if that tracking loop ever stops
/// consuming the terminator the stale event leaks into the next suite and turns
/// its click into a drag (the documented cross-suite failure).
@MainActor
final class RecyclerClickTests: AppKitWindowTestCase {

    /// Dispatch a genuine left click at `winPoint` through the window's real
    /// event path — the same hit-test/route AppKit uses at runtime — NOT a
    /// direct `view.mouseDown(with:)` call (which bypasses dispatch and would
    /// not prove the click reaches the view AppKit actually hit-tests). A
    /// mouseUp is queued first so the table's internal tracking loop, entered by
    /// `super.mouseDown`, finds its terminator and returns instead of blocking.
    private func dispatchRealClick(at winPoint: CGPoint, in window: NSWindow) {
        Self.drainPendingMouseEvents()
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

    func testResolvesClickToBlockAndLocalPoint() throws {
        let doc = MarkdownConverter.parse("First para.\n\nSecond para.\n\nThird para.")
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = makeTestWindow(width: 640, height: 480)
        window.contentView = v
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()
        // A window point inside the 2nd row: below the first row's height, small x.
        let row0H = v.rowHeightForTest(0)
        let p = CGPoint(x: 40, y: row0H + 6)   // flipped/table coords — helper converts
        let hit = try XCTUnwrap(v.blockAndPoint(forWindowPoint: v.windowPointForTableY(p)),
                                "the point must resolve to a block")
        XCTAssertEqual(hit.0, doc.blocks[1].id)
        // Anti-vacuity for the row pick: row 0 is a DIFFERENT block, so "resolves
        // to blocks[1]" is a real discrimination and not "every point answers the
        // same id".
        XCTAssertNotEqual(doc.blocks[0].id, doc.blocks[1].id)
        XCTAssertEqual(v.blockAndPoint(forWindowPoint: v.windowPointForTableY(
            CGPoint(x: 40, y: 2)))?.0, doc.blocks[0].id,
            "a point in row 0 must resolve to blocks[0], not blocks[1]")
        // Cell-local point: y is measured from the top of the 2nd row (~6pt in),
        // x carries through the fixed content column offset — bounded ABOVE too,
        // so a local point that silently forgot to subtract the row origin (and
        // came back as the raw table x) cannot pass.
        XCTAssertEqual(hit.1.y, 6, accuracy: 1.0)
        XCTAssertGreaterThanOrEqual(hit.1.x, 0)
        XCTAssertLessThanOrEqual(hit.1.x, 40,
                                 "the cell-local x cannot exceed the table-space x it came from")
    }

    /// A REAL click — routed through `window.sendEvent`, hit-tested to the table
    /// AppKit dispatches to, NOT `v.mouseDown(...)` directly — fires
    /// `onBlockClicked` with the clicked block. This is the regression guard for
    /// the dead-ancestor-override bug: the seam only counts if a genuine click
    /// reaches it.
    func testRealClickFiresOnBlockClicked() {
        let doc = MarkdownConverter.parse("First para.\n\nSecond para.\n\nThird para.")
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = makeTestWindow(width: 640, height: 480)
        window.contentView = v
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()

        var clicked: BlockID?
        var fireCount = 0
        v.onBlockClicked = { id, _ in clicked = id; fireCount += 1 }
        let row0H = v.rowHeightForTest(0)
        let winPoint = v.windowPointForTableY(CGPoint(x: 40, y: row0H + 6))
        dispatchRealClick(at: winPoint, in: window)
        // The interaction itself, not only its outcome: exactly one report. A seam
        // that never ran leaves this at 0; one that double-reports (the promote
        // path running twice) leaves it at 2, and either is a bug the id-equality
        // assertion alone would swallow.
        XCTAssertEqual(fireCount, 1,
                       "a real dispatched click must fire onBlockClicked EXACTLY once")
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
        let window = makeTestWindow(width: 640, height: 300)
        window.contentView = v
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()

        let target = 25
        v.scroll(to: doc.blocks[target].id)
        v.layoutSubtreeIfNeeded()

        // Anti-vacuity for the SCROLL half of the claim: the list must genuinely
        // have scrolled, and the target row must genuinely be inside the window.
        // Without this the test would still pass if `scroll(to:)` did nothing and
        // the click landed on row 25 sitting at its unscrolled position.
        XCTAssertGreaterThan(v.scrollOriginForTest.y, 0,
                             "precondition: scrolling to row \(target) moved the list")
        let rect = v.rowRectForTest(target)
        let winPoint = v.windowPointForTableY(CGPoint(x: 40, y: rect.midY))
        XCTAssertTrue((0...window.frame.height).contains(winPoint.y),
                      "precondition: row \(target) is inside the window "
                      + "(winY=\(winPoint.y) height=\(window.frame.height))")

        var clicked: BlockID?
        var fireCount = 0
        v.onBlockClicked = { id, _ in clicked = id; fireCount += 1 }
        dispatchRealClick(at: winPoint, in: window)
        XCTAssertEqual(fireCount, 1, "the click must actually have been delivered")
        XCTAssertEqual(clicked, doc.blocks[target].id,
                       "after scroll, a real click over row \(target) must resolve to blocks[\(target)]")
    }
}
#endif
