#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// **The recycler's `CaretLineAnchorTests` analogue** (I5). The projection editor
/// has enforced CLAUDE.md's viewport invariant — *"on ANY projection change —
/// reveal, close, keystroke, for every block type — the line the caret/click is on
/// must not move on screen… scroll only when the caret leaves the viewport, then
/// minimally"* — with `RevealFidelityTests` + `CaretLineAnchorTests` since the
/// projection reader shipped. The recycler had the freeze/unfreeze on exactly ONE
/// path (`promoteRow`, commit 75f697f) and no geometry test at all; that absence
/// is why the close and structural paths shipped unprotected.
///
/// Every test here measures the caret row's WINDOW-SPACE top (the row's
/// document-space rect put through the live scroll transform — the same
/// conversion a real click takes) plus the clip view's scroll origin, with the
/// caret's row parked MID-VIEWPORT, which is the only place the invariant is
/// observable: a row pinned to the top of the viewport cannot move for free.
///
/// ## Anti-vacuity discipline (this suite has already shipped 5 vacuous tests)
///
/// Every geometry assertion here is paired with BOTH:
///  • a **mutation assert** — the row heights genuinely changed / the row count
///    genuinely changed / the island genuinely survived — so "nothing moved"
///    can never be satisfied by "nothing happened"; and
///  • a **falsifier**, either a companion test that runs the same interaction with
///    `disableViewportAnchorForTest` (and, for the KEEP path,
///    `wipeSettledHeightsOnRefreshForTest`) and asserts the movement the anchor is
///    preventing, or — where the path provably cannot move the caret row — a
///    positive control on a neighbouring row, so a dead instrument fails the test.
///
/// Measured pre-fix movements are recorded in the per-test comments.
@MainActor
final class RecyclerViewportAnchorTests: AppKitWindowTestCase {

    // MARK: - Harness

    private func makeStack(_ md: String, renderer: AttributedRenderer = AttributedRenderer())
        -> (recycler: BlockRecyclerView, doc: QuoinDocument, controller: IslandController)
    {
        let doc = MarkdownConverter.parse(md)
        let recycler = BlockRecyclerView(renderer: renderer, theme: Theme())
        let window = makeTestWindow(width: 640, height: 480)
        window.contentView = recycler
        recycler.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        recycler.setDocument(doc, contentWidth: 600)
        recycler.layoutSubtreeIfNeeded()
        let controller = IslandController(recycler: recycler)
        return (recycler, doc, controller)
    }

    private static func paragraph(_ i: Int) -> String {
        "Paragraph \(i) with enough words in it to wrap across a couple of lines in a six hundred point column."
    }

    /// Park `row` in the MIDDLE of the viewport and prove it is really there —
    /// a row at the very top of the viewport is immune to the movement this
    /// suite measures, so the placement is an assertion, not a convenience.
    private func parkMidViewport(_ v: BlockRecyclerView, row: Int,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let rect = v.rowRectForTest(row)
        v.setScrollOriginForTest(max(0, rect.midY - v.visibleDocumentRectForTest.height / 2))
        v.layoutSubtreeIfNeeded()
        let visible = v.visibleDocumentRectForTest
        let placed = v.rowRectForTest(row)
        XCTAssertGreaterThan(placed.minY, visible.minY + 40,
                             "row \(row) must sit clear of the viewport top for the measurement to mean anything",
                             file: file, line: line)
        XCTAssertLessThan(placed.maxY, visible.maxY - 40,
                          "row \(row) must sit clear of the viewport bottom",
                          file: file, line: line)
    }

    /// The stub reconcile the structural test uses: apply the `SourceEdit` through
    /// the REAL incremental parse and hand the document back, exactly as
    /// `IslandBackspaceMergeTests` does.
    private func installReconcileStub(_ controller: IslandController,
                                      startingFrom doc: QuoinDocument) -> () -> QuoinDocument {
        final class Box { var doc: QuoinDocument; init(_ d: QuoinDocument) { doc = d } }
        let box = Box(doc)
        controller.onReconcile = { [weak controller] range, newText, caret in
            let edit = SourceEdit(range: range, replacement: newText)
            let result = try! MarkdownConverter.parseAfterEdit(previous: box.doc, edit: edit)
            box.doc = result.document
            let caretDocByte = IslandCaretMapping.documentByte(
                localUTF16: caret, islandSource: newText, islandByteStart: range.offset)
            controller?.applyReconciled(result.document, caretDocByte: caretDocByte)
        }
        return { box.doc }
    }

