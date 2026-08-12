#if canImport(AppKit)
import AppKit
import QuoinCore

/// Phase 2, Task 5: the swap machine that promotes exactly ONE recycler row from
/// the read-only `BlockRenderCell` to an editable `BlockEditorCell` (the
/// "island") on a click, and reverses on blur.
///
/// It is a pure-ish DRIVER: it never touches a `DocumentSession`. It sets the
/// recycler's `editingBlockID` (which reloads the affected rows so `viewFor`
/// vends a seeded `BlockEditorCell`), makes that cell's `islandTextView` first
/// responder, places the caret from the click point, mints the `IslandUnit`,
/// and emits `onReconcile` when an island is flushed. The APP installs
/// `onReconcile` to apply the edit back through the session (Task 6 adds the
/// debounce; Task 7 wires it to the recycler's click seam).
///
/// ## SwapState
///
/// ```
///   idle ──activate(hasMarkedText)──▶ blockedIME(intent)     (intent queued, NO swap)
///   idle ──activate(clean)──────────▶ swapping ──▶ idle       (fresh promotion)
///   idle(active) ──activate(clean)──▶ pendingFlush(old) ──▶ swapping ──▶ idle
///   idle(active) ──deactivate()─────▶ pendingFlush(old) ──▶ idle
/// ```
///
/// `pendingFlush(BlockID)` is the transient window where the OUTGOING island's
/// text is read back and `onReconcile` fires, before the recycler swaps rows.
/// `blockedIME(BlockID)` parks the activation intent while an IME composition is
/// live (marked text present): swapping mid-composition would drop the
/// half-composed characters, so the machine refuses and keeps the current
/// island.
@MainActor
public final class IslandController {

    public enum SwapState: Equatable {
        case idle
        case pendingFlush(BlockID)
        case swapping
        case blockedIME(BlockID)
    }

    public private(set) var state: SwapState = .idle
    public private(set) var activeIsland: IslandUnit?

    /// App installs this to apply a flushed island's text back through the
    /// session. Fired on every flush (swap-out + blur) with the island's byte
    /// range, its current text, and the island-local UTF-16 caret. The debounce
    /// that batches per-keystroke flushes is Task 6; here it fires once per
    /// swap/deactivate, which is enough to prove the seam.
    public var onReconcile: ((ByteRange, String, _ islandUTF16Caret: Int) -> Void)?

    /// The machine refuses to swap while an IME composition is live. On by
    /// default; the tests flip it only to prove the gate.
    public var refuseWhileMarkedText: Bool = true

    /// Test seam: when set, overrides the live `islandTextView.hasMarkedText()`
    /// probe so the IME-refusal branch can be exercised headlessly.
    var hasMarkedTextProbe: (() -> Bool)?

    // The activation intent parked while blocked by a live IME composition, so a
    // later commit (IME end → retry) can resume the swap. Retry is Task 6/7; the
    // intent is captured here so the seam is complete.
    private struct PendingIntent {
        let blockID: BlockID
        let localPoint: CGPoint
        let document: QuoinDocument
        let baseRevision: Int
    }
    private var pendingIntent: PendingIntent?

    private unowned let recycler: BlockRecyclerView

    public init(recycler: BlockRecyclerView) {
        self.recycler = recycler
    }

    // MARK: - Activation

    /// Activation intent from the recycler's click seam: promote `blockID`'s row
    /// to an editable island, seed it, first-respond, and place the caret near
    /// `localPoint` (the click's cell-local point). Flushes any current island
    /// first. Refuses (parks in `.blockedIME`) if a live IME composition would
    /// be dropped by the swap.
    public func activate(blockID: BlockID, localPoint: CGPoint,
                         in document: QuoinDocument, baseRevision: Int) {
        // IME refusal: swapping mid-composition drops the marked text. Park the
        // intent and keep the current island — do NOT flush, do NOT swap.
        if refuseWhileMarkedText, currentHasMarkedText() {
            pendingIntent = PendingIntent(blockID: blockID, localPoint: localPoint,
                                          document: document, baseRevision: baseRevision)
            state = .blockedIME(blockID)
            return
        }

        // Flush the OUTGOING island (if any) before touching the recycler, while
        // its editor cell still hosts the outgoing block's text.
        if activeIsland != nil {
            flushActiveIsland()
        }

        state = .swapping

        guard let block = document.blocks.first(where: { $0.id == blockID }) else {
            // The block vanished from the document; abandon the swap cleanly.
            state = .idle
            return
        }

        // Mint FIRST and gate the swap on it: a nil mint (block's content range
        // unresolvable) must NOT leave a stuck editable row with no active
        // island. Bail cleanly with no side effects.
        var model = BlockListModel(document: document)
        guard let island = model.mintIsland(at: block.range.offset, baseRevision: baseRevision) else {
            state = .idle
            return
        }

        // THE SWAP: set editingBlockID → the recycler reloads that one row so
        // `viewFor` vends a seeded `BlockEditorCell`. Then realize it, hand it
        // first responder, place the caret from the click point, and re-query the
        // row height so it sizes from the LIVE raw-source island layout (not the
        // projected read height) at activation, before any keystroke.
        recycler.editingBlockID = blockID
        if let cell = recycler.editorCellForEditingRow() {
            cell.window?.makeFirstResponder(cell.islandTextView)
            placeCaret(in: cell.islandTextView, atLocalPoint: localPoint)
            recycler.noteEditingRowHeight()
        }

        activeIsland = island
        state = .idle
    }

    /// Blur: flush the active island and swap its row back to read-only.
    public func deactivate() {
        guard activeIsland != nil else {
            state = .idle
            return
        }
        flushActiveIsland()
        recycler.editingBlockID = nil
        state = .idle
    }

    // MARK: - Flush

    /// Read the outgoing island's live text + caret and emit `onReconcile`, then
    /// drop the active island. Leaves the recycler row alone — the caller either
    /// re-points `editingBlockID` at the incoming block (swap) or clears it
    /// (deactivate).
    private func flushActiveIsland() {
        guard let island = activeIsland else { return }
        state = .pendingFlush(island.originBlockID)
        let textView = recycler.currentEditorCell?.islandTextView
        let text = textView?.string ?? ""
        let caret = textView?.selectedRange().location ?? 0
        onReconcile?(ByteRange(island.byteRange), text, caret)
        activeIsland = nil
    }

    // MARK: - IME probe

    private func currentHasMarkedText() -> Bool {
        if let probe = hasMarkedTextProbe { return probe() }
        return recycler.currentEditorCell?.islandTextView.hasMarkedText() ?? false
    }

    // MARK: - Caret placement

    /// Place the caret in `textView` nearest `localPoint` (the click's cell-local
    /// point). Uses the text view's own hit-testing —
    /// `characterIndexForInsertion(at:)` resolves nearest-line-by-y then
    /// nearest-glyph-by-x, the "safe default" the brief prescribes — clamped into
    /// range. Empty source lands the caret at 0.
    private func placeCaret(in textView: NSTextView, atLocalPoint localPoint: CGPoint) {
        let length = (textView.string as NSString).length
        guard length > 0 else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            return
        }
        let index = textView.characterIndexForInsertion(at: localPoint)
        let clamped = max(0, min(index, length))
        textView.setSelectedRange(NSRange(location: clamped, length: 0))
    }
}
#endif
