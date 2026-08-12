#if canImport(AppKit)
import XCTest
import AppKit
import SwiftUI
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 3 FALSIFIERS for the "click a block, the row jiggles and never becomes
/// editable" bug class (visible behind `-QuoinEditorRecycler YES`).
///
/// ## Why the existing tests were green while the app was broken (three times)
///
/// Every prior activation test asserts a FINAL STATE, at a moment of OUR
/// choosing, on a CLEAN bare-`NSView` table, with the mouseUp pre-queued. Three
/// properties of the real app are missing from that harness:
///
/// 1. **The bug is an OSCILLATION, not a wrong final state.** A row that grows,
///    shrinks, re-vends, and re-measures in a loop can still look "correct" at
///    the instant a test looks. Nothing counted the churn, so nothing saw it.
/// 2. **The table lives inside SwiftUI.** Under `NSHostingView` there is pending
///    layout at essentially every moment, so `reloadData(forRowIndexes:)` is
///    DEFERRED and COALESCES into a later pass; SwiftUI also re-evaluates the
///    representable on its own schedule. Headless, on a bare freshly-laid-out
///    table, the same call runs synchronously — the opposite regime.
/// 3. **The projection keeps re-applying underneath the island.**
///    `ReaderModel.scheduleAsyncContentRerender` bumps `rendered.revision` on a
///    120 ms debounce (image decodes etc.) with NO byte change, which re-runs
///    `BlockRecyclerReaderView.apply` while the island is live.
///
/// These tests close those gaps. The first two run through a REAL
/// `NSHostingView` — the app's actual hosting regime — and the rest drive the
/// bare seam in the specific state the app leaves it in. All of them use a real
/// key `NSWindow`, a real click dispatched through `window.sendEvent`, a REAL
/// `IslandController`, a PARAGRAPH block (prose is the priority path), and they
/// SPIN THE RUNLOOP afterwards, past both debounce windows, so deferred work
/// lands.
///
/// They are FALSIFIERS: a failure here is the deliverable, not a defect in the
/// test. Currently-failing cases carry `XCTExpectFailure` naming the bug, so the
/// suite stays green-and-actionable — when the seam is re-shaped the unexpected
/// PASS trips the strict expectation and the marker comes off.
///
/// ### Harness pitfall found while building this (do not "fix" it away)
///
/// A `.titled` window SWALLOWS the dispatched `leftMouseDown` entirely — no
/// `mouseDown` reaches the table, no activation, no counters move — while the
/// hit test at the same point correctly returns the cell. This is the CLAUDE.md
/// "first click into an inactive window is eaten by window activation" pitfall,
/// reproducible headlessly. Every window here is `.borderless` for that reason;
/// a future test that switches style mask will silently stop testing anything.
@MainActor
final class IslandActivationChurnTests: AppKitWindowTestCase {

    // MARK: - Harness

    /// Dispatch a genuine left click at `winPoint` through the window's real
    /// event path (mouseUp queued first so the table's `super.mouseDown`
    /// tracking loop finds its terminator instead of blocking).
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

