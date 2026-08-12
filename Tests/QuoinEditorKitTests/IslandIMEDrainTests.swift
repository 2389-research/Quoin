#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 3, Task 3: the activation intent parked in `.blockedIME` (Phase 2,
/// Task 5's IME refusal) is REPLAYED once the composition that blocked it
/// commits. Before this, `pendingIntent` was captured but never drained — a
/// click on a different block while composing was silently lost forever.
///
/// Headless, on a real recycler in an offscreen borderless window (same
/// recipe as `IslandControllerTests` / `IslandReconcileTests`). The
/// "composition" is simulated via `hasMarkedTextProbe` (the existing IME test
/// seam); the commit edge is driven through the REAL text-change path
/// (`islandTextView.insertText`), exactly as `IslandReconcileTests` does, so
/// the fan-out from `BlockEditorCell.onTextDidChange` through
/// `BlockRecyclerView.onEditingTextChanged` into
/// `IslandController.islandTextDidChange()` is exercised end to end.
@MainActor
final class IslandIMEDrainTests: XCTestCase {

    private func makeRecycler(_ md: String) -> (BlockRecyclerView, QuoinDocument, NSWindow) {
        let doc = MarkdownConverter.parse(md)
        let v = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = v
        window.makeKeyAndOrderFront(nil)
        v.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        v.setDocument(doc, contentWidth: 600)
        v.layoutSubtreeIfNeeded()
        return (v, doc, window)
    }

    /// activate(A) → begin composition (stub `hasMarkedText` true) → a
    /// keystroke marks `wasComposing` → `activate(B)` parks in `.blockedIME`
    /// with NO swap (A still active) → the composition commits (stub clears)
    /// → the commit keystroke fires the drain: the parked activation for B
    /// replays, flushing A EXACTLY ONCE and promoting B.
    ///
    /// Fix round 1: the commit edge used to unconditionally `reconcileNow()`
    /// (a KEEP flush of A) before draining, and the drain's own `activate(B)`
    /// then TERMINALLY flushed A again via `flushActiveIsland()` — the same
    /// block reconciled twice with identical content. In the real app both
    /// `onReconcile` firings become back-to-back applies against the same
    /// captured `baseRevision`; the first succeeds and bumps
    /// `contentRevision`, the second then fails the staleness check and
    /// surfaces a spurious "document changed underneath your typing" banner.
    /// This test counts `onReconcile` invocations to catch a regression back
    /// to the double-flush.
    func testParkedActivationReplaysWhenCompositionCommits() {
        let (v, doc, window) = makeRecycler("# Heading\n\nFirst para.\n\nSecond para.")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)

        var reconciledRanges: [ByteRange] = []
        var reconcileCount = 0
        controller.onReconcile = { range, _, _ in
            reconciledRanges.append(range)
            reconcileCount += 1
        }

        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)
        XCTAssertTrue(v.isEditingRow(0), "block A is the active island")

        // Begin composition: the stub makes `currentHasMarkedText()` report
        // true; a keystroke while it's true marks `wasComposing` (mirrors the
        // real IME mid-composition edge — the flush is parked, not fired).
        controller.hasMarkedTextProbe = { true }
        let cellA = v.editorCellForEditingRow()!
        let endA = cellA.islandTextView.string.utf16.count
        cellA.islandTextView.insertText("A", replacementRange: NSRange(location: endA, length: 0))
        XCTAssertTrue(reconciledRanges.isEmpty, "mid-composition must not flush")

        // A click into a DIFFERENT block while composing parks the intent —
        // per the Phase 2 IME-refusal contract, no swap happens.
        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        XCTAssertEqual(controller.state, .blockedIME(doc.blocks[1].id),
                       "the activation intent for block B parks, not swaps")
        XCTAssertEqual(controller.activeIsland?.originBlockID, doc.blocks[0].id,
                       "block A is still active — no swap happened")
        XCTAssertTrue(v.isEditingRow(0))
        XCTAssertFalse(v.isEditingRow(1), "block B was NOT promoted while composing")
        XCTAssertTrue(reconciledRanges.isEmpty, "IME refusal must not flush")

        // The composition commits: hasMarkedText clears. The commit keystroke
        // is the drain edge — since an activation is parked, it must skip the
        // KEEP reconcile and go straight to replaying the parked activation
        // for B, whose own terminal flush is the SOLE reconcile of A.
        controller.hasMarkedTextProbe = { false }
        let endA2 = cellA.islandTextView.string.utf16.count
        cellA.islandTextView.insertText("!", replacementRange: NSRange(location: endA2, length: 0))

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.activeIsland?.originBlockID, doc.blocks[1].id,
                       "the parked activation for block B replayed")
        XCTAssertTrue(v.isEditingRow(1), "block B is now the editable island")
        XCTAssertFalse(v.isEditingRow(0), "block A swapped back to read-only — it was flushed")
        XCTAssertEqual(reconcileCount, 1,
                       "block A is reconciled EXACTLY ONCE across the whole commit+drain — " +
                       "no duplicate KEEP-then-terminal flush")
        XCTAssertEqual(reconciledRanges.last?.offset, doc.blocks[0].range.offset,
                       "the single flush (the B swap's terminal flush) is for block A's byte range")
    }

    /// No composition, no click while blocked → nothing was ever parked, so
    /// an ordinary composition commit is a no-op for the drain (regression
    /// guard: the drain must not fire spuriously on every commit).
    func testCommitEdgeWithNothingParkedIsInert() {
        let (v, doc, window) = makeRecycler("# Heading\n\nFirst para.")
        defer { window.orderOut(nil) }
        let controller = IslandController(recycler: v)

        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero, in: doc, baseRevision: 0)

        controller.hasMarkedTextProbe = { true }
        let cell = v.editorCellForEditingRow()!
        let end = cell.islandTextView.string.utf16.count
        cell.islandTextView.insertText("A", replacementRange: NSRange(location: end, length: 0))

        controller.hasMarkedTextProbe = { false }
        let end2 = cell.islandTextView.string.utf16.count
        cell.islandTextView.insertText("!", replacementRange: NSRange(location: end2, length: 0))

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.activeIsland?.originBlockID, doc.blocks[0].id,
                       "block A stays active — nothing was parked to replay")
        XCTAssertTrue(v.isEditingRow(0))
    }
}
#endif