    // MARK: - 1. CLOSE (the path CLAUDE.md names explicitly)

    /// Deactivating a mid-viewport island must (a) actually put the row back to its
    /// READ height and (b) leave that row exactly where it was on screen.
    ///
    /// The block is a fenced CODE block because its island projection (raw source,
    /// fences included) is genuinely taller than its read projection: 125.0 pt vs
    /// 98.08 pt at a 600 pt column. A heading is NOT a usable subject — measured,
    /// its styled island source and its read projection are both 41.9 pt, so the
    /// close would have nothing to re-size and the test would prove nothing.
    ///
    /// ### What was broken, measured
    ///
    /// `demoteEditingRow` reloaded the row and stopped. `reloadData(forRowIndexes:)`
    /// re-vends a row's VIEW but never re-asks its HEIGHT, so the row stayed at
    /// **125.0 pt** (the island height) with a 98.08 pt read cell drawn into it —
    /// a 26.9 pt hole — until some unrelated later pass re-measured it. That
    /// detached, delayed collapse is the "content below jumps" report.
    ///
    /// ### On the anchor for this path
    ///
    /// Measured with `disableViewportAnchorForTest`: the closing row's own screen
    /// position moves **0.0 pt** with or without the anchor, and so does the scroll
    /// origin — necessarily, because the only geometry a close changes is the
    /// closing row's own height, and a row's TOP is unaffected by its own height.
    /// The anchor on this path is therefore defensive (it shares the one helper
    /// with the paths that need it); the falsifier that keeps THIS test honest is
    /// the positive control below — the row BELOW must move up by exactly the
    /// shrink, so a dead measurement instrument fails the test.
    func testClosingAnIslandReSizesTheRowAndDoesNotMoveIt() throws {
        var parts = (0..<6).map(Self.paragraph)
        parts.append("```swift\nlet x = 1\nlet y = 2\n```")
        parts.append(contentsOf: (6..<14).map(Self.paragraph))
        let (v, doc, controller) = makeStack(parts.joined(separator: "\n\n"))
        let codeRow = 6
        guard case .codeBlock = doc.blocks[codeRow].kind else {
            return XCTFail("row \(codeRow) must be the fenced code block")
        }
        parkMidViewport(v, row: codeRow)

        controller.activate(blockID: doc.blocks[codeRow].id, localPoint: .zero,
                            in: doc, baseRevision: 0)
        v.layoutSubtreeIfNeeded()
        XCTAssertTrue(v.isEditingRow(codeRow), "the island must be open on the code row")

        let islandHeight = v.rowRectForTest(codeRow).height
        let topBefore = v.rowTopInWindowForTest(codeRow)
        let originBefore = v.scrollOriginForTest
        let belowBefore = v.rowTopInWindowForTest(codeRow + 1)

        controller.deactivate()
        v.layoutSubtreeIfNeeded()

        let readHeight = v.rowRectForTest(codeRow).height
        let topAfter = v.rowTopInWindowForTest(codeRow)
        let originAfter = v.scrollOriginForTest
        let belowAfter = v.rowTopInWindowForTest(codeRow + 1)
        let trace = "islandHeight=\(islandHeight) readHeight=\(readHeight) "
            + "top=\(topBefore)→\(topAfter) origin=\(originBefore)→\(originAfter) "
            + "below=\(belowBefore)→\(belowAfter)"

        // MUTATION: the close really happened — the row is read-only again AND the
        // TABLE's row height (not just the delegate's answer) came back down.
        XCTAssertFalse(v.isEditingRow(codeRow), "the row must be read-only again — \(trace)")
        XCTAssertEqual(readHeight, v.rowHeightForTest(codeRow), accuracy: 0.5,
                       "the table's row height must equal the read height it now asks for — \(trace)")
        XCTAssertLessThan(readHeight, islandHeight - 10,
                          "the close must genuinely shrink the row (pre-fix it stayed at the island height) — \(trace)")

        // INVARIANT: the caret's row has not moved, and nothing scrolled.
        XCTAssertEqual(topAfter, topBefore, accuracy: 1,
                       "the closed row must not move on screen — \(trace)")
        XCTAssertEqual(originAfter.y, originBefore.y, accuracy: 1,
                       "closing must not scroll — \(trace)")

        // POSITIVE CONTROL (anti-vacuity for the measurement itself): the row below
        // MUST move up by exactly the shrink. If the instrument were dead, this
        // fails.
        // (Window space is bottom-up, so "risen on screen" is an INCREASE in y.)
        let shrink = islandHeight - readHeight
        XCTAssertEqual(belowAfter - belowBefore, shrink, accuracy: 1,
                       "the row below must rise by exactly the shrink — \(trace)")
    }

