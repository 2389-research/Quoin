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
    /// session. Fired on every flush — the per-keystroke debounce (KEEP path),
    /// the swap-out, and blur — with the island's byte range, its current text,
    /// and the island-local UTF-16 caret. The app applies the corresponding
    /// `SourceEdit(range:replacement:)` through the session; for the KEEP path it
    /// then hands the resulting document back via `applyReconciled(_:)` so the
    /// island re-anchors. Terminal flushes (swap/deactivate) drop the island, so
    /// they need no `applyReconciled`.
    public var onReconcile: ((ByteRange, String, _ islandUTF16Caret: Int) -> Void)?

    /// The debounce idle window before a KEEP-path reconcile fires (~200 ms in
    /// production). Injectable so tests can drive `flushPendingReconcile()`
    /// deterministically instead of sleeping on a real timer.
    public var reconcileDebounceInterval: TimeInterval = 0.2

    // KEEP-path reconcile bookkeeping. `pendingReconcile` marks that live island
    // text has changed since the last flush; `reconcileTimer` is the debounce.
    // `wasComposing` tracks the IME marked-text edge so a composition commit
    // flushes immediately (not after another idle window). `lastFlushedText` is
    // the text most recently sent through `onReconcile`, against which
    // `applyReconciled` verifies the re-anchored block still maps 1:1.
    private var pendingReconcile = false
    private var reconcileTimer: Timer?
    private var wasComposing = false
    private var lastFlushedText: String?

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
        // Install the reconcile-debounce fan-out. The recycler stays the SOLE
        // owner of the editing cell's `onTextDidChange` slot; it fans that signal
        // out to BOTH its row-height re-notify and this closure (Task 6).
        recycler.onEditingTextChanged = { [weak self] in
            self?.islandTextDidChange()
        }
    }

    deinit {
        reconcileTimer?.invalidate()
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
        // Fresh island: clear any reconcile carry-over from the previous one.
        pendingReconcile = false
        wasComposing = false
        lastFlushedText = nil
        cancelReconcileTimer()
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
    /// (deactivate). This is a TERMINAL flush: the island is dropped BEFORE
    /// `onReconcile` fires, so a synchronous `applyReconciled` from the app's
    /// apply is a no-op (there is nothing left to re-anchor).
    private func flushActiveIsland() {
        guard let island = activeIsland else { return }
        cancelReconcileTimer()
        pendingReconcile = false
        state = .pendingFlush(island.originBlockID)
        let textView = recycler.currentEditorCell?.islandTextView
        let text = textView?.string ?? ""
        let caret = textView?.selectedRange().location ?? 0
        // Drop the island FIRST so any synchronous applyReconciled is inert.
        activeIsland = nil
        lastFlushedText = text
        onReconcile?(ByteRange(island.byteRange), text, caret)
    }

    // MARK: - Reconciliation (Phase 2, Task 6) — the KEEP path

    /// The editing cell's live text changed. Debounce a KEEP-path reconcile,
    /// except: while an IME composition is live (marked text present) hold —
    /// splicing half-composed characters would corrupt the source — and flush
    /// IMMEDIATELY on the keystroke that clears the composition.
    private func islandTextDidChange() {
        guard activeIsland != nil else { return }
        let composing = currentHasMarkedText()
        if composing {
            // Mid-composition: park the pending flush, stop the debounce so it
            // can't fire into marked text.
            wasComposing = true
            pendingReconcile = true
            cancelReconcileTimer()
            return
        }
        if wasComposing {
            // The composition just committed — flush now, not after another idle
            // window (the "hasMarkedText clears" immediate-flush rule).
            wasComposing = false
            pendingReconcile = true
            reconcileNow()
            return
        }
        pendingReconcile = true
        scheduleReconcileTimer()
    }

    /// Flush a pending KEEP-path reconcile synchronously if one is due. Wired to
    /// the debounce timer in production; called directly by tests to flush
    /// deterministically without waiting on the real 200 ms window.
    public func flushPendingReconcile() {
        reconcileNow()
    }

    /// Build the `SourceEdit` from the live island text and fire `onReconcile`
    /// (KEEP semantics: the island stays active; the app hands the resulting
    /// document back through `applyReconciled`). No-op when nothing is pending,
    /// there is no active island, or an IME composition is still live.
    private func reconcileNow() {
        cancelReconcileTimer()
        guard pendingReconcile, let island = activeIsland else {
            pendingReconcile = false
            return
        }
        guard let cell = recycler.currentEditorCell,
              cell.blockID == island.originBlockID else { return }
        // Never splice mid-composition; the commit keystroke will re-drive this.
        if currentHasMarkedText() { return }
        pendingReconcile = false
        let newText = cell.islandTextView.string
        let caret = cell.islandTextView.selectedRange().location
        lastFlushedText = newText
        onReconcile?(ByteRange(island.byteRange), newText, caret)
    }

    /// KEEP-path re-anchor. The app calls this with the document produced by
    /// applying the most recently fired reconcile edit. Re-runs `BlockListModel`
    /// over the new document and finds the block that 1:1 corresponds to the
    /// edited island — same origin byte position, and content EXACTLY the text
    /// the island flushed. If no single block maps 1:1 (an interior newline split
    /// the block, or it merged with a neighbour) the island is torn down per the
    /// NO-STRUCTURAL-OPS rule — WITHOUT a re-flush (the edit is already applied);
    /// we do not hop the caret into a split block or merge. Otherwise the
    /// island's byte range is re-anchored and the caret re-seeded through
    /// `IslandCaretMapping`.
    public func applyReconciled(_ newDocument: QuoinDocument) {
        guard let island = activeIsland, let flushed = lastFlushedText else { return }
        let model = BlockListModel(document: newDocument)
        guard let record = model.record(at: island.byteRange.lowerBound),
              newDocument.source.substring(in: ByteRange(record.byteRange)) == flushed else {
            // Structural change: no clean 1:1 mapping → deactivate cleanly.
            teardownIsland()
            return
        }
        // 1:1 KEEP: re-anchor the byte range (its offset is unchanged — bytes
        // before the island never moved — but the length tracks the new text)
        // and re-seed the caret through the map. The IslandUnit.id is preserved.
        let oldStart = island.byteRange.lowerBound
        activeIsland?.byteRange = record.byteRange
        if let textView = recycler.currentEditorCell?.islandTextView {
            let localCaret = textView.selectedRange().location
            if let docByte = IslandCaretMapping.documentByte(
                    localUTF16: localCaret, islandSource: flushed, islandByteStart: oldStart),
               let reseated = IslandCaretMapping.localUTF16(
                    documentByte: docByte, islandSource: flushed,
                    islandByteStart: record.byteRange.lowerBound) {
                let length = (textView.string as NSString).length
                textView.setSelectedRange(
                    NSRange(location: max(0, min(reseated, length)), length: 0))
            }
        }
    }

    /// Tear the island down WITHOUT a flush (the edit that split the block is
    /// already applied): drop the island, clear the editing row, settle idle.
    /// Same observable end state `deactivate()` reaches (idle, no island) but
    /// without re-firing `onReconcile` — re-flushing here would re-apply the
    /// text against a now-stale byte range.
    private func teardownIsland() {
        cancelReconcileTimer()
        pendingReconcile = false
        wasComposing = false
        activeIsland = nil
        lastFlushedText = nil
        recycler.editingBlockID = nil
        state = .idle
    }

    // MARK: - Debounce timer

    private func scheduleReconcileTimer() {
        cancelReconcileTimer()
        reconcileTimer = Timer.scheduledTimer(
            withTimeInterval: reconcileDebounceInterval, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileNow() }
        }
    }

    private func cancelReconcileTimer() {
        reconcileTimer?.invalidate()
        reconcileTimer = nil
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
