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

    /// The most recent parse of the document the island lives in. Threaded so
    /// structural ops that reach OUTSIDE the island's own text — Task 7's
    /// Backspace-merge, which deletes the inter-block separator — can locate the
    /// predecessor block and compute their `SourceEdit` against the CURRENT
    /// document, never a stale one (CLAUDE.md: "a SourceEdit must be COMPUTED
    /// where it is APPLIED"). Set at `activate(...)` and refreshed at the top of
    /// `applyReconciled(...)` (every branch, before any early return).
    private var currentDocument: QuoinDocument?

    /// Task 7 (Fix round 1): a Backspace-merge that must wait for a preceding
    /// debounced (KEEP) flush's apply to LAND before it fires. In the real app
    /// `onReconcile` is async (`Task { await onReconcile(...); applyReconciled(...) }`),
    /// so when `handleBackspace` flushes a pending edit the flush's apply is NOT
    /// complete when it returns — firing the merge as a sibling Task would race the
    /// flush (unstructured-`Task` @MainActor enqueue order is not FIFO). Instead the
    /// merge is DEFERRED: set here, consumed at the END of the next `applyReconciled`
    /// (the flush's), which recomputes the predecessor + separator against the now-
    /// refreshed document and fires the merge. This makes flush-before-merge ordering
    /// GUARANTEED, and — because the recompute runs post-flush — removes the
    /// stale-offset reliance entirely (the separator invariant holds against the
    /// actual current document).
    private var pendingMergeAfterFlush = false

    /// The `BlockKind` of the block the active island currently hosts, threaded at
    /// `activate` and kept in step with the hosted block across KEEP re-anchors and
    /// SPLIT re-homes. The Return handler (Task 5) classifies on this via
    /// `ReturnSemantics.mode(for:)`. `nil` whenever there is no active island.
    public private(set) var activeIslandKind: BlockKind?

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
    // Minor fix (stale-range guard): true from the moment a KEEP reconcile fires
    // `onReconcile` until the app hands the resulting document back through
    // `applyReconciled` and the island's `byteRange` is re-anchored. A second
    // `reconcileNow` MUST NOT compute a whole-island replace against a byteRange
    // that the in-flight apply is about to move — it would splice a stale span.
    // While set, `reconcileNow` re-arms the debounce instead of firing. Cleared in
    // `applyReconciled` and `teardownIsland` (both terminate an in-flight apply).
    private var reconcileInFlight = false

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

    // Observer token for `NSWindow.didResignKeyNotification`. When the app loses
    // key window (e.g. Cmd-Tab away) the text view keeps first responder — so the
    // blur seam does NOT fire — but any pending edits should still be persisted.
    // We flush the KEEP-path reconcile WITHOUT tearing the island down, so the
    // user returns to the same active island with their typing already applied.
    private var resignKeyObserver: NSObjectProtocol?

    public init(recycler: BlockRecyclerView) {
        self.recycler = recycler
        // Install the reconcile-debounce fan-out. The recycler stays the SOLE
        // owner of the editing cell's `onTextDidChange` slot; it fans that signal
        // out to BOTH its row-height re-notify and this closure (Task 6).
        recycler.onEditingTextChanged = { [weak self] in
            self?.islandTextDidChange()
        }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowDidResignKey() }
        }
    }

    deinit {
        reconcileTimer?.invalidate()
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
    }

    /// The app lost key window while an island is active: flush pending edits
    /// through the existing KEEP reconcile path (no teardown — the island stays
    /// active). No-op when nothing is pending or there is no active island.
    private func windowDidResignKey() {
        guard activeIsland != nil else { return }
        flushPendingReconcile()
    }

    // MARK: - Activation

    /// Activation intent from the recycler's click seam: promote `blockID`'s row
    /// to an editable island, seed it, first-respond, and place the caret near
    /// `localPoint` (the click's cell-local point). Flushes any current island
    /// first. Refuses (parks in `.blockedIME`) if a live IME composition would
    /// be dropped by the swap.
    public func activate(blockID: BlockID, localPoint: CGPoint,
                         in document: QuoinDocument, baseRevision: Int) {
        // Retain the freshest parse so structural ops (Backspace-merge) resolve
        // the predecessor block against the current document.
        currentDocument = document
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
            // Blur seam: a click outside the island — or the window handing first
            // responder to another view — flushes + swaps this row back to
            // read-only. A responder override, NOT a delegate method, so the
            // cell's ChangeForwarder delegate is untouched.
            cell.onResignFirstResponder = { [weak self] in self?.deactivate() }
            // Return-key seam (Task 5): route Return through the controller so it
            // splits per `ReturnSemantics`. A nil return (no island / composing /
            // out-of-scope kind) falls through to the native newline.
            cell.onInsertNewline = { [weak self] in self?.handleReturn() ?? false }
            // Backspace-key seam (Task 7): route Backspace through the controller
            // so a caret at island start MERGES the block into its predecessor. A
            // nil return (no island / not at start / no predecessor / composing)
            // falls through to the native within-island delete.
            cell.onDeleteBackward = { [weak self] in self?.handleBackspace() ?? false }
            cell.window?.makeFirstResponder(cell.islandTextView)
            placeCaret(in: cell.islandTextView, atLocalPoint: localPoint)
            recycler.noteEditingRowHeight()
        }

        activeIsland = island
        activeIslandKind = block.kind
        // Fresh island: clear any reconcile carry-over from the previous one.
        pendingReconcile = false
        wasComposing = false
        reconcileInFlight = false
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

    // MARK: - Return (Phase 3, Task 5)

    /// Return pressed inside the active island. Classifies on the island block's
    /// `ReturnSemantics.mode` and performs the structural insert on the island's
    /// `NSTextView` through the NATIVE input path (`insertText`), so TextKit
    /// updates, the cell's change notification fires, and the debounce reconcile +
    /// Task-4 re-activate-at-caret primitive re-homes the island into the block the
    /// caret now sits in.
    ///
    /// Returns `true` to CONSUME the keystroke (a structural op handled it — the
    /// `IslandTextView` override does NOT call `super`); `false` falls through to
    /// the native `insertNewline:` (a plain `\n`). Falls through when there is no
    /// active island, mid-IME-composition (never split into marked text — Task 3's
    /// composing-edge discipline), or for the not-yet-implemented list/quote/table
    /// modes (Task 6).
    public func handleReturn() -> Bool {
        guard let kind = activeIslandKind,
              let textView = recycler.currentEditorCell?.islandTextView else {
            return false
        }
        // Never split mid-composition: splicing into half-composed marked text
        // corrupts the source. Let native handle the newline.
        if currentHasMarkedText() { return false }

        switch ReturnSemantics.mode(for: kind) {
        case .paragraphBreak:
            // Markdown separates blocks with a BLANK line, so `\n\n` is what makes
            // the reparse yield two blocks; a lone `\n` is a soft break (same block).
            insertAndSeatCaret("\n\n", in: textView)
            return true
        case .verbatim:
            // A newline inside a verbatim block (code/math/…) stays IN-block — the
            // reparse keeps one block and Task-4's KEEP path re-seeds 1:1, no split.
            insertAndSeatCaret("\n", in: textView)
            return true
        case .listAware:
            return handleListReturn(in: textView, quote: false)
        case .quoteAware:
            return handleListReturn(in: textView, quote: true)
        case .tableRow:
            // Task 6b/Phase 4: table-row skeleton. A blank line TERMINATES a
            // table, so NEVER insert `\n\n` here — fall through to native.
            return false
        }
    }

    /// Return inside a list (`quote == false`) or block-quote (`quote == true`)
    /// island. Reads the current line UP TO THE CARET off the live text view,
    /// asks the pure `ListContinuation` engine what to do, and realizes it:
    ///
    /// - `.continue(str)`: splice `str` (a `\n` + fresh marker) at the caret. The
    ///   list/quote is ONE cmark block, so the reparse keeps it one block with an
    ///   extra item → the debounce reconcile rides Task 4's KEEP re-anchor (1:1,
    ///   `activeIslandKind` stays the list/quote kind), NOT the split re-home.
    /// - `.exit`: DELETE the empty marker on the current line (the whole
    ///   `lineStart ..< caret` prefix, which for an empty item IS the marker), so
    ///   the trailing item collapses to a blank line. For a list/quote at the END
    ///   of the document, Task 5's terminal-empty-paragraph branch keeps the
    ///   island alive on the blank line; a MID-document exit-to-empty-paragraph
    ///   shares the deferred Task 5b representation gap (may tear down) — both are
    ///   handled gracefully (never a crash, never a byte-corrupting splice).
    ///
    /// Always returns `true` (the structural op consumed the Return).
    private func handleListReturn(in textView: NSTextView, quote: Bool) -> Bool {
        let ns = textView.string as NSString
        let caret = textView.selectedRange().location
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        let lineStart = lineRange.location
        let lineUpToCaret = ns.substring(with: NSRange(location: lineStart,
                                                       length: caret - lineStart))
        let result = quote
            ? ListContinuation.quote(lineUpToCaret: lineUpToCaret)
            : ListContinuation.list(lineUpToCaret: lineUpToCaret)

        switch result {
        case .continue(let insertion):
            insertAndSeatCaret(insertion, in: textView)
        case .exit:
            // Delete the empty marker (lineStart ..< caret) to collapse the item.
            let markerRange = NSRange(location: lineStart, length: caret - lineStart)
            textView.insertText("", replacementRange: markerRange)
            textView.setSelectedRange(NSRange(location: lineStart, length: 0))
        }
        return true
    }

    /// Insert `text` at the island's selection through the NATIVE `NSTextInputClient`
    /// entry point (so the cell's `textDidChange` fires → reconcile debounce), then
    /// seat the caret past the insertion. Seating is explicit because a headless
    /// `insertText` does not advance the selection; on the live first responder the
    /// caret is already there, so re-seating to the same offset is a no-op — either
    /// way the post-Return caret is deterministic.
    private func insertAndSeatCaret(_ text: String, in textView: NSTextView) {
        let sel = textView.selectedRange()
        textView.insertText(text, replacementRange: sel)
        let newCaret = sel.location + (text as NSString).length
        textView.setSelectedRange(NSRange(location: newCaret, length: 0))
    }

    // MARK: - Backspace-merge (Phase 3, Task 7)

    /// Backspace pressed inside the active island. When the caret sits at the
    /// island's START with an EMPTY selection, MERGE the island's block into its
    /// predecessor by deleting the inter-block separator; otherwise fall through
    /// to the native within-island delete.
    ///
    /// Returns `true` to CONSUME the keystroke (the `IslandTextView` override does
    /// NOT call `super`); `false` falls through to the native `deleteBackward:`.
    /// Falls through (native) when: there is no active island, an IME composition
    /// is live, the caret is not at `{0,0}` (any non-zero location OR a non-empty
    /// selection is a normal within-island delete), or the island is already the
    /// FIRST block (no predecessor — never a splice).
    ///
    /// The merge is NOT expressible as a native in-island edit: the deleted bytes
    /// are the inter-block SEPARATOR, which lives OUTSIDE the island's own text.
    /// So it is emitted directly through the controller's existing `onReconcile`
    /// seam (the same channel `reconcileNow`/`flushActiveIsland` use), and
    /// `applyReconciled` re-homes the island onto the merged block with the caret
    /// at the join.
    public func handleBackspace() -> Bool {
        // Only act on the LIVE island cell; a missing/mismatched cell → native.
        guard let cell = recycler.currentEditorCell,
              let island = activeIsland,
              cell.blockID == island.originBlockID else {
            return false
        }
        let textView = cell.islandTextView
        // Never merge mid-composition: splicing around half-composed marked text
        // corrupts the source. Let native handle the delete.
        if currentHasMarkedText() { return false }
        // Consume ONLY at the island's very start with an EMPTY selection. The
        // comparison pins BOTH location AND length: a non-empty selection anchored
        // at location 0 (`{0, n}`) is a native selection-delete, NOT a merge.
        guard textView.selectedRange() == NSRange(location: 0, length: 0) else {
            return false
        }
        guard let document = currentDocument else { return false }

        // The CONSUME decision is made SYNCHRONOUSLY from caret == {0,0} +
        // predecessor-exists. Predecessor-existence is stable across a KEEP flush
        // (a debounced typing edit never changes the block STRUCTURE), so the
        // possibly-stale current document answers it authoritatively even before a
        // pending edit is flushed. No predecessor → the island is the first block →
        // native no-op; NEVER splice with a nil record.
        guard predecessorRecord(before: island.byteRange.lowerBound, in: document) != nil else {
            return false
        }

        // ORDERING (Fix round 1): if a debounced KEEP edit is pending, the real
        // app's `onReconcile` is async, so the flush's apply lands LATER. Firing
        // the merge now would race it (non-FIFO Tasks) and could splice the merge
        // FIRST, leaving the flush's whole-island range to overrun the shrunken
        // document (the CLAUDE.md "compute-where-applied / stale-base" bug class).
        // Defer the merge behind the flush: flush now, and let the flush's
        // `applyReconciled` fire the merge once it has landed and refreshed the
        // document + island range. When nothing is pending, the flush is a no-op
        // and we fire the merge immediately (unchanged from the original path).
        if pendingReconcile {
            pendingMergeAfterFlush = true
            flushPendingReconcile()
        } else {
            fireBackspaceMerge()
        }
        return true
    }

    /// The block immediately before `islandStart`: the record whose content ends at
    /// or before it, nearest to it. `nil` when the island is the first block.
    private func predecessorRecord(before islandStart: Int,
                                   in document: QuoinDocument) -> BlockRecord? {
        BlockListModel(document: document).records
            .filter { $0.byteRange.upperBound <= islandStart }
            .max(by: { $0.byteRange.upperBound < $1.byteRange.upperBound })
    }

    /// Compute the separator-delete `SourceEdit` against the CURRENT document and
    /// fire it through the existing `onReconcile` seam. Recomputes predecessor +
    /// separator live (post-flush when deferred) so the offsets are never stale.
    ///
    /// JOIN RULE: replace the inter-block separator bytes
    /// `[prev.upperBound, islandStart)` with "" — the island's block MERGES INTO
    /// the previous block (e.g. "First\n\nSecond" → "FirstSecond", ONE block); the
    /// reparse decides the merged block's kind. The island-local caret is 0 (island
    /// start); in the "" replacement that maps to
    /// `caretDocByte == separator.lowerBound == prev.byteRange.upperBound`, the join
    /// (where the predecessor's content ends and the merged-in text begins).
    /// `lastFlushedText`/`reconcileInFlight` mirror `reconcileNow` so the in-flight
    /// guard holds and `applyReconciled`'s KEEP check fails (the merged block's
    /// content is NOT the old island text) → the re-home runs. Guarded so a lost
    /// island / vanished predecessor / empty separator NEVER splices.
    private func fireBackspaceMerge() {
        guard let island = activeIsland, let document = currentDocument,
              let cell = recycler.currentEditorCell,
              cell.blockID == island.originBlockID else { return }
        let islandStart = island.byteRange.lowerBound
        guard let prev = predecessorRecord(before: islandStart, in: document) else { return }
        let separator = prev.byteRange.upperBound ..< islandStart
        // EMPTY-SPLICE GUARD: only fire for a real, positive-length separator.
        guard separator.lowerBound < separator.upperBound else { return }
        lastFlushedText = cell.islandTextView.string
        reconcileInFlight = true
        onReconcile?(ByteRange(separator), "", 0)
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
        // CRITICAL guard: a missing editor cell must NEVER cause a splice. If the
        // live island cell is gone (e.g. a projection refresh reloaded the row out
        // from under us, or the row is not realized), we have NO trustworthy island
        // text. Falling back to `textView?.string ?? ""` here fires
        // `onReconcile(range, "")`, which splices the block's byte range with an
        // EMPTY STRING and DELETES its content. Bail: drop the island WITHOUT
        // firing onReconcile.
        guard let textView = recycler.currentEditorCell?.islandTextView else {
            activeIsland = nil
            activeIslandKind = nil
            lastFlushedText = nil
            reconcileInFlight = false
            state = .idle
            return
        }
        let text = textView.string
        let caret = textView.selectedRange().location
        // Drop the island FIRST so any synchronous applyReconciled is inert.
        activeIsland = nil
        activeIslandKind = nil
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
            // Phase 3: if an activation is parked, its replay below will flush
            // the outgoing island TERMINALLY via `activate`'s own
            // `flushActiveIsland()` — do NOT also KEEP-reconcile it here, or the
            // same block fires `onReconcile` twice with identical content (the
            // second lands on a stale `baseRevision` once the app applies the
            // first and trips the staleness guard). Skip straight to the drain;
            // its terminal flush is the single reconcile for this commit.
            if pendingIntent != nil {
                drainPendingIntent()
            } else {
                reconcileNow()
            }
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
        // Minor fix (stale-range guard): a prior reconcile's apply/re-anchor is
        // still in flight, so `island.byteRange` is about to move. Computing a
        // whole-island replace against it now would splice a stale span. Leave
        // `pendingReconcile` set and re-arm the debounce so this fires once the
        // re-anchor lands.
        if reconcileInFlight {
            scheduleReconcileTimer()
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
        reconcileInFlight = true
        onReconcile?(ByteRange(island.byteRange), newText, caret)
    }

    /// Re-anchor handoff from the app after it applies the most recently fired
    /// reconcile edit. Two outcomes:
    ///
    /// **KEEP (no structural change):** the island's origin byte still resolves to
    /// a block whose content is EXACTLY the text the island flushed → re-anchor the
    /// byte range + origin block id in place and re-seat the caret. The
    /// `IslandUnit.id` is preserved.
    ///
    /// **SPLIT / structural change (Phase 3, Task 4 — the re-activate-at-caret
    /// primitive):** the flushed text no longer maps 1:1 (an interior newline split
    /// the block, or it merged with a neighbour). Instead of Phase-2's teardown, the
    /// island is RE-HOMED into the block that CONTAINS the reconcile-time caret
    /// (`caretDocByte`): re-anchor onto that block, re-seed the island cell's source
    /// from the block's bytes, and seat the caret there. This branch NEVER splices —
    /// only re-anchors + re-seeds the view (the edit is already applied). When no
    /// caret is supplied (legacy callers) or the caret fell into a separator gap
    /// (shouldn't happen for a real caret), it falls back to the safe `teardownIsland`.
    ///
    /// `caretDocByte` is the absolute UTF-8 byte offset of the reconcile-time caret,
    /// computed at FLUSH time (`island.byteRange.lowerBound +
    /// UTF8IndexMap(flushedText).utf8(fromUTF16: caret)` — bytes before the caret
    /// don't move), NOT a live `selectedRange()` re-read (the cell may be gone after
    /// a split). Additive + defaulted so pre-Task-4 callers keep compiling.
    public func applyReconciled(_ newDocument: QuoinDocument, caretDocByte: Int? = nil) {
        // The in-flight apply has landed — clear the stale-range guard regardless
        // of the outcome below.
        reconcileInFlight = false
        // Refresh the retained parse in EVERY branch (before any early return) so
        // a subsequent structural op sees the latest document.
        currentDocument = newDocument
        // Fix round 1: a Backspace-merge deferred behind THIS (KEEP-flush) apply
        // fires once it has landed — recomputing predecessor + separator against
        // the now-refreshed document/island range and firing through onReconcile.
        // Runs at EVERY exit (whichever branch the flush took), and at most once:
        // the flag is cleared before the merge, so the merge's own applyReconciled
        // is a no-op here (no re-entrant loop).
        defer {
            if pendingMergeAfterFlush {
                pendingMergeAfterFlush = false
                fireBackspaceMerge()
            }
        }
        guard let island = activeIsland, let flushed = lastFlushedText else { return }
        let model = BlockListModel(document: newDocument)

        // KEEP: the island's origin byte still resolves to a block whose content is
        // EXACTLY the flushed text → 1:1 re-anchor in place. The byte-range OFFSET is
        // unchanged (bytes before the island never moved) but its length tracks the
        // new text; the origin block id changes (content-hash) so hand it to the
        // recycler so its editing identity tracks in lockstep across the projection
        // refresh (`updateDocumentPreservingEditing`).
        if let record = model.record(at: island.byteRange.lowerBound),
           newDocument.source.substring(in: ByteRange(record.byteRange)) == flushed {
            let oldStart = island.byteRange.lowerBound
            activeIsland?.byteRange = record.byteRange
            activeIsland?.originBlockID = record.blockID
            activeIslandKind = record.kind
            recycler.reanchorEditing(to: record.blockID)
            if let textView = recycler.currentEditorCell?.islandTextView {
                // Prefer the flush-time caret (`caretDocByte`); fall back to a live
                // re-read for legacy callers that pass no caret.
                let reseated: Int?
                if let caretDocByte {
                    reseated = IslandCaretMapping.localUTF16(
                        documentByte: caretDocByte, islandSource: flushed,
                        islandByteStart: record.byteRange.lowerBound)
                } else {
                    let localCaret = textView.selectedRange().location
                    reseated = IslandCaretMapping.documentByte(
                        localUTF16: localCaret, islandSource: flushed, islandByteStart: oldStart)
                        .flatMap {
                            IslandCaretMapping.localUTF16(
                                documentByte: $0, islandSource: flushed,
                                islandByteStart: record.byteRange.lowerBound)
                        }
                }
                if let reseated {
                    let length = (textView.string as NSString).length
                    textView.setSelectedRange(
                        NSRange(location: max(0, min(reseated, length)), length: 0))
                }
            }
            return
        }

        // No caret (legacy caller) → safe teardown; the edit is already applied.
        guard let caretDocByte else {
            teardownIsland()
            return
        }

        // TERMINAL EMPTY PARAGRAPH (Task 5): Return at the END of the document's
        // LAST block yields a trailing blank-line gap ("Hello" → "Hello\n\n") that
        // Markdown cannot represent as a second block, so the reconcile-time caret
        // byte lands PAST all block content, at document end. `record(at:)` returns
        // nil there. Tearing down here IS the original Return-at-end bug (a dead
        // caret, next keystroke on the wrong block). Instead — matching the design
        // doc's "the last block absorbs through EOF" — keep the island on the LAST
        // block with its slice EXTENDED through the caret to host the trailing
        // newlines, caret on the now-occupiable blank line. The NEXT keystroke
        // splices at the caret and materializes the new block, and the normal
        // re-home (below) then lands the island onto it. Guarded to the LAST block
        // (caret at/after its content end): a mid-document end-of-paragraph gap is a
        // separate, recycler-level feature (occupiable blank lines) still deferred.
        if model.record(at: caretDocByte) == nil,
           let last = model.records.last,
           caretDocByte >= last.byteRange.upperBound {
            let extended = last.byteRange.lowerBound ..< caretDocByte
            let extendedSlice = newDocument.source.substring(in: ByteRange(extended)) ?? flushed
            activeIsland?.byteRange = extended
            activeIsland?.originBlockID = last.blockID
            activeIslandKind = last.kind
            // The island now flushes the extended (block + trailing gap) slice; keep
            // `lastFlushedText` in step so the next reconcile's whole-island replace
            // maps against it.
            lastFlushedText = extendedSlice
            recycler.reanchorEditing(to: last.blockID)
            if let textView = recycler.currentEditorCell?.islandTextView {
                // The cell already hosts the extended slice (the user just typed the
                // break into it) — do NOT re-seed. Seat the caret at the trailing gap.
                let reseated = IslandCaretMapping.localUTF16(
                    documentByte: caretDocByte, islandSource: extendedSlice,
                    islandByteStart: extended.lowerBound) ?? (extendedSlice as NSString).length
                let length = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: max(0, min(reseated, length)), length: 0))
            }
            return
        }

        // SPLIT / structural change → RE-ACTIVATE AT CARET. Re-home the island onto
        // the block that now CONTAINS the reconcile-time caret. Caret in a separator
        // gap (not the terminal case above) → safe teardown (the edit is applied).
        guard let rec = model.record(at: caretDocByte) else {
            teardownIsland()
            return
        }
        let islandSource = newDocument.source.substring(in: ByteRange(rec.byteRange)) ?? ""
        activeIsland?.byteRange = rec.byteRange
        activeIsland?.originBlockID = rec.blockID
        activeIslandKind = rec.kind
        // The island now flushes the caret block's text; keep `lastFlushedText` in
        // step so a subsequent KEEP reconcile maps 1:1 against it.
        lastFlushedText = islandSource
        recycler.reanchorEditing(to: rec.blockID)
        if let textView = recycler.currentEditorCell?.islandTextView {
            // Re-seed the island cell's source from the caret block's bytes (NOT a
            // user edit — swap the string directly, which does not re-fire the
            // reconcile debounce).
            if textView.string != islandSource {
                textView.string = islandSource
            }
            let reseated = IslandCaretMapping.localUTF16(
                documentByte: caretDocByte, islandSource: islandSource,
                islandByteStart: rec.byteRange.lowerBound) ?? 0
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: max(0, min(reseated, length)), length: 0))
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
        reconcileInFlight = false
        activeIsland = nil
        activeIslandKind = nil
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

    /// Replay a parked activation once the composition that blocked it has
    /// committed. Clears `pendingIntent` FIRST — re-entrancy safety: the
    /// replayed `activate` may itself re-park (a fresh composition started in
    /// the window between commit and replay), and that must not stomp on the
    /// intent this call is in the middle of draining. No-op when nothing is
    /// parked.
    private func drainPendingIntent() {
        guard let intent = pendingIntent else { return }
        pendingIntent = nil
        activate(blockID: intent.blockID, localPoint: intent.localPoint,
                 in: intent.document, baseRevision: intent.baseRevision)
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