    // MARK: - 2. STRUCTURAL (Backspace-merge)

    /// A Backspace-merge removes a row; the caret's row afterwards is the
    /// PREDECESSOR's row (the merged block), whose content did not move in the
    /// document. It must not move on screen either, and the viewport must not
    /// scroll.
    ///
    /// ### Measured pre-fix: **33.5 pt**
    ///
    /// `reconcileRowCountKeepingEditing`'s `removeRows` makes AppKit adjust the
    /// clip view itself: the scroll origin went `(0, 82.8) → (0, 49.3)` and the
    /// caret's row jumped from window y 329.4 to 295.9 — the whole viewport
    /// lurched by the removed row's height. `testStructuralMergeJumpsWithoutTheAnchor`
    /// is that number as an executable falsifier.
    func testStructuralMergeKeepsTheCaretRowStill() throws {
        try runStructuralMerge(anchored: true)
    }

    /// FALSIFIER for the test above: same interaction, anchor neutered. The
    /// movement must be REAL and LARGE (measured 33.5 pt), which is what proves
    /// the zero asserted above is earned.
    func testStructuralMergeJumpsWithoutTheAnchor() throws {
        try runStructuralMerge(anchored: false)
    }

    private func runStructuralMerge(anchored: Bool) throws {
        let md = (0..<10).map(Self.paragraph).joined(separator: "\n\n")
        let (v, doc, controller) = makeStack(md)
        let currentDoc = installReconcileStub(controller, startingFrom: doc)
        let islandRow = 5
        parkMidViewport(v, row: islandRow)

        controller.activate(blockID: doc.blocks[islandRow].id, localPoint: .zero,
                            in: doc, baseRevision: 0)
        v.layoutSubtreeIfNeeded()
        let cell = try XCTUnwrap(v.editorCellForEditingRow())
        cell.islandTextView.setSelectedRange(NSRange(location: 0, length: 0))

        let originBefore = v.scrollOriginForTest
        // The row the caret will be on AFTER the merge is the PREDECESSOR's row —
        // the merged block starts where it started — so that is the row whose
        // screen position must be unchanged.
        let caretRowTopBefore = v.rowTopInWindowForTest(islandRow - 1)
        let rowsBefore = v.numberOfRowsForTest

        let harness = EditorTestHarness(adopting: cell.islandTextView, appliedRevision: { 0 })
        harness.pressBackspace()
        controller.flushPendingReconcile()

        v.disableViewportAnchorForTest = !anchored
        // The app's refresh seam (`BlockRecyclerReaderView.apply`) for the document
        // the merge produced.
        v.updateDocumentPreservingEditing(
            currentDoc(), contentWidth: 600,
            islandStartByte: controller.activeIsland?.byteRange.lowerBound)
        v.layoutSubtreeIfNeeded()

        // MUTATION: the merge really happened and the island really survived it.
        XCTAssertEqual(currentDoc().blocks.count, rowsBefore - 1,
                       "the merge must remove a block")
        XCTAssertEqual(v.numberOfRowsForTest, rowsBefore - 1,
                       "the table must have one row fewer")
        let newEditingRow = try XCTUnwrap(v.editingRowForTest, "the island must survive the merge")
        XCTAssertEqual(newEditingRow, islandRow - 1,
                       "the island must have shifted up into the merged row")
        XCTAssertEqual(v.currentEditorCell?.islandTextView.string,
                       currentDoc().source.substring(in: currentDoc().blocks[newEditingRow].range),
                       "the live island must hold the merged block's text")

        let caretRowTopAfter = v.rowTopInWindowForTest(newEditingRow)
        let originAfter = v.scrollOriginForTest
        let movement = caretRowTopAfter - caretRowTopBefore
        let trace = "anchored=\(anchored) movement=\(movement) "
            + "top=\(caretRowTopBefore)→\(caretRowTopAfter) origin=\(originBefore)→\(originAfter)"

        if anchored {
            XCTAssertEqual(movement, 0, accuracy: 1,
                           "the caret's row must not move on screen across a merge — \(trace)")
            XCTAssertEqual(originAfter.y, originBefore.y, accuracy: 1,
                           "a merge must not scroll the viewport — \(trace)")
        } else {
            // The falsifier. Measured: -33.5 pt (and the origin moved with it).
            XCTAssertGreaterThan(abs(movement), 10,
                                 "WITHOUT the anchor the merge must visibly move the caret's row — "
                                 + "if this stops being true the anchored assertion above is vacuous — \(trace)")
        }
    }

