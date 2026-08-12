#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// The DATA-LOSS gate for the island's RE-ANCHOR path (the sibling of
/// `IslandStaleDocumentTests`, which gates the MISMATCH path).
///
/// `IslandController.revalidateForDocumentRefresh` accepts a re-anchor when the
/// island's block is still positionally identifiable (same start byte, same
/// index). Pre-fix it refreshed the ANCHOR (`anchoredSource`) but never touched
/// the island's TEXT VIEW. After a ⌘Z that rewrote the open block IN PLACE the
/// island therefore displayed the PRE-undo text while the anchor claimed to be in
/// sync — and because the anchor matched, the refuse-on-drift guard added in
/// 38d1994 waved the next flush straight through. One keystroke after the undo
/// spliced the stale text back over the restored bytes: the undo was silently
/// reverted.
///
/// Post-fix the re-anchor is a THREE-WAY decision:
///
///  1. the re-anchored block's bytes still equal `anchoredSource` (the external
///     change did not touch the island's block) → pure re-anchor, nothing is
///     re-seeded, unflushed typing survives;
///  2. the bytes CHANGED and the island has no unflushed edits → RE-SEED the
///     island from the new bytes and stay active (the undo is visible
///     immediately), caret clamped;
///  3. the bytes CHANGED and the island HAS unflushed edits → abandon LOUDLY
///     (`abandonIslandForInvalidatedDocument`), because merging the two is
///     ambiguous and writing either one at the other's offsets corrupts.
///
/// Every assertion on a counter is paired with an "it actually happened" assert
/// (the emitted `SourceEdit`s, the island's live string, the caret), so an
/// implementation that simply stopped flushing would not pass.
@MainActor
final class IslandExternalReseedTests: AppKitWindowTestCase {

    /// Controllers are referenced weakly by the recycler; keep them alive.
    private var retained: [IslandController] = []

    override func tearDown() {
        retained.removeAll()
        super.tearDown()
    }

    private func makeStack(document doc: QuoinDocument)
        -> (recycler: BlockRecyclerView, controller: IslandController)
    {
        let recycler = BlockRecyclerView(renderer: AttributedRenderer(), theme: Theme())
        let window = makeTestWindow(width: 640, height: 480)
        window.contentView = recycler
        recycler.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        recycler.setDocument(doc, contentWidth: 600)
        recycler.layoutSubtreeIfNeeded()
        let controller = IslandController(recycler: recycler)
        retained.append(controller)
        return (recycler, controller)
    }

    private func byteRange(of block: Block) -> Range<Int> {
        block.range.offset ..< (block.range.offset + block.range.length)
    }

