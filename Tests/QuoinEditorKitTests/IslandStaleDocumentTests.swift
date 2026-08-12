#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// The falsifier gates for the two STALE-DOCUMENT defects found by the Phase-3
/// whole-phase review — both corruption-class, both about the island controller
/// trusting document state it never revalidated:
///
///  • **I4** (cutover blocker) — `currentDocument` and `activeIsland.byteRange`
///    were maintained ONLY by the island's own reconcile path, so any change that
///    came from somewhere else (undo/redo, a format or block command, a
///    task-checkbox toggle, conflict resolution, external file adoption) shifted
///    the bytes underneath a stale range and the island's next flush spliced its
///    text over the WRONG span. ⌘Z with a block open was the concrete case: the
///    flush overwrote the very content the undo had just restored.
///  • **I4, second half** — `BlockRecyclerView.updateDocumentPreservingEditing`
///    re-pointed the live editing row by `record(at: islandStartByte)`, which on a
///    shifted document resolves to whatever block now contains that byte. The
///    editing row silently moved onto a block the user never opened.
///  • **I3** — the parked IME activation intent captured the click-time
///    `document` + `baseRevision` and replayed them verbatim, minting the incoming
///    island's byte range from block ranges an apply had already moved.
///
/// Every test here asserts the INTERACTION as well as the post-condition (the
/// counters `refusedFlushCount` / `invalidationTeardownCount`, the byte ranges,
/// the discarded text), so a "fix" that simply stopped doing anything at all
/// would not pass.
@MainActor
final class IslandStaleDocumentTests: AppKitWindowTestCase {

    /// Controllers are referenced weakly by the recycler; keep them alive.
    private var retained: [IslandController] = []

    override func tearDown() {
        retained.removeAll()
        super.tearDown()
    }

    private func makeStack(document doc: QuoinDocument)
        -> (recycler: BlockRecyclerView, controller: IslandController, window: NSWindow)
    {
        let recycler = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = makeTestWindow(width: 640, height: 480)
        window.contentView = recycler
        recycler.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        recycler.setDocument(doc, contentWidth: 600)
        recycler.layoutSubtreeIfNeeded()
        let controller = IslandController(recycler: recycler)
        retained.append(controller)
        return (recycler, controller, window)
    }

    private func byteRange(of block: Block) -> Range<Int> {
        block.range.offset ..< (block.range.offset + block.range.length)
    }

    // MARK: - I4: ⌘Z with an island open