    // MARK: - 3. KEEP-path reload

    /// A KEEP-path refresh (the island's own re-projection: same row count, bytes
    /// before the island unchanged) must not move the caret's row.
    ///
    /// The subject is a document with an IMAGE above the island, because that is
    /// the only way a KEEP reload can change a height ABOVE the caret: the image's
    /// true height is recorded only in `settledHeights`, and the old refresh threw
    /// that dictionary away on every pass, dropping the row back to its
    /// `.textReference` placeholder height.
    ///
    /// ### Measured pre-fix
    ///
    /// With the old wipe restored AND the anchor neutered
    /// (`testKeepReloadJumpsWhenSettledHeightsAreWiped`) the image row above
    /// collapses and the caret's row rises with it. With the fix the settled
    /// heights survive the refresh, so nothing above the caret moves at all — and
    /// if a future change makes something above move again, the anchor absorbs it
    /// (`testKeepReloadAnchorAbsorbsAHeightChangeAbove`).
    func testKeepReloadKeepsTheCaretRowStill() throws {
        try runKeepReload(anchored: true, wipeSettledHeights: false)
    }

    /// FALSIFIER: restore the pre-fix `settledHeights.removeAll()` and neuter the
    /// anchor — the caret's row must visibly jump, proving the zero above is real.
    func testKeepReloadJumpsWhenSettledHeightsAreWiped() throws {
        try runKeepReload(anchored: false, wipeSettledHeights: true)
    }

    /// And with the wipe but WITH the anchor: the anchor alone holds the caret row
    /// still even when a row above really does re-measure.
    func testKeepReloadAnchorAbsorbsAHeightChangeAbove() throws {
        try runKeepReload(anchored: true, wipeSettledHeights: true)
    }