    /// Let every DEFERRED consequence of the click land: commit pending layout,
    /// run the display pass, and spin the runloop so coalesced table work (and
    /// any timer / `Task` continuation) executes. The default window is ~700 ms —
    /// deliberately PAST both the 120 ms async-re-render debounce and the 200 ms
    /// reconcile debounce, because a loop driven by either would be invisible to
    /// the ~50 ms spin the older tests used.
    private func settle(_ root: NSView, in window: NSWindow, spins: Int = 14) {
        for _ in 0..<spins {
            root.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// The teardown seam from `IslandActivationSurvivesReloadTests`: re-fire the
    /// editing row's reload AFTER first responder is live — the same table op the
    /// app's `super.mouseDown` tracking-loop commit performs.
    private func commitDeferredReload(_ recycler: BlockRecyclerView) {
        recycler.reloadEditingRow()
        recycler.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    /// Window point over row `row`'s vertical middle (where a user's click
    /// actually lands), routed through the same scroll/flip transform a real
    /// click takes.
    private func windowPoint(forRow row: Int, in recycler: BlockRecyclerView) -> CGPoint {
        let rect = recycler.rowRectForTest(row)
        return recycler.windowPointForTableY(CGPoint(x: 40, y: rect.midY))
    }

    // MARK: Bare-seam harness (no SwiftUI)

    /// Real recycler + real `IslandController` in a KEY window, wired exactly as
    /// the app wires them (`onBlockClicked → controller.activate`).
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
        recycler.onBlockClicked = { [weak controller] blockID, point in
            controller?.activate(blockID: blockID, localPoint: point,
                                 in: doc, baseRevision: 0)
        }
        return (recycler, controller, doc, window)
    }

    // MARK: SwiftUI harness (the app's real hosting regime)

    /// The SwiftUI wrapper the app uses, so the recycler runs inside a genuine
    /// `NSHostingView`: pending layout is the steady state, `updateNSView` runs
    /// on SwiftUI's schedule, and the whole island wiring is built by
    /// `BlockRecyclerReaderView` itself rather than by the test.
    private struct RecyclerHost: View {
        let document: QuoinDocument
        let rendered: RenderedDocument
        let theme: Theme
        let renderer: AttributedRenderer
        var body: some View {
            BlockRecyclerReaderView(
                document: document,
                rendered: rendered,
                theme: theme,
                renderer: renderer,
                scrollTarget: nil,
                onTopBlockChange: nil,
                searchQuery: nil,
                onReconcile: { _, _ in document })
        }
    }

    /// Stand the recycler up INSIDE a real `NSHostingView` in a key window and
    /// dig the hosted `BlockRecyclerView` back out of SwiftUI's view tree.
    private func makeHostedStack(_ markdown: String) throws
        -> (recycler: BlockRecyclerView, controller: IslandController,
            doc: QuoinDocument, window: NSWindow, hosting: NSView)
    {
        let doc = MarkdownConverter.parse(markdown)
        let theme = Theme()
        let hosting = NSHostingView(rootView: RecyclerHost(
            document: doc,
            rendered: RenderedDocument(attributed: NSAttributedString(),
                                       blockRanges: [:], revision: 1),
            theme: theme,
            renderer: AttributedRenderer(theme: theme)))
        // `.borderless` is load-bearing — see the type comment.
        let window = makeTestWindow(width: 640, height: 480)
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let recycler = try XCTUnwrap(Self.findRecycler(hosting),
                                     "no BlockRecyclerView inside the hosting view")
        let controller = try XCTUnwrap(recycler.islandControllerForTest,
                                       "BlockRecyclerReaderView did not install an IslandController")
        return (recycler, controller, doc, window, hosting)
    }

    private static func findRecycler(_ view: NSView) -> BlockRecyclerView? {
        if let recycler = view as? BlockRecyclerView { return recycler }
        for sub in view.subviews {
            if let found = findRecycler(sub) { return found }
        }
        return nil
    }

    // MARK: - 1. Anti-oscillation

    /// THE KEY FALSIFIER. One click on a PARAGRAPH — inside a real
    /// `NSHostingView` — must promote its row to an island ONCE and settle. Not
    /// "end up correct" at some chosen instant: *settle*. Exactly one
    /// editor-cell vend for that row, no read-cell re-vend of that row after the
    /// promotion, a bounded number of height queries, and no grow/shrink
    /// reversal in the heights the table asked for. This catches the jiggle
    /// regardless of which mechanism causes it.
    ///
    /// ### Why the bound is 6
    ///
    /// A single activation legitimately touches the clicked row's height four
    /// times: (1) the `editingBlockID` setter's `reloadData(forRowIndexes:)`
    /// re-measures the row; (2) `drainPendingEditingReload()`'s
    /// `layoutSubtreeIfNeeded` commits that reload; (3) `noteEditingRowHeight()`
    /// invalidates the row so it re-sizes off the LIVE island layout instead of
    /// the read projection; (4) the settling display pass commits (3). Two more
    /// are slack for AppKit's own visible-range recompute. An oscillation is a
    /// LOOP — over a ~700 ms observation window it blows past six by a wide
    /// margin — so the bound separates "activation did its four pieces of work"
    /// from "the row is churning", without being tuned to any observed number.
    func testOneClickVendsTheIslandOnceAndSettles() throws {
        let (recycler, controller, doc, window, hosting) =
            try makeHostedStack("First para.\n\nSecond para.\n\nThird para.")

        let clickedRow = 1
        let clickedBlockID = doc.blocks[clickedRow].id
        let point = windowPoint(forRow: clickedRow, in: recycler)

        recycler.resetChurnCountersForTest()
        dispatchRealClick(at: point, in: window)
        settle(hosting, in: window)

        let editorVends = recycler.editorCellVendsByRowForTest[clickedRow] ?? 0
        let renderVends = recycler.renderCellVendsByRowForTest[clickedRow] ?? 0
        let heights = recycler.heightQueriesByRowForTest[clickedRow] ?? []

        let trace = """
            editorVends=\(editorVends) renderVends=\(renderVends) \
            heightQueries=\(heights.count) heights=\(heights.map { ($0 * 10).rounded() / 10 }) \
            editingBlockID=\(recycler.editingBlockID.map { "\($0)" } ?? "nil") \
            activeIsland=\(controller.activeIsland != nil)
            """

        XCTAssertEqual(editorVends, 1,
                       "one click must vend the editor cell for row \(clickedRow) EXACTLY once — \(trace)")
        XCTAssertEqual(renderVends, 0,
                       "the clicked row must not fall back to a read cell after promotion — \(trace)")
        // Anti-vacuity: a bound of "at most 6" would also pass if the counter
        // never fired at all (the exact way the previous three tests were green
        // while broken). Prove the height instrument is live before trusting it.
        XCTAssertGreaterThanOrEqual(heights.count, 1,
                                    "the height instrument must actually observe the clicked row — \(trace)")
        XCTAssertLessThanOrEqual(heights.count, 6,
                                 "the clicked row's height must be queried a bounded number of times — \(trace)")
        XCTAssertFalse(Self.hasGrowShrinkReversal(heights),
                       "the clicked row's height must not grow then shrink (the visible jiggle) — \(trace)")
        XCTAssertEqual(recycler.editingBlockID, clickedBlockID,
                       "the clicked block is the one that ends up editable — \(trace)")
    }

    /// A grow→shrink (or shrink→grow) reversal in the height sequence: the
    /// literal, user-visible jiggle. A monotone settle (read height → island
    /// height, possibly repeated) is fine; a reversal is not. Sub-half-point
    /// wobble is rounding, not motion.
    private static func hasGrowShrinkReversal(_ heights: [CGFloat]) -> Bool {
        var lastDirection = 0
        for (a, b) in zip(heights, heights.dropFirst()) {
            let delta = b - a
            guard abs(delta) > 0.5 else { continue }
            let direction = delta > 0 ? 1 : -1
            if lastDirection != 0 && direction != lastDirection { return true }
            lastDirection = direction
        }
        return false
    }

    // MARK: - 2. Row-geometry stability

    /// The recycler's analogue of `CaretLineAnchorTests` — the CLAUDE.md
    /// viewport invariant ("on ANY projection change the line the caret/click is
    /// on must not move on screen") is otherwise UNENFORCED on the new editor.
    ///
    /// Run inside the hosting view, scrolled into the body of the document (at
    /// origin, a bug that scrolls to top is invisible). A click must not scroll
    /// and must not move the clicked row under the pointer. Epsilon is 4 pt, the
    /// spec's drift target: under one line of body text, so any real
    /// reflow-under-the-caret trips it while sub-pixel rounding does not.
    ///
    /// Phase 3: extended to cover the PROMOTE path explicitly — the click must
    /// actually have promoted the row (otherwise "nothing moved" is vacuous), and
    /// every height/reload op in the swap must have run at zero animation duration
    /// (spec §4 steps 3/6: an animated height flip IS the jiggle).
    func testClickDoesNotMoveTheClickedRowOnScreen() throws {
        let (recycler, controller, doc, window, hosting) = try makeHostedStack(
            (0..<40).map { "Paragraph number \($0)." }.joined(separator: "\n\n"))

        recycler.scroll(to: doc.blocks[20].id)
        settle(hosting, in: window, spins: 2)
        recycler.resetChurnCountersForTest()

        // The row must actually be ON SCREEN. The original version of this test
        // hard-coded row 22 after scrolling row 20 into view — which lands BELOW the
        // window (window-space y of -30.6), so the click hit nothing and "the row
        // did not move" was vacuously true. Pick a row whose whole rect is inside
        // the window instead, and assert below that the click really promoted it.
        let clickedRow = try XCTUnwrap(
            (0..<40).first { row in
                let rect = recycler.rowRectForTest(row)
                let top = recycler.windowPointForTableY(CGPoint(x: 0, y: rect.minY)).y
                let bottom = recycler.windowPointForTableY(CGPoint(x: 0, y: rect.maxY)).y
                return min(top, bottom) > 8 && max(top, bottom) < window.frame.height - 8
            },
            "no row is fully visible after the scroll")
        let beforeScrollOrigin = recycler.scrollOriginForTest
        let beforeRowRect = recycler.rowRectForTest(clickedRow)
        let beforeRowTopInWindow =
            recycler.windowPointForTableY(CGPoint(x: 0, y: beforeRowRect.minY)).y
        // Phase 3: the row BELOW the click, measured directly (not derived) —
        // it is the one that slides when the island is a different height than
        // the read cell it replaced.
        let nextRow = clickedRow + 1
        let beforeNextTopInWindow =
            recycler.windowPointForTableY(CGPoint(x: 0, y: recycler.rowRectForTest(nextRow).minY)).y
        let point = windowPoint(forRow: clickedRow, in: recycler)

        dispatchRealClick(at: point, in: window)
        settle(hosting, in: window)

        let afterScrollOrigin = recycler.scrollOriginForTest
        let afterRowRect = recycler.rowRectForTest(clickedRow)
        let afterRowTopInWindow =
            recycler.windowPointForTableY(CGPoint(x: 0, y: afterRowRect.minY)).y

        let trace = """
            scrollOrigin \(NSStringFromPoint(beforeScrollOrigin))→\(NSStringFromPoint(afterScrollOrigin)) \
            rowRect \(NSStringFromRect(beforeRowRect))→\(NSStringFromRect(afterRowRect)) \
            rowTopInWindow \(beforeRowTopInWindow)→\(afterRowTopInWindow)
            """

        XCTAssertEqual(afterScrollOrigin.y, beforeScrollOrigin.y, accuracy: 0.5,
                       "activating a block must not scroll the list — \(trace)")
        XCTAssertEqual(afterRowTopInWindow, beforeRowTopInWindow, accuracy: 4.0,
                       "the clicked row must not move on screen (viewport invariant) — \(trace)")
        // Anti-vacuity + promote-path coverage: the click really did promote, and
        // the swap's height work was unanimated.
        XCTAssertEqual(recycler.editingBlockID, doc.blocks[clickedRow].id,
                       "the click must have promoted the clicked row — \(trace)")
        XCTAssertNotNil(controller.activeIsland, "…with a live island — \(trace)")
        XCTAssertFalse(recycler.animationDurationsForTest.isEmpty,
                       "the promote must have run height work — \(trace)")
        XCTAssertTrue(recycler.animationDurationsForTest.allSatisfy { $0 == 0 },
                      "the read↔island height flip must not animate — "
                      + "durations=\(recycler.animationDurationsForTest) \(trace)")

        // Phase 3 (island source styling): the clicked row's TOP not moving is
        // only half the viewport invariant. If the island is a different height
        // than the read cell it replaced, everything BELOW the click slides —
        // which is exactly what the user reported ("doesn't preserve the
        // layout") and what an unstyled mono island, or an editing row that
        // dropped its separator contribution, both cause. The row must keep its
        // own height AND the next row must stay where it was.
        //
        // 1pt, not the row-top assertion's 4pt: both quantities here are
        // deterministic row arithmetic, and the prose→prose separator
        // contribution this guards is only 2.0pt (measured) — a 4pt budget
        // swallows it whole and the assertion is vacuous.
        XCTAssertEqual(afterRowRect.height, beforeRowRect.height, accuracy: 1.0,
                       "edit mode must keep the block's vertical skeleton — "
                       + "rowHeight \(beforeRowRect.height)→\(afterRowRect.height) \(trace)")
        let afterNextTopInWindow =
            recycler.windowPointForTableY(CGPoint(x: 0, y: recycler.rowRectForTest(nextRow).minY)).y
        XCTAssertEqual(afterNextTopInWindow, beforeNextTopInWindow, accuracy: 1.0,
                       "the row BELOW the click must not slide — "
                       + "nextTop \(beforeNextTopInWindow)→\(afterNextTopInWindow) \(trace)")
    }

    // MARK: - 3. Dirty-table activation survival

    /// THE HARNESS-GAP CLOSER for `IslandActivationSurvivesReloadTests`, which
    /// runs on a CLEAN, freshly laid-out table where `reloadData(forRowIndexes:)`
    /// executes synchronously inside `drainPendingEditingReload()`. In the app
    /// the table has pending layout essentially all the time, so the very same
    /// reload COALESCES into a later pass — the regime the Phase-3 hotfix was
    /// never tested in.
    ///
    /// The table is dirtied BEFORE the click: pending layout on the table AND on
    /// its host, plus a column resize, which invalidates every row's geometry the
    /// way a hosting-view resize does. The survival assertions then run twice —
    /// once after the coalesced work lands naturally, and once after the explicit
    /// editing-row reload that models the app's tracking-loop commit.
    func testActivationSurvivesOnADirtyTable() {
        let (recycler, controller, doc, window) =
            makeStack("First para.\n\nSecond para.\n\nThird para.")

        let clickedRow = 1
        let clickedBlockID = doc.blocks[clickedRow].id
        let point = windowPoint(forRow: clickedRow, in: recycler)

        // DIRTY the table the way NSHostingView leaves it: pending layout plus a
        // geometry change that invalidates every row.
        let table = recycler.tableViewForTest
        table.tableColumns.first?.width += 1
        table.needsLayout = true
        table.needsDisplay = true
        recycler.needsLayout = true

        dispatchRealClick(at: point, in: window)
        settle(recycler, in: window, spins: 4)

        assertIslandSurvives(recycler: recycler, controller: controller, window: window,
                             clickedBlockID: clickedBlockID,
                             phase: "after the coalesced reload landed")

        commitDeferredReload(recycler)

        assertIslandSurvives(recycler: recycler, controller: controller, window: window,
                             clickedBlockID: clickedBlockID,
                             phase: "after the tracking-loop reload commit")
    }

    private func assertIslandSurvives(
        recycler: BlockRecyclerView, controller: IslandController, window: NSWindow,
        clickedBlockID: BlockID, phase: String
    ) {
        let island = recycler.currentEditorCell?.islandTextView
        let fr = window.firstResponder
        let trace = """
            \(phase): editingBlockID=\(recycler.editingBlockID.map { "\($0)" } ?? "nil") \
            activeIsland=\(controller.activeIsland != nil) \
            firstResponder=\(fr.map { String(describing: type(of: $0)) } ?? "nil")
            """
        XCTAssertNotNil(controller.activeIsland, "the island survives — \(trace)")
        XCTAssertEqual(recycler.editingBlockID, clickedBlockID,
                       "the clicked row stays the editable island — \(trace)")
        XCTAssertNotNil(island, "the editing cell still hosts an island text view — \(trace)")
        XCTAssertTrue(fr === island, "the island keeps window first responder — \(trace)")
    }

    // MARK: - 4. SwiftUI seam / projection-revision re-apply

    /// `ReaderModel.scheduleAsyncContentRerender` bumps `rendered.revision` on a
    /// 120 ms debounce (image decodes and friends) with NO byte change — so
    /// `BlockRecyclerReaderView.apply` re-runs against an IDENTICAL document
    /// while an island is live. That is the exact shape reproduced here, with no
    /// app needed.
    ///
    /// The island must survive a content-free revision bump: the SAME first
    /// responder object (not a rebuilt one), the same editing block, the same row
    /// rect. If it did not, every async re-render would be an island teardown —
    /// which reads to a user as a click that "doesn't take".
    func testIslandSurvivesAContentFreeRevisionBump() throws {
        let doc = MarkdownConverter.parse("First para.\n\nSecond para.\n\nThird para.")
        let coordinator = BlockRecyclerReaderView.Coordinator()
        let theme = Theme()
        let renderer = AttributedRenderer(theme: theme)

        func repr(revision: Int) -> BlockRecyclerReaderView {
            BlockRecyclerReaderView(
                document: doc,
                rendered: RenderedDocument(attributed: NSAttributedString(),
                                           blockRanges: [:], revision: revision),
                theme: theme,
                renderer: renderer,
                scrollTarget: nil,
                onTopBlockChange: nil,
                searchQuery: nil)
        }

        let recycler = repr(revision: 1).makeRecycler(coordinator: coordinator)
        let window = makeTestWindow(width: 640, height: 480)
        window.contentView = recycler
        recycler.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        // Re-seed at the REAL laid-out width, so the later re-apply differs ONLY
        // in `revision` (an unchanged width is what isolates the revision bump).
        repr(revision: 1).apply(to: recycler, coordinator: coordinator, initial: true)
        recycler.layoutSubtreeIfNeeded()

        let clickedRow = 1
        let clickedBlockID = doc.blocks[clickedRow].id
        dispatchRealClick(at: windowPoint(forRow: clickedRow, in: recycler), in: window)
        settle(recycler, in: window, spins: 4)

        let controller = try XCTUnwrap(coordinator.islandController)
        XCTAssertNotNil(controller.activeIsland, "precondition: the click produced a live island")
        XCTAssertEqual(recycler.editingBlockID, clickedBlockID,
                       "precondition: the clicked row is the island")
        let beforeResponder = window.firstResponder
        let beforeRowRect = recycler.rowRectForTest(clickedRow)
        XCTAssertTrue(beforeResponder === recycler.currentEditorCell?.islandTextView,
                      "precondition: the island holds first responder")

        // The async projection re-render: identical document, bumped revision.
        repr(revision: 2).apply(to: recycler, coordinator: coordinator, initial: false)
        settle(recycler, in: window, spins: 4)

        let afterResponder = window.firstResponder
        let afterRowRect = recycler.rowRectForTest(clickedRow)
        let trace = """
            editingBlockID=\(recycler.editingBlockID.map { "\($0)" } ?? "nil") \
            activeIsland=\(controller.activeIsland != nil) \
            responder \(beforeResponder.map { String(describing: type(of: $0)) } ?? "nil")\
            →\(afterResponder.map { String(describing: type(of: $0)) } ?? "nil") \
            sameObject=\(afterResponder === beforeResponder) \
            rowRect \(NSStringFromRect(beforeRowRect))→\(NSStringFromRect(afterRowRect))
            """

        XCTAssertNotNil(controller.activeIsland,
                        "a content-free revision bump must not tear the island down — \(trace)")
        XCTAssertEqual(recycler.editingBlockID, clickedBlockID,
                       "the editing block is unchanged across the re-apply — \(trace)")
        XCTAssertTrue(afterResponder === beforeResponder,
                      "first responder is the SAME island text view (not a rebuilt one) — \(trace)")
        XCTAssertEqual(afterRowRect.origin.y, beforeRowRect.origin.y, accuracy: 4.0,
                       "the editing row does not move across the re-apply — \(trace)")
        XCTAssertEqual(afterRowRect.height, beforeRowRect.height, accuracy: 1.0,
                       "the editing row does not resize across the re-apply — \(trace)")
    }

    // MARK: - 5. Island width drift across a re-apply (found while building 1–4)

    /// The projection-revision test's sibling, and the one defect this sweep
    /// actually caught: a re-apply at a DIFFERENT WIDTH (any window/sidebar
    /// resize while an island is live) re-frames the editing row but never
    /// re-`configure`s the live `BlockEditorCell`.
    ///
    /// `updateDocumentPreservingEditing`'s KEEP path deliberately spares the
    /// editing row from `reloadData(forRowIndexes:)` so first responder and caret
    /// survive — but `configure(slice:blockID:width:)`, which sets the island's
    /// `NSTextContainer` width, is only ever called from `editorView(for:)`, i.e.
    /// from that very reload. So the island keeps laying its text out at the OLD
    /// column while its cell is framed at the NEW one, and
    /// `fittingHeightForConfiguredWidth` — which `rowHeight(atRow:)` uses for the
    /// editing row — reports a height measured at a width the cell no longer has.
    /// A two-step width settle (exactly what `NSHostingView` does on open/resize)
    /// therefore mis-sizes the open island: the grow/shrink signature.
    ///
    /// The assertion is constant-free: whatever the cell's width delta is, the
    /// island's text container must move by the same amount.
    ///
    /// FIXED (Phase 3, click-seam re-shape): `updateDocumentPreservingEditing` now
    /// calls `updateEditingCellWidth(_:)` → `BlockEditorCell.updateWidth(_:)`, which
    /// re-lays the LIVE island at the new column WITHOUT re-vending it and WITHOUT
    /// re-seeding its text (the island's text is authoritative — re-seeding from the
    /// document here would drop unflushed keystrokes). The `XCTExpectFailure` that
    /// used to head this test is gone; it must now genuinely pass.
    func testIslandTextContainerTracksWidthAcrossAReapply() throws {
        let doc = MarkdownConverter.parse(
            "First para.\n\nSecond paragraph with enough words that the column width "
            + "genuinely decides how many lines it wraps to.\n\nThird para.")
        let theme = Theme()
        let hosting = NSHostingView(rootView: RecyclerHost(
            document: doc,
            rendered: RenderedDocument(attributed: NSAttributedString(),
                                       blockRanges: [:], revision: 1),
            theme: theme,
            renderer: AttributedRenderer(theme: theme)))
        let window = makeTestWindow(width: 640, height: 480)
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let recycler = try XCTUnwrap(Self.findRecycler(hosting))
        let clickedRow = 1
        dispatchRealClick(at: windowPoint(forRow: clickedRow, in: recycler), in: window)
        settle(hosting, in: window, spins: 4)

        let cellBefore = try XCTUnwrap(recycler.currentEditorCell,
                                       "precondition: the click produced a live editor cell")
        let containerBefore = try XCTUnwrap(cellBefore.islandTextView.textContainer).size.width
        let cellWidthBefore = cellBefore.frame.width

        // The resize: exactly what a sidebar toggle or window resize does. The
        // rootView reassignment is the benign SwiftUI re-evaluation that always
        // accompanies it in the app (any `ReaderModel` publish) — it is what
        // drives `updateNSView` → `apply` → the width branch. Without it a bare
        // frame change never reaches the representable, which is why this bug
        // needs the SwiftUI seam to reproduce at all.
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 480)
        hosting.rootView = RecyclerHost(
            document: doc,
            rendered: RenderedDocument(attributed: NSAttributedString(),
                                       blockRanges: [:], revision: 1),
            theme: theme,
            renderer: AttributedRenderer(theme: theme))
        settle(hosting, in: window, spins: 4)

        let cellAfter = try XCTUnwrap(recycler.currentEditorCell,
                                      "the island survives the resize")
        let containerAfter = try XCTUnwrap(cellAfter.islandTextView.textContainer).size.width
        let cellWidthAfter = cellAfter.frame.width

        let trace = """
            containerWidth \(containerBefore)→\(containerAfter) \
            cellWidth \(cellWidthBefore)→\(cellWidthAfter) \
            rowRect=\(NSStringFromRect(recycler.rowRectForTest(clickedRow)))
            """
        XCTAssertNotEqual(cellWidthAfter, cellWidthBefore, accuracy: 0.5,
                          "precondition: the resize actually re-framed the editing cell — \(trace)")
        XCTAssertEqual(containerAfter - containerBefore, cellWidthAfter - cellWidthBefore,
                       accuracy: 0.5,
                       "the island's text container must track the cell's width — \(trace)")
    }
}
#endif
