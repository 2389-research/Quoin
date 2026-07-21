#if canImport(AppKit)
import XCTest
import AppKit
@testable import QuoinRender

/// The selection popover (#45) is a floating toolbar anchored to a text
/// selection. Its placement math is a pure function so it can be pinned without
/// a live text view — these tests lock the four behaviors that matter: centered
/// over the selection, sitting just above it, flipping below near the top of the
/// document, and clamped inside the visible bounds. Coordinates are the text
/// view's flipped, top-left-origin space (smaller y is higher on screen).
final class SelectionToolbarGeometryTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
    private let barSize = CGSize(width: 220, height: SelectionToolbarView.height)

    func testCentersHorizontallyOverSelection() {
        let selection = CGRect(x: 260, y: 300, width: 80, height: 18)  // midX 300
        let frame = SelectionToolbarView.toolbarFrame(
            selectionRect: selection, barSize: barSize, inBounds: bounds)
        XCTAssertEqual(frame.midX, selection.midX, accuracy: 0.5)
    }

    func testSitsAboveSelectionByGap() {
        let gap: CGFloat = 8
        let selection = CGRect(x: 260, y: 300, width: 80, height: 18)
        let frame = SelectionToolbarView.toolbarFrame(
            selectionRect: selection, barSize: barSize, inBounds: bounds, gap: gap)
        // Above → the bar's bottom edge is `gap` above the selection's top.
        XCTAssertEqual(frame.maxY, selection.minY - gap, accuracy: 0.5)
        XCTAssertLessThan(frame.minY, selection.minY)
    }

    func testFlipsBelowWhenNoRoomAbove() {
        let gap: CGFloat = 8
        // Selection hugs the top: no room for the bar above it.
        let selection = CGRect(x: 260, y: 4, width: 80, height: 18)
        let frame = SelectionToolbarView.toolbarFrame(
            selectionRect: selection, barSize: barSize, inBounds: bounds, gap: gap)
        // Below → the bar's top edge is `gap` beneath the selection's bottom.
        XCTAssertEqual(frame.minY, selection.maxY + gap, accuracy: 0.5)
    }

    func testClampsWithinLeftEdge() {
        let selection = CGRect(x: 0, y: 300, width: 40, height: 18)  // midX 20
        let frame = SelectionToolbarView.toolbarFrame(
            selectionRect: selection, barSize: barSize, inBounds: bounds)
        XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX)
    }

    func testClampsWithinRightEdge() {
        let selection = CGRect(x: 580, y: 300, width: 40, height: 18)  // midX 600 (edge)
        let frame = SelectionToolbarView.toolbarFrame(
            selectionRect: selection, barSize: barSize, inBounds: bounds)
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX)
    }
}
#endif