    /// Build "Alpha.\n\nBravo." and then edit the SECOND block in place, so the
    /// undo below rewrites that block's content WITHOUT moving its start byte or
    /// its index — the exact shape that takes the RE-ANCHOR path (not the
    /// mismatch path `IslandStaleDocumentTests` already gates).
    private func sessionWithEditedSecondBlock(_ replacement: String) async throws
        -> (session: DocumentSession, edited: QuoinDocument, original: String)
    {
        let original = "Alpha.\n\nBravo."
        let session = DocumentSession(source: original)
        let edited = try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 8, length: 6), replacement: replacement),
            actionName: .typing)
        XCTAssertEqual(edited.source, "Alpha.\n\n" + replacement,
                       "precondition: the pre-undo document is the edited one")
        XCTAssertEqual(edited.blocks.count, 2, "precondition: still two blocks")
        XCTAssertEqual(edited.blocks[1].range.offset, 8,
                       "precondition: the edited block still starts at byte 8")
        return (session, edited, original)
    }

    // MARK: - 1. THE DATA-LOSS GATE

    /// ⌘Z rewrites the OPEN block in place; the user then types one character.
    ///
    /// Pre-fix the island still held `"Bravo edited."` while `anchoredSource` had
    /// been refreshed to the post-undo `"Bravo."`, so the flush-time drift check
    /// PASSED and the controller emitted
    ///   `SourceEdit(range: 8..<14, replacement: "XBravo edited.")`
    /// over the post-undo source `"Alpha.\n\nBravo."`, producing
    ///   `"Alpha.\n\nXBravo edited."`
    /// — the undo silently reverted, with the keystroke welded onto the resurrected
    /// text. Post-fix the island is re-seeded to `"Bravo."` the moment the undo's
    /// document arrives, so the same keystroke produces `"Alpha.\n\nXBravo."`.
    func testTypingAfterUndoDoesNotResurrectThePreUndoText() async throws {
        let (session, edited, _) = try await sessionWithEditedSecondBlock("Bravo edited.")
        let (recycler, controller) = makeStack(document: edited)
        var fires: [(range: ByteRange, text: String)] = []
        controller.onReconcile = { range, text, _ in fires.append((range, text)) }

        controller.activate(blockID: edited.blocks[1].id, localPoint: .zero,
                            in: edited, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell, "the island's editor cell is live")
        XCTAssertEqual(cell.islandTextView.string, "Bravo edited.",
                       "precondition: the island opened on the PRE-undo text")

        // ⌘Z — a real history splice through the real session.
        let undoResult = try await session.undo()
        let undone = try XCTUnwrap(undoResult, "the undo produced a document")
        XCTAssertEqual(undone.source, "Alpha.\n\nBravo.",
                       "precondition: the undo restored the original")
        XCTAssertEqual(undone.blocks[1].range.offset, 8,
                       "precondition: the undo did NOT move the island's block (re-anchor path)")

        // The app's delivery path for a revision bump.
        recycler.updateDocumentPreservingEditing(
            undone, contentWidth: 600,
            islandStartByte: controller.activeIsland?.byteRange.lowerBound)

        // The island is still live and re-anchored (this is the re-anchor path, not
        // the mismatch path).
        XCTAssertNotNil(controller.activeIsland,
                        "the island stays open — the block is still positionally identifiable")
        XCTAssertEqual(controller.activeIsland?.byteRange, byteRange(of: undone.blocks[1]),
                       "the island re-anchored onto the post-undo range")

        // One keystroke, at a FIXED offset so the pre-fix and post-fix strings are
        // directly comparable.
        let live = try XCTUnwrap(recycler.currentEditorCell)
        live.islandTextView.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        controller.flushPendingReconcile()

        XCTAssertEqual(fires.count, 1, "exactly one reconcile fired; got \(fires)")
        let fire = try XCTUnwrap(fires.first)
        XCTAssertEqual(fire.text, "XBravo.",
                       "the flushed text is the POST-undo block plus the keystroke, not the pre-undo text")

        _ = try await session.applyEdit(SourceEdit(range: fire.range, replacement: fire.text))
        let finalSource = await session.document.source
        XCTAssertEqual(finalSource, "Alpha.\n\nXBravo.",
                       "typing after an undo must build on the UNDONE content")
        XCTAssertFalse(finalSource.contains("edited"),
                       "the undo must not be resurrected by the island's stale text")
    }

    // MARK: - 2. VISIBLE FRESHNESS

    /// The user-visible half of the same bug: with NO typing after the undo, the
    /// island's text view must already SHOW the restored bytes. (Pre-fix it showed
    /// the pre-undo text until the user clicked away and the read cell re-rendered
    /// — "the undo isn't reflected in the editable area".)
    func testIslandTextIsReseededFromTheNewDocumentAfterAnUndo() async throws {
        let (session, edited, _) = try await sessionWithEditedSecondBlock("Bravo edited.")
        let (recycler, controller) = makeStack(document: edited)
        controller.onReconcile = { _, _, _ in }

        controller.activate(blockID: edited.blocks[1].id, localPoint: .zero,
                            in: edited, baseRevision: 0)
        XCTAssertEqual(recycler.currentEditorCell?.islandTextView.string, "Bravo edited.")

        let undoResult = try await session.undo()
        let undone = try XCTUnwrap(undoResult)
        recycler.updateDocumentPreservingEditing(
            undone, contentWidth: 600,
            islandStartByte: controller.activeIsland?.byteRange.lowerBound)

        let cell = try XCTUnwrap(recycler.currentEditorCell,
                                 "the island is still the live editing cell")
        XCTAssertEqual(cell.islandTextView.string, "Bravo.",
                       "the island must DISPLAY the post-undo bytes, not the pre-undo ones")
        XCTAssertEqual(
            cell.islandTextView.string,
            undone.source.substring(in: ByteRange(byteRange(of: undone.blocks[1]))),
            "and it must equal the document's bytes for the re-anchored block exactly")
        XCTAssertEqual(controller.invalidationTeardownCount, 0,
                       "a clean island is RE-SEEDED, not abandoned")
        XCTAssertEqual(cell.blockID, undone.blocks[1].id,
                       "the editing identity re-points onto the post-undo content-hash id")
    }

    /// The re-seeded string must remain byte-identical to the document (the
    /// `BlockEditorCell` string-integrity gate) AND be styled — a re-seed that
    /// bypassed `configure`/`restyle` would leave the island in the unstyled seed
    /// face. Asserted through the same seam `IslandSourceStylingTests` uses.
    func testReseedKeepsTheStringIntactAndRestyled() async throws {
        let original = "Alpha.\n\n# Heading"
        let session = DocumentSession(source: original)
        let edited = try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 8, length: 9), replacement: "# Heading edited"),
            actionName: .typing)
        let (recycler, controller) = makeStack(document: edited)
        controller.onReconcile = { _, _, _ in }
        // The recycler installs the real styler on every editor cell it vends.
        controller.activate(blockID: edited.blocks[1].id, localPoint: .zero,
                            in: edited, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell)
        let restylesBefore = cell.restyleCountForTest

        let undoResult = try await session.undo()
        let undone = try XCTUnwrap(undoResult)
        recycler.updateDocumentPreservingEditing(
            undone, contentWidth: 600,
            islandStartByte: controller.activeIsland?.byteRange.lowerBound)

        let live = try XCTUnwrap(recycler.currentEditorCell)
        XCTAssertEqual(live.islandTextView.string, "# Heading",
                       "the re-seeded string is the document's bytes, character for character")
        XCTAssertEqual(live.styledTextForTest.string, live.islandTextView.string,
                       "the styling layer never changes the characters")
        XCTAssertGreaterThan(live.restyleCountForTest, restylesBefore,
                             "the re-seed went through the restyle path, not a raw string poke")
    }

    // MARK: - 3. UNFLUSHED → ABANDON

    /// Unflushed keystrokes + an external change to the SAME block is genuinely
    /// ambiguous: re-seeding would silently eat the typing, keeping the text would
    /// re-ship the data-loss bug. The established rule in this codebase is
    /// "discard LOUDLY rather than write at wrong offsets".
    func testUnflushedTypingIsAbandonedLoudlyOnAnExternalChangeToTheSameBlock() async throws {
        let (session, edited, _) = try await sessionWithEditedSecondBlock("Bravo edited.")
        let (recycler, controller) = makeStack(document: edited)
        var fires: [(range: ByteRange, text: String)] = []
        controller.onReconcile = { range, text, _ in fires.append((range, text)) }

        controller.activate(blockID: edited.blocks[1].id, localPoint: .zero,
                            in: edited, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell)
        cell.islandTextView.insertText("Q", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(cell.islandTextView.string, "QBravo edited.",
                       "precondition: there ARE unflushed keystrokes when the undo lands")

        let undoResult = try await session.undo()
        let undone = try XCTUnwrap(undoResult)
        recycler.updateDocumentPreservingEditing(
            undone, contentWidth: 600,
            islandStartByte: controller.activeIsland?.byteRange.lowerBound)

        XCTAssertNil(controller.activeIsland,
                     "an island with unflushed typing over changed bytes must go down")
        XCTAssertEqual(controller.invalidationTeardownCount, 1,
                       "the abandon actually RAN (not: nothing happened)")
        XCTAssertEqual(controller.lastDiscardedIslandText, "QBravo edited.",
                       "the discarded text is named in the record, so the loss is never silent")

        // Every flush trigger the user could reach next must stay silent.
        controller.flushPendingReconcile()
        controller.deactivate()
        XCTAssertTrue(fires.isEmpty, "no SourceEdit may be emitted; got \(fires)")
        for fire in fires {
            _ = try? await session.applyEdit(SourceEdit(range: fire.range, replacement: fire.text))
        }
        let finalSource = await session.document.source
        XCTAssertEqual(finalSource, "Alpha.\n\nBravo.",
                       "the undo's content survives the abandon byte-for-byte")
    }

    // MARK: - 4. CARET

    /// The caret rule: the island keeps its UTF-16 offset, CLAMPED to the new
    /// text's length (and snapped back to a composed-character boundary). A block
    /// that shrinks past the caret parks it at the end rather than crashing.
    func testCaretIsClampedIntoAShrunkenBlockAfterReseed() async throws {
        let (session, edited, _) = try await sessionWithEditedSecondBlock("Bravo edited long tail.")
        let (recycler, controller) = makeStack(document: edited)
        controller.onReconcile = { _, _, _ in }

        controller.activate(blockID: edited.blocks[1].id, localPoint: .zero,
                            in: edited, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell)
        XCTAssertEqual(cell.islandTextView.string, "Bravo edited long tail.")
        cell.islandTextView.setSelectedRange(NSRange(location: 20, length: 0))
        XCTAssertEqual(cell.islandTextView.selectedRange().location, 20,
                       "precondition: the caret sits PAST the length of the post-undo block")

        let undoResult = try await session.undo()
        let undone = try XCTUnwrap(undoResult)
        recycler.updateDocumentPreservingEditing(
            undone, contentWidth: 600,
            islandStartByte: controller.activeIsland?.byteRange.lowerBound)

        let live = try XCTUnwrap(recycler.currentEditorCell)
        XCTAssertEqual(live.islandTextView.string, "Bravo.", "precondition: the block shrank")
        let caret = live.islandTextView.selectedRange().location
        XCTAssertEqual(live.islandTextView.selectedRange().length, 0, "still an insertion point")
        XCTAssertLessThanOrEqual(caret, (live.islandTextView.string as NSString).length,
                                 "the caret is in bounds")
        XCTAssertEqual(caret, 6, "a caret past the new end clamps to the end of the block")
    }

    /// The non-shrinking half of the caret rule: a caret that still fits keeps its
    /// exact offset.
    func testCaretKeepsItsOffsetWhenItStillFitsAfterReseed() async throws {
        let (session, edited, _) = try await sessionWithEditedSecondBlock("Bravo edited.")
        let (recycler, controller) = makeStack(document: edited)
        controller.onReconcile = { _, _, _ in }

        controller.activate(blockID: edited.blocks[1].id, localPoint: .zero,
                            in: edited, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell)
        cell.islandTextView.setSelectedRange(NSRange(location: 3, length: 0))

        let undoResult = try await session.undo()
        let undone = try XCTUnwrap(undoResult)
        recycler.updateDocumentPreservingEditing(
            undone, contentWidth: 600,
            islandStartByte: controller.activeIsland?.byteRange.lowerBound)

        let live = try XCTUnwrap(recycler.currentEditorCell)
        XCTAssertEqual(live.islandTextView.string, "Bravo.")
        XCTAssertEqual(live.islandTextView.selectedRange().location, 3,
                       "a caret that still fits is preserved exactly")
    }

    // MARK: - 5. POSITIVE CONTROL

    /// An external change to a DIFFERENT block leaves the island's own bytes
    /// untouched: nothing is re-seeded, and unflushed typing SURVIVES. This is what
    /// stops the fix from being tightened into "abandon on every external change".
    func testExternalChangeToAnotherBlockLeavesTheIslandAndItsTypingIntact() async throws {
        let original = "Alpha.\n\nBravo.\n\nCharlie."
        let session = DocumentSession(source: original)
        let doc = await session.document
        let (recycler, controller) = makeStack(document: doc)
        var fires: [(range: ByteRange, text: String)] = []
        controller.onReconcile = { range, text, _ in fires.append((range, text)) }

        // Island on the FIRST block, so a change to the LAST block cannot move it.
        controller.activate(blockID: doc.blocks[0].id, localPoint: .zero,
                            in: doc, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell)
        cell.islandTextView.insertText("Z", replacementRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(cell.islandTextView.string, "AlphaZ.",
                       "precondition: the island holds unflushed typing")

        // An external edit to the LAST block (a task toggle / format command shape).
        let changed = try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 16, length: 8), replacement: "Charlie!!"),
            actionName: .typing)
        XCTAssertEqual(changed.source, "Alpha.\n\nBravo.\n\nCharlie!!")
        recycler.updateDocumentPreservingEditing(
            changed, contentWidth: 600,
            islandStartByte: controller.activeIsland?.byteRange.lowerBound)

        XCTAssertNotNil(controller.activeIsland, "the island survives a change to another block")
        XCTAssertEqual(controller.invalidationTeardownCount, 0, "nothing was abandoned")
        let live = try XCTUnwrap(recycler.currentEditorCell)
        XCTAssertEqual(live.islandTextView.string, "AlphaZ.",
                       "the unflushed typing is NOT clobbered by a re-seed")

        // And it still flushes to the right place.
        controller.flushPendingReconcile()
        XCTAssertEqual(fires.count, 1, "the island is still editable and still flushes")
        let fire = try XCTUnwrap(fires.first)
        XCTAssertEqual(fire.range, ByteRange(offset: 0, length: 6))
        XCTAssertEqual(fire.text, "AlphaZ.")
        _ = try await session.applyEdit(SourceEdit(range: fire.range, replacement: fire.text))
        let finalSource = await session.document.source
        XCTAssertEqual(finalSource, "AlphaZ.\n\nBravo.\n\nCharlie!!")
    }

    // MARK: - 6. THE `revalidate.skip` (apply-in-flight) PATH

    /// The in-flight early return is the one branch that deliberately does NOT
    /// re-anchor. It must therefore also NOT refresh the anchor — otherwise it
    /// would reproduce exactly the defect this suite gates, one layer down.
    ///
    /// Here the island's own reconcile is in flight (the app never calls
    /// `applyReconciled`) when an external change to the SAME block arrives. The
    /// island's text is stale relative to the document, but the anchor is stale
    /// TOO, so every later splice is refused by the byte re-validation.
    func testApplyInFlightSkipLeavesTheAnchorStaleSoNoSpliceCanLand() async throws {
        let doc = MarkdownConverter.parse("Alpha.\n\nBravo.")
        let (recycler, controller) = makeStack(document: doc)
        var fires: [(range: ByteRange, text: String)] = []
        // Deliberately NO applyReconciled: the apply stays in flight.
        controller.onReconcile = { range, text, _ in fires.append((range, text)) }

        controller.activate(blockID: doc.blocks[1].id, localPoint: .zero, in: doc, baseRevision: 0)
        let cell = try XCTUnwrap(recycler.currentEditorCell)
        cell.islandTextView.insertText("X", replacementRange: NSRange(location: 6, length: 0))
        controller.flushPendingReconcile()
        XCTAssertEqual(fires.count, 1, "precondition: the island's own reconcile fired")
        XCTAssertEqual(fires[0].text, "Bravo.X")

        // An EXTERNAL change to the same block lands while that apply is in flight.
        let external = MarkdownConverter.parse("Alpha.\n\nZulu.")
        recycler.updateDocumentPreservingEditing(
            external, contentWidth: 600,
            islandStartByte: controller.activeIsland?.byteRange.lowerBound)
        XCTAssertNotNil(controller.activeIsland,
                        "the in-flight window stands down; the apply's re-anchor decides")

        // More typing, then a terminal flush: it parks behind the in-flight apply.
        let live = try XCTUnwrap(recycler.currentEditorCell)
        live.islandTextView.insertText("Y", replacementRange: NSRange(location: 7, length: 0))
        controller.deactivate()
        XCTAssertEqual(controller.deferredOpCountForTest, 1,
                       "the terminal flush was DEFERRED behind the in-flight apply")

        // The apply finally lands, releasing the deferred flush — which must be
        // REFUSED, because the document no longer holds what it was computed against.
        controller.applyReconciled(external)
        XCTAssertEqual(fires.count, 1,
                       "the deferred flush refused on byte drift; nothing new was spliced. got \(fires)")
    }
}
#endif
