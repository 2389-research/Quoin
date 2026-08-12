#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 2, Task 5: the `IslandController` + `SwapState` machine promotes exactly
/// ONE recycler row from the read-only `BlockRenderCell` to an editable
/// `BlockEditorCell` (the "island") on a click, seeds it with the block's raw
/// source, makes it first responder, places the caret, and reverses on blur.
///
/// These are headless state-machine transitions on a REAL recycler in an
/// offscreen borderless window (same recipe as `BlockRecyclerViewTests` /
/// `RecyclerClickTests`).
@MainActor
final class IslandControllerTests: XCTestCase {

    /// Offscreen recycler seeded with `md`, laid out, ready for activation.
    private func makeRecycler(_ md: String) -> (BlockRecyclerView, QuoinDocument, NSWindow) {
        let doc = MarkdownConverter.parse(md)
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = OffscreenTestWindow.make(width: 640, height: 480)
        window.contentView = v
        window.makeKeyAndOrderFront(nil)
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()
        return (v, doc, window)
    }

    // MARK: - Activation promotes exactly one row

    func testActivatePromotesExactlyOneRow() {
        let (v, doc, window) = makeRecycler("# Heading\n\nFirst para.\n\nSecond para.")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)

        controller.activate(blockID: doc.blocks[0].id,
                            localPoint: CGPoint(x: 4, y: 4), in: doc, baseRevision: 3)

        XCTAssertEqual(controller.state, .idle, "after the swap the machine settles idle")
        XCTAssertEqual(controller.activeIsland?.originBlockID, doc.blocks[0].id)
        XCTAssertEqual(controller.activeIsland?.baseRevision, 3,
                       "the island carries the activation's base revision")
        // Exactly ONE row is a BlockEditorCell.
        XCTAssertEqual(v.editingRowForTest, 0)
        XCTAssertTrue(v.isEditingRow(0), "the clicked row is the editable island")
        XCTAssertFalse(v.isEditingRow(1), "other rows stay read-only")
        XCTAssertFalse(v.isEditingRow(2))
    }

    /// The island's text view is first responder and seeded with the RAW block
    /// source (delimiters intact) — the heading `#` is present.
    func testActivateSeedsRawSourceAndFirstResponder() {
        let (v, doc, window) = makeRecycler("# Heading\n\nFirst para.")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)

        controller.activate(blockID: doc.blocks[0].id,
                            localPoint: CGPoint(x: 4, y: 4), in: doc, baseRevision: 0)

        let cell = v.editorCellForEditingRow()
        XCTAssertNotNil(cell)
        XCTAssertEqual(cell?.islandTextView.string, "# Heading",
                       "the island is seeded with the block's RAW source, delimiters intact")
        XCTAssertTrue(cell?.islandTextView == window.firstResponder,
                      "the island text view is first responder")
    }

    // MARK: - Editing row sizes from the live raw-source layout at activation

    /// A heading's RAW source (`# Heading`, monospace) lays out differently from
    /// its projected read height (large heading font). On activation — BEFORE any
    /// typing — the editing row must re-query height and size from the live island
    /// layout, or content below shifts on a click with no edit.
    func testHeadingIslandRowSizesFromLiveLayoutAtActivation() {
        let (v, doc, window) = makeRecycler("# Heading\n\nBody paragraph.")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)

        // The projected read height of the heading row, before any activation.
        let readHeight = v.rowHeightForTest(0)

        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)

        let cell = v.editorCellForEditingRow()
        XCTAssertNotNil(cell)
        let liveHeight = cell!.fittingHeightForConfiguredWidth + 2 * DecorationDraw.verticalBleed

        XCTAssertEqual(v.rowHeightForTest(0), liveHeight, accuracy: 0.5,
                       "the editing row is sized from the live island layout at activation")
        XCTAssertNotEqual(v.rowHeightForTest(0), readHeight, accuracy: 0.5,
                          "a heading's raw-source island height differs from its projected read height")
    }

    // MARK: - Swap flushes the previous island

    func testActivateWhileActiveFlushesPrevious() {
        let (v, doc, window) = makeRecycler("# Heading\n\nFirst para.\n\nSecond para.")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)

        var reconciledRanges: [ByteRange] = []
        controller.onReconcile = { range, _, _ in reconciledRanges.append(range) }

        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)
        XCTAssertTrue(reconciledRanges.isEmpty, "activating from idle flushes nothing")

        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        XCTAssertEqual(reconciledRanges.count, 1, "the previous island is flushed exactly once")
        XCTAssertEqual(reconciledRanges.first?.offset, doc.blocks[0].range.offset,
                       "the flush fires onReconcile for block1's byte range")
        XCTAssertEqual(reconciledRanges.first?.length, doc.blocks[0].range.length)

        XCTAssertEqual(controller.activeIsland?.originBlockID, doc.blocks[1].id,
                       "block2 is now the active island")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(v.isEditingRow(1), "block2's row is now the editable island")
        XCTAssertFalse(v.isEditingRow(0), "block1's row swapped back to read-only")
    }

    // MARK: - IME refusal

    func testMarkedTextRefusesSwap() {
        let (v, doc, window) = makeRecycler("# Heading\n\nFirst para.")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)

        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)

        // Stub marked text (mid-IME-composition) TRUE via the test seam.
        controller.hasMarkedTextProbe = { true }
        var reconciled = false
        controller.onReconcile = { _, _, _ in reconciled = true }

        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)

        XCTAssertEqual(controller.state, .blockedIME(doc.blocks[1].id),
                       "an active island with marked text parks the intent in .blockedIME")
        XCTAssertFalse(reconciled, "IME refusal must NOT flush the current island")
        XCTAssertEqual(controller.activeIsland?.originBlockID, doc.blocks[0].id,
                       "the original island stays active — no swap happened")
        XCTAssertTrue(v.isEditingRow(0), "block1 is still the island")
        XCTAssertFalse(v.isEditingRow(1), "block2 was NOT promoted")
    }

    // MARK: - Deactivate reverses the swap

    func testDeactivateReturnsRowToReadOnly() {
        let (v, doc, window) = makeRecycler("# Heading\n\nFirst para.")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)

        var reconciled = 0
        controller.onReconcile = { _, _, _ in reconciled += 1 }

        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)
        XCTAssertTrue(v.isEditingRow(0))

        controller.deactivate()
        XCTAssertEqual(reconciled, 1, "blur flushes the island once")
        XCTAssertNil(controller.activeIsland)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(v.isEditingRow(0), "the row swapped back to read-only")
        XCTAssertNil(v.editingRowForTest)
    }

    // MARK: - Recycling stays bounded with an active island

    func testRecyclingStaysBoundedWithActiveIsland() {
        let src = (0..<400).map { "Paragraph number \($0)." }.joined(separator: "\n\n")
        let (v, doc, window) = makeRecycler(src)
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)

        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)
        v.scroll(to: doc.blocks[399].id)
        v.layoutSubtreeIfNeeded()

        XCTAssertLessThan(v.visibleCellCount, 60,
                          "promoting one row to an island must not defeat recycling")
    }
}
#endif