    /// THE CUTOVER BLOCKER. An island is open on the LAST block with UNFLUSHED
    /// keystrokes in it; the user presses ⌘Z, which rewrites EARLIER bytes and
    /// moves that block. The island's `byteRange` is now meaningless.
    ///
    /// The undo is a genuine `DocumentSession.undo()` — the real history splice,
    /// the real `contentRevision` bump — and the flush is the real click-away
    /// (`deactivate()` → `flushActiveIsland`), the path that reads the island's
    /// text back and emits the `SourceEdit`.
    ///
    /// Pre-fix this produced:
    ///   `SourceEdit(range: 16..<32, replacement: "Charlie charlie.X")`
    /// against the POST-UNDO source `"Alpha alpha alpha.\n\nBravo.\n\nCharlie charlie."`,
    /// whose bytes 16..<32 are `"e.\n\nBravo.\n\nChar"` — so the splice produced
    ///   `"Alpha alpha alphCharlie charlie.Xlie charlie."`
    /// destroying the `Bravo.` block the undo had just restored AND mangling the
    /// undo itself. Post-fix the island is torn down at the moment the shifted
    /// document arrives and NOTHING is spliced.
    func testUndoWhileIslandOpenDoesNotCorruptTheDocument() async throws {
        let original = "Alpha alpha alpha.\n\nBravo.\n\nCharlie charlie."
        let session = DocumentSession(source: original)
        // An undoable edit that SHORTENS the first block, so the undo below GROWS
        // the document: the island's stale range then stays IN BOUNDS and points at
        // the wrong bytes (a silent overwrite) instead of off the end (which would
        // merely throw and hide the defect).
        let shortened = try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 18), replacement: "Alpha."),
            actionName: .typing)
        XCTAssertEqual(shortened.source, "Alpha.\n\nBravo.\n\nCharlie charlie.",
                       "precondition: the pre-undo document is the shortened one")

        let (recycler, controller, _) = makeStack(document: shortened)
        var fires: [(range: ByteRange, text: String)] = []
        controller.onReconcile = { range, text, _ in fires.append((range, text)) }

        // Open the island on the LAST block and type into it (UNFLUSHED — the
        // debounce timer is armed but never runs in this test).
        let target = shortened.blocks[2]
        let openedRange = byteRange(of: target)
        controller.activate(blockID: target.id, localPoint: .zero,
                            in: shortened, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell, "the island's editor cell is live")
        XCTAssertEqual(controller.activeIsland?.byteRange, openedRange,
                       "precondition: the island is anchored to the last block")
        XCTAssertEqual(cell.islandTextView.string, "Charlie charlie.")
        cell.islandTextView.insertText(
            "X", replacementRange: NSRange(location: 16, length: 0))
        XCTAssertEqual(cell.islandTextView.string, "Charlie charlie.X",
                       "precondition: there ARE unflushed keystrokes when the undo lands")

        // ⌘Z. A real history splice through the session.
        let undoResult = try await session.undo()
        let undone = try XCTUnwrap(undoResult, "the undo produced a document")
        XCTAssertEqual(undone.source, original, "precondition: the undo restored the original")
        let shiftedRange = byteRange(of: undone.blocks[2])
        XCTAssertNotEqual(shiftedRange.lowerBound, openedRange.lowerBound,
                          "precondition: the undo MOVED the island's block")

        // The app's delivery path for a revision bump (BlockRecyclerReaderView.apply).
        recycler.updateDocumentPreservingEditing(
            undone, contentWidth: 600,
            islandStartByte: controller.activeIsland?.byteRange.lowerBound)

        // The island must be gone — its anchor cannot be revalidated — and the
        // discard must be OBSERVED, not merely inferred from "nothing happened".
        XCTAssertNil(controller.activeIsland,
                     "the island must not survive a document change it cannot revalidate against")
        XCTAssertEqual(controller.invalidationTeardownCount, 1,
                       "the revalidation actually RAN and abandoned the island")
        XCTAssertEqual(controller.lastDiscardedIslandText, "Charlie charlie.X",
                       "the unflushed keystrokes are discarded — and named in the record")

        // Every flush trigger the user could reach next.
        controller.flushPendingReconcile()
        controller.deactivate()
        XCTAssertTrue(fires.isEmpty,
                      "no SourceEdit may be emitted against an unvalidated range; got \(fires)")

        // Apply whatever WAS emitted through the real session and prove the undo's
        // content survived byte-for-byte.
        for fire in fires {
            _ = try? await session.applyEdit(
                SourceEdit(range: fire.range, replacement: fire.text))
        }
        let finalSource = await session.document.source
        XCTAssertEqual(finalSource, original,
                       "the undo's content must survive the island's teardown intact")
    }

    // MARK: - I4: the flush-time drift check (the backstop)

    /// Drive the refuse-on-drift validation DIRECTLY. `adoptDocumentWithoutRevalidationForTest`
    /// puts the controller in the state a MISSED notification path would leave: it
    /// knows about the new document, but its island's range and anchor still
    /// describe the old one. The KEEP-path flush must refuse.
    func testKeepFlushRefusesWhenTheIslandsBytesDrifted() throws {
        let doc = MarkdownConverter.parse("Alpha.\n\nBravo.\n\nCharlie charlie.")
        let (recycler, controller, _) = makeStack(document: doc)
        var fires: [(range: ByteRange, text: String)] = []
        controller.onReconcile = { range, text, _ in fires.append((range, text)) }

        let target = doc.blocks[2]
        controller.activate(blockID: target.id, localPoint: .zero, in: doc, baseRevision: 0)
        let island = try XCTUnwrap(controller.activeIsland)
        let cell = try XCTUnwrap(recycler.currentEditorCell)
        cell.islandTextView.insertText("X", replacementRange: NSRange(location: 16, length: 0))

        let drifted = MarkdownConverter.parse("Alpha alpha alpha.\n\nBravo.\n\nCharlie charlie.")
        XCTAssertNotEqual(drifted.source.substring(in: ByteRange(island.byteRange)),
                          "Charlie charlie.",
                          "precondition: the drifted document holds DIFFERENT bytes at the island's range")
        controller.adoptDocumentWithoutRevalidationForTest(drifted)

        controller.flushPendingReconcile()

        XCTAssertTrue(fires.isEmpty, "the KEEP flush must refuse to splice; got \(fires)")
        XCTAssertEqual(controller.refusedFlushCount, 1,
                       "the drift check RAN and refused (not: nothing was pending)")
        XCTAssertEqual(controller.lastDiscardedIslandText, "Charlie charlie.X",
                       "the refused text is recorded, so the loss is never silent")
        XCTAssertNil(controller.activeIsland,
                     "a mis-anchored island is torn down, not left live over a range it cannot write")
    }

    /// Same drift, but through the TERMINAL flush (click-away / blur), which reads
    /// the island's text back on a different code path (`flushActiveIsland`) and so
    /// needs its own guard.
    func testTerminalFlushRefusesWhenTheIslandsBytesDrifted() throws {
        let doc = MarkdownConverter.parse("Alpha.\n\nBravo.\n\nCharlie charlie.")
        let (recycler, controller, _) = makeStack(document: doc)
        var fires: [(range: ByteRange, text: String)] = []
        controller.onReconcile = { range, text, _ in fires.append((range, text)) }

        controller.activate(blockID: doc.blocks[2].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell)
        cell.islandTextView.insertText("X", replacementRange: NSRange(location: 16, length: 0))
        XCTAssertEqual(cell.islandTextView.string, "Charlie charlie.X",
                       "precondition: the island holds text the flush would want to write")

        controller.adoptDocumentWithoutRevalidationForTest(
            MarkdownConverter.parse("Alpha alpha alpha.\n\nBravo.\n\nCharlie charlie."))

        controller.deactivate()

        XCTAssertTrue(fires.isEmpty, "the terminal flush must refuse to splice; got \(fires)")
        XCTAssertEqual(controller.refusedFlushCount, 1,
                       "the drift check RAN on the terminal path too")
        XCTAssertEqual(controller.lastDiscardedIslandText, "Charlie charlie.X")
        XCTAssertNil(controller.activeIsland)
    }

    /// The complement, and the guard against a "fix" that just refuses everything:
    /// with the document UNCHANGED underneath it, the very same flush fires
    /// normally, at the island's own range, with the island's own text.
    func testUndriftedFlushStillFires() throws {
        let doc = MarkdownConverter.parse("Alpha.\n\nBravo.\n\nCharlie charlie.")
        let (recycler, controller, _) = makeStack(document: doc)
        var fires: [(range: ByteRange, text: String)] = []
        controller.onReconcile = { range, text, _ in fires.append((range, text)) }

        controller.activate(blockID: doc.blocks[2].id, localPoint: .zero, in: doc, baseRevision: 0)
        let island = try XCTUnwrap(controller.activeIsland)
        let cell = try XCTUnwrap(recycler.currentEditorCell)
        cell.islandTextView.insertText("X", replacementRange: NSRange(location: 16, length: 0))

        controller.flushPendingReconcile()

        XCTAssertEqual(fires.count, 1, "an undrifted island still reconciles normally")
        XCTAssertEqual(fires.first?.range.offset, island.byteRange.lowerBound)
        XCTAssertEqual(fires.first?.range.length, island.byteRange.count)
        XCTAssertEqual(fires.first?.text, "Charlie charlie.X")
        XCTAssertEqual(controller.refusedFlushCount, 0)
    }

    // MARK: - I4, second half: the wrong-block re-point

    /// `updateDocumentPreservingEditing` must not adopt "whatever block happens to
    /// contain the island's start byte". On a shifted document that byte lands
    /// INSIDE a different block, and the pre-fix code re-pointed `_editingBlockID`
    /// (and the live cell's `blockID`) onto it — the user's open editor silently
    /// became a different block's editor.
    ///
    /// Pre-fix the re-point had a second, nastier consequence: re-pointing the
    /// editing identity onto ROW 0 made the reload sweep include the row the live
    /// editor cell physically sits on, whose resign then read as a genuine BLUR and
    /// ran a full `deactivate()` — flushing the island's text at its stale range.
    /// So this asserts not only "no silent adoption" but "no splice", with real
    /// unflushed text in the island to splice.
    func testPreservingRefreshDoesNotRePointOntoADifferentBlock() throws {
        let before = MarkdownConverter.parse("Alpha.\n\nBravo.\n\nCharlie charlie.")
        let (recycler, controller, _) = makeStack(document: before)
        var fires: [(range: ByteRange, text: String)] = []
        controller.onReconcile = { range, text, _ in fires.append((range, text)) }

        let target = before.blocks[2]
        controller.activate(blockID: target.id, localPoint: .zero, in: before, baseRevision: 0)
        let islandStart = try XCTUnwrap(controller.activeIsland?.byteRange.lowerBound)
        XCTAssertTrue(recycler.isEditingRow(2), "precondition: row 2 is the editing row")
        XCTAssertEqual(recycler.currentEditorCell?.blockID, target.id)
        let cell = try XCTUnwrap(recycler.currentEditorCell)
        cell.islandTextView.insertText("X", replacementRange: NSRange(location: 16, length: 0))
        XCTAssertEqual(cell.islandTextView.string, "Charlie charlie.X",
                       "precondition: the island holds unflushed text a stray flush could splice")

        // The shifted document: the island's start byte now lands inside block 0.
        let after = MarkdownConverter.parse("Alpha alpha alpha.\n\nBravo.\n\nCharlie charlie.")
        let occupant = try XCTUnwrap(BlockListModel(document: after).record(at: islandStart))
        XCTAssertEqual(occupant.blockID, after.blocks[0].id,
                       "precondition: a DIFFERENT block occupies the island's start byte")
        XCTAssertNotEqual(occupant.byteRange.lowerBound, islandStart,
                          "precondition: that byte is not a block START any more")

        recycler.updateDocumentPreservingEditing(
            after, contentWidth: 600, islandStartByte: islandStart)

        XCTAssertNil(recycler.editingBlockID,
                     "the editing identity must be dropped, never re-pointed onto another block")
        XCTAssertNil(recycler.currentEditorCell,
                     "the live editor cell must be gone (full swap), not re-labelled")
        XCTAssertNil(controller.activeIsland, "and the controller's island with it")
        XCTAssertEqual(controller.invalidationTeardownCount, 1,
                       "the abandonment actually ran (anti-vacuity)")
        XCTAssertTrue(fires.isEmpty,
                      "and nothing was spliced on the way out; got \(fires)")
        XCTAssertEqual(controller.refusedFlushCount, 0,
                       "the flush was prevented at the door, not refused at the sill")
        XCTAssertEqual(recycler.numberOfRowsForTest, after.blocks.count,
                       "the refresh still projected the new document")
    }

    /// The complement: the island's OWN re-projection — its block's content (and
    /// content-hash id, and length) changed, but nothing before it moved — is still
    /// preserved, with the editing identity re-pointed onto the new id. This is the
    /// `IslandRefreshOrderTests` shape, asserted here too so the guard above cannot
    /// be tightened into a teardown-everything rule.
    func testPreservingRefreshStillKeepsTheIslandOnItsOwnReprojection() throws {
        let before = MarkdownConverter.parse("Alpha.\n\nBravo.\n\nCharlie charlie.")
        let (recycler, controller, _) = makeStack(document: before)
        controller.activate(blockID: before.blocks[2].id, localPoint: .zero,
                            in: before, baseRevision: 0)
        let islandStart = try XCTUnwrap(controller.activeIsland?.byteRange.lowerBound)

        // Only the island's OWN block changed; every byte before it is identical.
        let after = MarkdownConverter.parse("Alpha.\n\nBravo.\n\nCharlie charlie.X")
        XCTAssertNotEqual(before.blocks[2].id, after.blocks[2].id,
                          "precondition: the content-hash id changed")

        recycler.updateDocumentPreservingEditing(
            after, contentWidth: 600, islandStartByte: islandStart)

        XCTAssertTrue(recycler.isEditingRow(2), "the island survives its own re-projection")
        XCTAssertEqual(recycler.currentEditorCell?.blockID, after.blocks[2].id,
                       "the editing identity re-points onto the new content-hash id")
        XCTAssertEqual(controller.activeIsland?.byteRange, byteRange(of: after.blocks[2]),
                       "and the island re-anchors to the block's new range")
        XCTAssertEqual(controller.invalidationTeardownCount, 0, "nothing was abandoned")
    }

    // MARK: - I3: the parked IME intent replays against the CURRENT document

    /// A click parked by a live IME composition must be replayed against the
    /// document as it is AT DRAIN TIME. Pre-fix the intent carried the click-time
    /// parse, so a change that landed while the user kept composing left the
    /// incoming island minted from stale block ranges — and its first flush spliced
    /// at those stale offsets.
    func testParkedIntentMintsAgainstTheCurrentDocumentNotTheParkedOne() throws {
        let atClickTime = MarkdownConverter.parse("Alpha.\n\nBravo.\n\nCharlie charlie.")
        let (recycler, controller, _) = makeStack(document: atClickTime)
        controller.onReconcile = { _, _, _ in }

        // Island A on block 0, mid-composition.
        controller.activate(blockID: atClickTime.blocks[0].id, localPoint: .zero,
                            in: atClickTime, baseRevision: 0)
        controller.hasMarkedTextProbe = { true }
        let cellA = try XCTUnwrap(recycler.currentEditorCell)
        cellA.islandTextView.insertText(
            "\u{3042}", replacementRange: NSRange(location: 6, length: 0))

        // A click into block 2 PARKS (no swap) while the composition is live.
        let parkedTarget = atClickTime.blocks[2]
        controller.activate(blockID: parkedTarget.id, localPoint: .zero,
                            in: atClickTime, baseRevision: 0)
        XCTAssertEqual(controller.state, .blockedIME(parkedTarget.id),
                       "precondition: the intent parked rather than swapping")

        // While the user keeps composing, a change lands that MOVES block 2 (block 1
        // grew). Block 0 — the live island — is untouched, so the island survives.
        let atDrainTime = MarkdownConverter.parse("Alpha.\n\nBravo bravo bravo.\n\nCharlie charlie.")
        let staleRange = byteRange(of: atClickTime.blocks[2])
        let currentRange = byteRange(of: atDrainTime.blocks[2])
        XCTAssertNotEqual(staleRange, currentRange,
                          "precondition: the target block MOVED between park and drain")
        XCTAssertEqual(atClickTime.blocks[2].id, atDrainTime.blocks[2].id,
                       "precondition: same block identity — only its position changed")
        recycler.updateDocumentPreservingEditing(
            atDrainTime, contentWidth: 600,
            islandStartByte: controller.activeIsland?.byteRange.lowerBound)
        XCTAssertNotNil(controller.activeIsland,
                        "precondition: island A survives a change that did not touch it")

        // The composition commits → the parked activation drains.
        controller.hasMarkedTextProbe = { false }
        let liveCellA = try XCTUnwrap(recycler.currentEditorCell)
        liveCellA.islandTextView.insertText(
            "!", replacementRange: NSRange(location: (liveCellA.islandTextView.string as NSString).length,
                                           length: 0))

        XCTAssertEqual(controller.activeIsland?.originBlockID, atDrainTime.blocks[2].id,
                       "the drain actually replayed the parked click (anti-vacuity)")
        XCTAssertEqual(controller.activeIsland?.byteRange, currentRange,
                       "the replayed island is minted against the CURRENT document, not the parked one")
        XCTAssertNotEqual(controller.activeIsland?.byteRange, staleRange,
                          "…and specifically NOT against the stale click-time ranges")
        XCTAssertEqual(recycler.currentEditorCell?.islandTextView.string, "Charlie charlie.",
                       "the incoming island is seeded from the block it actually landed on")
    }
}
#endif