    private func runKeepReload(anchored: Bool, wipeSettledHeights: Bool) throws {
        let dir = try Self.makeImageFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        var parts = ["Intro paragraph.", "![a picture](picture.png)"]
        parts.append(contentsOf: (0..<12).map(Self.paragraph))
        let renderer = AttributedRenderer(baseURL: dir, imageResolution: .async)
        let (v, doc, controller) = makeStack(parts.joined(separator: "\n\n"), renderer: renderer)

        // Let the image decode land, so its TRUE height is the recorded one.
        let settled = expectation(description: "the image row settles")
        v.didRecordSettledHeightForTest = { _ in settled.fulfill() }
        v.forceLoadRowForTest(1)
        wait(for: [settled], timeout: 5)
        v.layoutSubtreeIfNeeded()
        let imageRowHeight = v.rowHeightForTest(1)
        XCTAssertEqual(v.settledHeightCountForTest, 1,
                       "the image's decoded height must be recorded before the refresh")

        let islandRow = 6
        parkMidViewport(v, row: islandRow)
        controller.activate(blockID: doc.blocks[islandRow].id, localPoint: .zero,
                            in: doc, baseRevision: 0)
        v.layoutSubtreeIfNeeded()
        let cellBefore = try XCTUnwrap(v.currentEditorCell)

        let topBefore = v.rowTopInWindowForTest(islandRow)
        let originBefore = v.scrollOriginForTest
        v.resetChurnCountersForTest()
        v.disableViewportAnchorForTest = !anchored
        v.wipeSettledHeightsOnRefreshForTest = wipeSettledHeights

        // The KEEP path: same bytes, same row count, island open and re-anchored by
        // its stable start byte — exactly what `BlockRecyclerReaderView.apply` does
        // for the island's own re-projection.
        v.updateDocumentPreservingEditing(
            doc, contentWidth: 600,
            islandStartByte: controller.activeIsland?.byteRange.lowerBound)
        v.layoutSubtreeIfNeeded()

        // MUTATION: this really was the KEEP path — the island cell is the SAME
        // object (not re-vended), and the other rows really were re-projected.
        XCTAssertTrue(v.currentEditorCell === cellBefore,
                      "the KEEP path must keep the live island cell")
        XCTAssertEqual(v.editingRowForTest, islandRow, "the island must stay on its row")
        let reloadedRows = v.renderCellVendsByRowForTest.keys.filter { $0 != islandRow }
        XCTAssertFalse(reloadedRows.isEmpty,
                       "the KEEP path must actually re-project the non-editing rows")

        let topAfter = v.rowTopInWindowForTest(islandRow)
        let imageAfter = v.rowHeightForTest(1)
        let movement = topAfter - topBefore
        let trace = "anchored=\(anchored) wipe=\(wipeSettledHeights) movement=\(movement) "
            + "imageRowHeight=\(imageRowHeight)→\(imageAfter) "
            + "origin=\(originBefore)→\(v.scrollOriginForTest)"

        if wipeSettledHeights {
            // The pre-fix behaviour, reproduced: the row above really does collapse.
            XCTAssertLessThan(imageAfter, imageRowHeight - 10,
                              "the wipe must genuinely collapse the image row (else the falsifier proves nothing) — \(trace)")
        } else {
            XCTAssertEqual(imageAfter, imageRowHeight, accuracy: 0.5,
                           "a KEEP refresh must not throw the decoded image height away — \(trace)")
            XCTAssertEqual(v.settledHeightCountForTest, 1,
                           "the settled height must survive the refresh — \(trace)")
        }

        if anchored {
            XCTAssertEqual(movement, 0, accuracy: 1,
                           "the caret's row must not move across a KEEP refresh — \(trace)")
        } else {
            XCTAssertGreaterThan(abs(movement), 10,
                                 "WITHOUT the anchor a collapsing row above must visibly move the caret's row — \(trace)")
        }
    }

    // MARK: - Off-screen rule

    /// The documented exception: when the caret's row is NOT on screen the helper
    /// does not fight it. Scrolling to hold an invisible row's position would be
    /// the very motion the invariant forbids, so a projection change with the
    /// island far off screen must leave the scroll origin exactly where the user
    /// put it.
    func testOffscreenCaretRowIsNotFoughtFor() throws {
        var parts = (0..<6).map(Self.paragraph)
        parts.append("```swift\nlet x = 1\nlet y = 2\n```")
        parts.append(contentsOf: (6..<30).map(Self.paragraph))
        let (v, doc, controller) = makeStack(parts.joined(separator: "\n\n"))
        let codeRow = 6
        parkMidViewport(v, row: codeRow)
        controller.activate(blockID: doc.blocks[codeRow].id, localPoint: .zero,
                            in: doc, baseRevision: 0)
        v.layoutSubtreeIfNeeded()

        // Scroll the island well ABOVE the viewport, as a user reading further down
        // the document would. (Scrolling to the very END instead would be clamped by
        // AppKit on the next layout pass, which is a scroll of its own and would make
        // the measurement below meaningless.)
        v.setScrollOriginForTest(v.rowRectForTest(codeRow).maxY + 200)
        v.layoutSubtreeIfNeeded()
        let origin = v.scrollOriginForTest
        XCTAssertFalse(v.rowRectForTest(codeRow).intersects(v.visibleDocumentRectForTest),
                       "the island's row must really be off screen for this test to mean anything")

        controller.deactivate()
        v.layoutSubtreeIfNeeded()

        XCTAssertFalse(v.isEditingRow(codeRow), "the close must still have happened")
        XCTAssertEqual(v.scrollOriginForTest.y, origin.y, accuracy: 1,
                       "an off-screen caret row must not drag the viewport anywhere")
    }

    // MARK: - Fixtures

    /// A real 240×160 PNG on disk, so the image row's decoded height is far larger
    /// than its `.textReference` placeholder (a 1×1 pixel would make the falsifier's
    /// movement smaller than the tolerance).
    private static func makeImageFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-viewport-anchor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 160,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 240, height: 160).fill()
        NSGraphicsContext.restoreGraphicsState()
        let png = rep.representation(using: .png, properties: [:])!
        try png.write(to: dir.appendingPathComponent("picture.png"))
        return dir
    }
}
#endif
