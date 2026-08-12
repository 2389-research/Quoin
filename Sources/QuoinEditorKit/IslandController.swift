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
    /// where it is APPLIED"). Set at `activate(...)`, refreshed at the top of
    /// `applyReconciled(...)` (every branch, before any early return), AND at every
    /// document refresh the recycler projects (`revalidateForDocumentRefresh`) —
    /// that last one is what makes the flush-time drift check (I4) able to see an
    /// EXTERNALLY-driven change (undo/redo, format command, task toggle, conflict
    /// resolution, external file adoption) at all.
    private var currentDocument: QuoinDocument?

    /// The document revision in effect for `currentDocument`. Carried so the IME
    /// drain can replay a parked activation against the CURRENT revision (I3)
    /// instead of the one captured at click time.
    private var currentBaseRevision: Int = 0

    // MARK: - The island's ANCHOR (I4)

    /// The exact bytes the active island is anchored to: what
    /// `currentDocument.source` holds at `activeIsland.byteRange` right now.
    ///
    /// This is the island's contract with the document, and it is DISTINCT from
    /// `lastFlushedText` (which is the "did the user actually change anything"
    /// baseline and is written OPTIMISTICALLY at fire time, before the apply
    /// lands). `anchoredSource` only ever advances at points where the document is
    /// KNOWN to hold it: activation, each `applyReconciled` branch, and an accepted
    /// external revalidation.
    ///
    /// Every splice the controller emits is byte-re-validated against it first
    /// (`anchorIsIntact`) — the CLAUDE.md "refuse-on-drift byte re-validation"
    /// pattern. If the document underneath the island moved (⌘Z is the canonical
    /// case) the anchor no longer matches and the splice is REFUSED rather than
    /// written at the wrong offsets.
    private var anchoredSource: String?

    /// The island block's INDEX in `currentDocument.blocks`. Paired with the start
    /// byte in `revalidateForDocumentRefresh`: a start byte that still lands on a
    /// block START could, after a shift, be a DIFFERENT block's start (the shift
    /// happened to equal an inter-block-start distance). Requiring the index to
    /// match too makes that coincidence non-silent.
    private var activeIslandIndex: Int?

    // MARK: - The VIRTUAL LINE (Phase 3, Task 5b)

    /// Non-nil while the island hosts a **transient, byte-less blank line**: a new
    /// empty paragraph the user has opened with Return but not yet typed into.
    ///
    /// ## Why this state has to exist
    ///
    /// Markdown has no empty-paragraph node. `First\n\nMiddle\n\nLast` and
    /// "…the same, with an empty paragraph between Middle and Last" are THE SAME
    /// BYTES — there is nothing to write, and nothing for cmark to parse into a
    /// block. So an interior end-of-block Return cannot be expressed as an edit,
    /// and the pre-5b code that tried (insert `\n\n`, flush) grew the file by two
    /// bytes and then dropped the island, because the reconcile-time caret landed
    /// in the inter-block gap where `BlockListModel.record(at:)` answers nil.
    ///
    /// ## What it is
    ///
    /// The island's TEXT VIEW shows `logical + "\n\n"` — the host block's real
    /// bytes plus a trailing blank line that exists ONLY in the text view — with
    /// the caret on that line. Everything that talks to the document keeps
    /// describing the HOST BLOCK ALONE: `activeIsland.byteRange`, `anchoredSource`,
    /// `activeIslandIndex` and the recycler's editing row are all untouched, so
    /// `anchorIsIntact`, `revalidateForDocumentRefresh` and
    /// `updateDocumentPreservingEditing` need no new cases — they never see the
    /// tail. The ONE seam that has to know is the flush, which writes
    /// `effectiveIslandText(live)` instead of the live string.
    ///
    /// ## The two exits
    ///
    ///  • **Abandoned** (blur / click-away / Escape / an external re-seed): the
    ///    effective text is the host slice, which the document already holds, so
    ///    the unchanged-text short-circuit fires. Zero bytes written, no undo
    ///    entry, no autosave — byte-losslessness by CONSTRUCTION, not by an
    ///    un-write.
    ///  • **Materialized** (a keystroke lands after the tail): the tail stops being
    ///    a tail, the effective text becomes the whole string, and ONE flush
    ///    replaces the host block's range with `logical + "\n\n" + typed`. The
    ///    separator that already followed the host block is OUTSIDE that range, so
    ///    it survives and the result is exactly `…Middle\n\nX\n\nLast`. The caret
    ///    then lands in a real block and the existing Task-4 re-home takes over.
    ///
    /// ## Why `tail` and `materializationSuffix` are DERIVED, not `"\n\n"`
    ///
    /// cmark's block ranges are not uniform about the newline that ends a block: a
    /// paragraph's range stops at its last character (`"Middle"`), a LIST's range
    /// includes its trailing newline (`"- a\n"`). So the blank line the caret needs
    /// is two newlines after a paragraph but only one after a list — and, on the
    /// other side, the inter-block gap left in the document is two bytes after a
    /// paragraph but only one after a list. Both quantities are therefore measured
    /// from the actual bytes (`virtualTail(for:)` / `materializationSuffix(for:)`);
    /// hard-coding `"\n\n"` on either side welds the new block onto its neighbour.
    private struct VirtualLine {
        /// The island's logical text when the line was opened. Diagnostics only —
        /// the LIVE logical text is always recomputed off the text view by stripping
        /// the affixes, so editing the host block with the line still open works.
        let openedWith: String
        /// The byte-less newlines the text view shows BEFORE the host block's text
        /// (Return at the block's START — the new empty paragraph goes ABOVE and
        /// the block is pushed down). Always `"\n\n"` or empty: a block's range
        /// never includes a LEADING newline, so unlike `tail` there is nothing to
        /// measure.
        let head: String
        /// The byte-less newlines the text view shows AFTER the host block's text
        /// (Return at the block's END). Whatever it takes to put the caret on a
        /// blank line BELOW a blank line — measured, see `virtualTail(for:)`.
        let tail: String
    }
    private var virtualLine: VirtualLine?

    /// Where a Return would put the new, byte-less empty paragraph.
    private enum VirtualLinePosition { case above, below }

    /// Test-only observability (anti-vacuity): the transient state itself, and how
    /// many times it was entered / materialized — so a test proves the INTERACTION
    /// happened, not just that some post-condition holds.
    var hasVirtualLineForTest: Bool { virtualLine != nil }
    private(set) var virtualLineEnteredCountForTest = 0
    private(set) var virtualLineMaterializedCountForTest = 0

    /// Test-only observability (anti-vacuity): how many times a splice was REFUSED
    /// by the flush-time drift check, and how many times an external document
    /// change forced the island down. `lastDiscardedIslandText` is the island text
    /// that was thrown away by the most recent refusal/teardown — the report's
    /// "what happens to unflushed keystrokes" answer, observable from a test.
    private(set) var refusedFlushCount = 0
    private(set) var invalidationTeardownCount = 0
    private(set) var lastDiscardedIslandText: String?

    // MARK: - The deferral channel (ordered work behind an in-flight apply)

    /// Work that MUST NOT fire until the currently in-flight `onReconcile` apply has
    /// LANDED (i.e. the app has called `applyReconciled`). In the real app
    /// `onReconcile` is async (`Task { await onReconcile(...); applyReconciled(...) }`),
    /// so anything fired as a sibling `Task` races it — unstructured-`Task`
    /// @MainActor enqueue order is not FIFO — and would splice against offsets the
    /// in-flight apply is about to move (the CLAUDE.md "compute-where-applied /
    /// stale-base" bug class).
    ///
    /// This is the ONE deferral channel (Task 7 built it for the Backspace-merge;
    /// the Phase-3 critical-fix wave generalized it rather than adding a second):
    /// entries are appended in order and drained ONE PER `applyReconciled`, so each
    /// deferred op is itself ordered behind the op before it.
    private enum DeferredOp {
        /// A Backspace-merge, KEYED to the island that armed it (C2). At consume
        /// time `fireBackspaceMerge` re-resolves the predecessor/separator from
        /// whatever island is CURRENT, so an unkeyed flag would happily merge the
        /// neighbours of a completely different block the user has since clicked
        /// into. The key makes a stale merge a no-op instead.
        case backspaceMerge(IslandUnitID)
        /// A TERMINAL flush (swap-out / blur) that arrived while an apply was in
        /// flight (C1). The island is already gone, so there is nothing left to
        /// re-anchor — the op carries everything needed to splice the outgoing
        /// text exactly once, against the document the in-flight apply produces.
        case terminalFlush(TerminalFlush)
    }

    /// A terminal flush parked behind an in-flight apply. It records the island's
    /// START byte (bytes BEFORE an island never move across its own edits) and the
    /// text the in-flight apply is writing there (`priorText`), so the deferred
    /// splice range is `islandStart ..< islandStart + priorText.utf8.count` — the
    /// exact span the in-flight apply wrote, computable without re-deriving block
    /// structure (which a structural edit would have changed).
    private struct TerminalFlush {
        let islandStart: Int
        let priorText: String
        let text: String
        let caretUTF16: Int
    }

    private var deferredOps: [DeferredOp] = []

    /// Test-only observability: how many ops are queued behind the in-flight apply.
    /// The falsifier tests assert on it directly so "the work was DEFERRED" is an
    /// observed interaction, not inferred from a downstream outcome that a
    /// fired-immediately implementation might also produce.
    var deferredOpCountForTest: Int { deferredOps.count }

    /// Who the currently in-flight `onReconcile` belongs to. `applyReconciled` uses
    /// it to refuse a re-anchor that would land on the WRONG island: by the time an
    /// apply comes back the user may have clicked into another block, and the
    /// KEEP/SPLIT branches would then re-anchor (or tear down) an island that had
    /// nothing to do with the edit.
    private enum InFlightOwner {
        /// A KEEP reconcile / Backspace-merge fired by this island — its
        /// `applyReconciled` re-anchors it.
        case island(IslandUnitID)
        /// A TERMINAL flush (swap-out, blur, deferred terminal flush). The island
        /// was dropped before the fire, so the apply has nothing to re-anchor.
        case orphan
    }
    private var inFlightOwner: InFlightOwner?

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
    //
    // C1/C3: `lastFlushedText` is also the UNCHANGED-TEXT BASELINE. It is SEEDED at
    // `activate` with the island's own source, so "the document already holds this
    // text" is expressible from the very first moment of an island's life — a
    // click-in/click-away with zero typing then short-circuits instead of replaying
    // byte-identical bytes as a real edit (dead undo step, spurious autosave/mtime
    // bump, pointless revision bump + recycler refresh).
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

    /// Is an apply this controller fired still outstanding? Read by the recycler,
    /// which PARKS a structural projection refresh that arrives in this window
    /// (the island is still anchored to its pre-split block, so the refresh would
    /// insert the new row on the wrong side of the editing row) and replays it
    /// from `applyReconciled`.
    var isApplyInFlight: Bool { reconcileInFlight }

    /// The machine refuses to swap while an IME composition is live. On by
    /// default; the tests flip it only to prove the gate.
    public var refuseWhileMarkedText: Bool = true

    /// Test seam: when set, overrides the live `islandTextView.hasMarkedText()`
    /// probe so the IME-refusal branch can be exercised headlessly.
    var hasMarkedTextProbe: (() -> Bool)?

    // The activation intent parked while blocked by a live IME composition, so a
    // later commit (IME end → retry) can resume the swap.
    //
    // I3: it parks the click's IDENTITY ONLY — `blockID` + `localPoint`. It used to
    // also capture the click-time `document` + `baseRevision` and replay them
    // VERBATIM, so any apply that landed between park and drain (the composition
    // window is unbounded — it lasts as long as the user keeps composing) left the
    // replayed `activate` setting `currentDocument` to a STALE parse and minting
    // the island's `byteRange` from stale block ranges. The very first flush then
    // spliced at wrong offsets. The drain re-reads `currentDocument` /
    // `currentBaseRevision`, which every landing apply and every projected document
    // refresh keeps current.
    private struct PendingIntent {
        let blockID: BlockID
        let localPoint: CGPoint
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
        // Test-only observability (weak, never read by production code): lets a
        // test reach this controller when SwiftUI — not the test — owns the
        // Coordinator that owns it — and, since I4, the seam the recycler uses to
        // hand every projected document back for revalidation.
        recycler.islandController = self
        // Install the reconcile-debounce fan-out. The recycler stays the SOLE
        // owner of the editing cell's `onTextDidChange` slot; it fans that signal
        // out to BOTH its row-height re-notify and this closure (Task 6).
        recycler.onEditingTextChanged = { [weak self] in
            self?.islandTextDidChange()
        }
        // Phase 3 hotfix: when a reload re-vends the live editing cell, the new
        // cell has none of our responder seams (they live on the cell instance).
        // Re-install them before it retakes first responder.
        recycler.onEditingCellRebuilt = { [weak self] in
            self?.editingCellWasRebuilt()
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
        ilog("activate.enter", "blockID=\(blockID) kind=\(document.blocks.first(where: { $0.id == blockID }).map { "\($0.kind)" } ?? "nil") baseRevision=\(baseRevision)")
        // IME refusal: swapping mid-composition drops the marked text. Park the
        // intent and keep the current island — do NOT flush, do NOT swap.
        if refuseWhileMarkedText, currentHasMarkedText() {
            // I3: park identity only. Adopt the click-time parse ONLY when there is
            // no island to invalidate — with an island active, `currentDocument` is
            // the parse THAT island is anchored to (kept current by every landing
            // apply and every projected refresh), and overwriting it with a
            // possibly-older click-time snapshot would make the outgoing island's
            // own drift check read a false mismatch and discard its typing.
            if activeIsland == nil {
                currentDocument = document
                currentBaseRevision = baseRevision
            }
            pendingIntent = PendingIntent(blockID: blockID, localPoint: localPoint)
            state = .blockedIME(blockID)
            return
        }

        // C2: a Backspace-merge armed by the OUTGOING island must never be consumed
        // by the incoming one. Purge merge deferrals before the swap (a deferred
        // TERMINAL flush is kept — it carries the outgoing island's unwritten text
        // and is self-contained; dropping it would drop an edit).
        purgeDeferredMerges()

        // Flush the OUTGOING island (if any) before touching the recycler, while
        // its editor cell still hosts the outgoing block's text — and while
        // `currentDocument` is still the parse IT is anchored to, so its drift check
        // measures the right thing.
        if activeIsland != nil {
            flushActiveIsland()
        }

        // Retain the freshest parse so structural ops (Backspace-merge) resolve
        // the predecessor block against the current document.
        currentDocument = document
        currentBaseRevision = baseRevision

        state = .swapping

        guard let block = document.blocks.first(where: { $0.id == blockID }) else {
            // The block vanished from the document; abandon the swap cleanly.
            abandonSwap(reason: "blockNotInDocument")
            return
        }

        // Mint FIRST and gate the swap on it: a nil mint (block's content range
        // unresolvable) must NOT leave a stuck editable row with no active
        // island. Bail cleanly with no side effects.
        var model = BlockListModel(document: document)
        guard let island = model.mintIsland(at: block.range.offset, baseRevision: baseRevision) else {
            abandonSwap(reason: "mintFailed")
            return
        }

        // THE SWAP (Phase 3, click-seam re-shape): `promoteRow` is an EXPLICIT
        // SYNCHRONOUS operation — it sets the editing identity, reloads the row
        // through the table, FORCES that reload to commit, re-queries the row height
        // off the live island layout, and hands back the REALIZED cell. Nothing here
        // depends on when a `didSet`-armed reload happens to land any more (that
        // dependency is exactly what made the previous hotfix pass headlessly and
        // fail in the app). A nil means the promotion failed: abandon the swap
        // cleanly rather than leave a half-promoted row.
        guard let cell = recycler.promoteRow(to: blockID) else {
            ilog("activate.promoteFailed", "blockID=\(blockID)")
            abandonSwap(reason: "promoteFailed")
            return
        }
        // Install the responder seams (blur / Return / Backspace). Extracted so
        // a later reload that re-vends this cell can re-install them
        // (`editingCellWasRebuilt`).
        installIslandSeams(on: cell)
        cell.window?.makeFirstResponder(cell.islandTextView)
        // Caret: on the CLICK path the recycler forwards the ORIGINAL mouse event
        // to this text view right after we return, so the text view places its own
        // caret in its OWN coordinate space (and drag-select works on the promoting
        // click). Running `placeCaret` there too would be both redundant and WRONG:
        // `localPoint` is measured from the ROW's top-left, while the text view is
        // inset by the decoration bleed / left gutter — an off-by-inset caret. Only
        // non-click activations (arrow-key entry, tests, the IME replay) place the
        // caret from a point here.
        if !recycler.isForwardingClickToIsland {
            placeCaret(in: cell.islandTextView, atLocalPoint: localPoint)
        }
        ilog("activate.madeFirstResponder", {
            let fr = cell.window?.firstResponder
            return "firstResponder=\(fr.map { String(describing: type(of: $0)) } ?? "nil") isEditable=\(cell.islandTextView.isEditable) forwardingClick=\(recycler.isForwardingClickToIsland) cellFrame=\(NSStringFromRect(cell.frame))"
        }())

        activeIsland = island
        activeIslandKind = block.kind
        // I4: seed the ANCHOR. `anchoredSource` is the document's own bytes at the
        // island's range (the cell's seeded string is the fallback for a
        // not-yet-configured cell); `activeIslandIndex` pins which block that is, so
        // an external shift that happens to re-align the start byte onto a DIFFERENT
        // block's start is still detected.
        anchoredSource = document.source.substring(in: ByteRange(island.byteRange))
            ?? cell.islandTextView.string
        activeIslandIndex = document.blocks.firstIndex(where: { $0.id == blockID })
        // Fresh island: clear any reconcile carry-over from the previous one
        // (Task 5b: including a virtual line the OUTGOING island may have had —
        // it belongs to that island and dies with it).
        virtualLine = nil
        pendingReconcile = false
        wasComposing = false
        reconcileInFlight = false
        inFlightOwner = nil
        // C1/C3: SEED the unchanged-text baseline with the island's own source, so a
        // flush that replays byte-identical bytes is recognisable as a no-op. Read
        // off the realized cell (the exact string a later flush reads back), with
        // the document slice as the fallback for a not-yet-seeded cell.
        lastFlushedText = cell.islandTextView.string
        cancelReconcileTimer()
        state = .idle
        assertNoOrphanedEditorCell("activate")
    }

    // MARK: - Clean abandonment (C5)

    /// Abandon an in-progress swap and leave a CLEAN state.
    ///
    /// Every `activate` bail AFTER `flushActiveIsland()` has dropped the outgoing
    /// island runs through here. Without it the recycler is still pointed at the
    /// OUTGOING block (`editingBlockID` set, `liveEditorCell` realized) whose
    /// `IslandTextView` is still FIRST RESPONDER, while `activeIsland` is nil — so
    /// every subsequent keystroke reaches `islandTextDidChange`, hits its
    /// `activeIsland != nil` guard, and is SILENTLY DISCARDED (the user types into
    /// a live-looking editor and nothing is ever written).
    ///
    /// Drop first responder BEFORE demoting so the resign is observed while the
    /// cell still exists; the blur seam is inert (`activeIsland` is already nil), so
    /// this cannot re-enter `deactivate`.
    private func abandonSwap(reason: String) {
        ilog("activate.abandon", "reason=\(reason) editingBlockID=\(recycler.editingBlockID.map { "\($0)" } ?? "nil")")
        if let cell = recycler.currentEditorCell, let window = cell.window,
           window.firstResponder === cell.islandTextView {
            // `makeFirstResponder(nil)` hands first responder back to the window.
            window.makeFirstResponder(nil)
        }
        recycler.editingBlockID = nil
        activeIslandKind = nil
        state = .idle
        assertNoOrphanedEditorCell("abandonSwap(\(reason))")
    }

    /// The ⟺ invariant: a live editable cell exists **iff** an island is active.
    /// Exposed (not private) so the falsifier test can assert it directly; asserted
    /// in DEBUG at every SETTLED point (`activate`, `deactivate`, `abandonSwap`,
    /// `teardownIsland`) — never mid-swap, where it is legitimately violated for a
    /// few statements.
    var hasOrphanedEditorCell: Bool {
        activeIsland == nil
            && (recycler.editingBlockID != nil || recycler.currentEditorCell != nil)
    }

    private func assertNoOrphanedEditorCell(_ context: String) {
        assert(!hasOrphanedEditorCell,
               "island invariant violated at \(context): a live editable cell exists with no active island")
    }

    // MARK: - Revalidation against EXTERNAL document changes (I4)

    /// Does the document the controller currently knows about still hold, at
    /// `range`, exactly the bytes the island is anchored to?
    ///
    /// The flush-time BACKSTOP. Every splice the controller emits is gated on it,
    /// so even if a notification path is missed the controller can never write the
    /// island's text over a span that has moved underneath it. Answers `true` when
    /// there is nothing to compare against (no retained parse / no anchor — only
    /// reachable for callers that drive `applyReconciled` directly), which keeps
    /// legacy call sites behaving exactly as before.
    private func anchorIsIntact(range: Range<Int>) -> Bool {
        guard let document = currentDocument, let anchoredSource else { return true }
        return document.source.substring(in: ByteRange(range)) == anchoredSource
    }

    /// The recycler is about to project `document`. Revalidate the active island
    /// against it and answer the byte offset the recycler should locate the editing
    /// row by — or `nil` to tear the editing row down (`setDocument`).
    ///
    /// ## The contract
    ///
    /// A document change that did NOT come from this island (undo/redo, a format or
    /// block command, a task-checkbox toggle, conflict resolution, external file
    /// adoption) shifts the bytes underneath `activeIsland.byteRange`. The island
    /// must therefore either RE-ANCHOR correctly or GO AWAY — it may never keep a
    /// range it has not revalidated.
    ///
    /// Re-anchor is accepted only on a POSITIONAL identity match: the island's start
    /// byte must still be a block START, and that block must still sit at the
    /// island's remembered INDEX. That is the signal that separates the two cases
    /// that look alike from here:
    ///
    ///  • the island's OWN edit re-projecting (its block's content — and so its
    ///    content-hash id and length — changed, but nothing before it moved), which
    ///    MUST be preserved (`IslandRefreshOrderTests`); and
    ///  • an external change that moved the island's block (⌘Z), which MUST NOT be
    ///    trusted.
    ///
    /// Content equality cannot do that job: in the first case the projected content
    /// is the island's NEW text, which matches neither the anchor nor (when the
    /// refresh wins the race with `applyReconciled`) anything else the controller
    /// holds.
    ///
    /// While an apply this controller fired is still outstanding, the island's range
    /// is about to be re-anchored by `applyReconciled` (or by the deferred op behind
    /// it): the positional mismatch in that window is DELIBERATE and transient, so
    /// revalidation stands down and lets the in-flight path finish. `currentDocument`
    /// is still refreshed, which is what keeps the flush-time drift check honest.
    ///
    /// ## An accepted re-anchor is a THREE-WAY decision (the ⌘Z data-loss fix)
    ///
    /// Re-anchoring ADVANCES `anchoredSource` to the document's new bytes, which is
    /// precisely what makes the flush-time drift check stop objecting. So the
    /// island's DISPLAYED TEXT may never be left stale behind a refreshed anchor:
    ///
    ///  1. **The island's own block is byte-identical** (`newSource ==
    ///     anchoredSource`) — the external change happened elsewhere. Pure
    ///     re-anchor: nothing is re-seeded and UNFLUSHED TYPING SURVIVES.
    ///  2. **Its bytes changed and the island is CLEAN** (live text ==
    ///     `lastFlushedText`) — RE-SEED the text view from the new bytes and stay
    ///     open (`revalidate.reseed`). The user keeps their place and the undo is
    ///     visible immediately.
    ///  3. **Its bytes changed and there ARE unflushed keystrokes** — abandon
    ///     loudly. Merging is ambiguous, and either half written at the other's
    ///     offsets corrupts.
    ///
    /// Pre-fix only the re-anchor happened: after a ⌘Z that rewrote the open block
    /// IN PLACE the island kept showing the pre-undo text while the anchor claimed
    /// to be in sync, and the very next keystroke's flush spliced that stale text
    /// back over the restored bytes.
    ///
    /// UNFLUSHED KEYSTROKES on a refused re-anchor are DISCARDED, loudly
    /// (`revalidate.abandon … discardedUnflushed=`). They cannot be flushed first:
    /// by the time a projected document reaches us the external change has ALREADY
    /// been applied to the session, so the only range we could splice them at is the
    /// stale one — which is the corruption this fix exists to prevent. Discarding a
    /// few characters is recoverable; overwriting the span an undo just restored is
    /// not.
    func revalidateForDocumentRefresh(_ document: QuoinDocument, islandStartByte: Int?) -> Int? {
        guard let island = activeIsland else {
            // No island: the recycler's own guards decide, and an editing row with
            // no island is an orphan → full swap.
            currentDocument = document
            return nil
        }
        let previous = currentDocument
        currentDocument = document

        if reconcileInFlight || !deferredOps.isEmpty {
            ilog("revalidate.skip",
                 "reason=applyInFlight islandStart=\(island.byteRange.lowerBound) deferred=\(deferredOps.count)")
            return island.byteRange.lowerBound
        }
        if let previous, previous.source == document.source {
            ilog("revalidate.unchanged", "islandStart=\(island.byteRange.lowerBound)")
            return island.byteRange.lowerBound
        }

        let start = island.byteRange.lowerBound
        let model = BlockListModel(document: document)
        guard let index = model.records.firstIndex(where: { $0.byteRange.lowerBound == start }),
              index == activeIslandIndex else {
            ilog("revalidate.mismatch",
                 "islandStart=\(start) expectedIndex=\(activeIslandIndex.map { "\($0)" } ?? "nil") foundIndex=\(model.records.firstIndex(where: { $0.byteRange.lowerBound == start }).map { "\($0)" } ?? "nil")")
            abandonIslandForInvalidatedDocument(reason: "externalDocumentChange")
            return nil
        }
        let record = model.records[index]
        let newSource = document.source.substring(in: ByteRange(record.byteRange)) ?? ""

        // Did this external change touch the ISLAND'S OWN block, or only bytes
        // elsewhere? Everything below turns on that question, because a re-anchor
        // ADVANCES `anchoredSource` — and an advanced anchor is exactly what makes
        // the flush-time drift check wave a stale splice through.
        if newSource != anchoredSource {
            // THE ISLAND'S BLOCK CHANGED UNDERNEATH IT. Its text view still shows
            // the PRE-change bytes, so leaving it alone here is not cosmetic: with
            // the anchor refreshed to the new bytes, `anchorIsIntact` passes and the
            // next keystroke's flush splices the STALE text over the span the
            // external change just wrote (⌘Z silently reverted — the shipped bug).
            guard let cell = recycler.currentEditorCell,
                  cell.blockID == island.originBlockID else {
                // No live cell to re-seed (or it hosts some other block): there is no
                // trustworthy island text at all. Down it goes.
                ilog("revalidate.reseed.impossible",
                     "islandStart=\(start) reason=noLiveCell")
                abandonIslandForInvalidatedDocument(reason: "externalBlockChangeWithoutCell")
                return nil
            }
            // Task 5b: the byte-less virtual tail is NOT an unflushed edit.
            let live = effectiveIslandText(cell.islandTextView.string)
            if live != lastFlushedText {
                // UNFLUSHED TYPING over changed bytes. Re-seeding would silently eat
                // the user's in-progress keystrokes; keeping them would re-ship the
                // corruption. ⌘Z-with-unflushed-typing is genuinely ambiguous, and
                // the established rule here is "discard LOUDLY rather than write at
                // wrong offsets" — same teardown, counters and log line as the
                // positional-mismatch path.
                ilog("revalidate.reseed.refused",
                     "islandStart=\(start) reason=unflushedEdits liveLen=\((live as NSString).length)")
                abandonIslandForInvalidatedDocument(
                    reason: "externalBlockChangeWithUnflushedEdits")
                return nil
            }
            // CLEAN island → RE-SEED it in place and stay open. The user keeps their
            // place in the block and the undo becomes visible immediately.
            reseedIsland(cell: cell, from: newSource, blockID: record.blockID)
            ilog("revalidate.reseed",
                 "islandStart=\(start) index=\(index) newID=\(record.blockID) oldLen=\((live as NSString).length) newLen=\((newSource as NSString).length) caret=\(cell.islandTextView.selectedRange().location)")
        }

        activeIsland?.byteRange = record.byteRange
        activeIsland?.originBlockID = record.blockID
        activeIslandKind = record.kind
        anchoredSource = newSource
        ilog("revalidate.reanchor", "islandStart=\(start) index=\(index) newID=\(record.blockID)")
        return start
    }

    /// Re-seed the live island's text view from the document's bytes for the block
    /// it has just been re-anchored onto, and re-seat the caret.
    ///
    /// Only ever called with a CLEAN island (live text == `lastFlushedText`), so
    /// nothing the user typed can be lost here.
    ///
    /// It goes through `BlockEditorCell.configure(slice:blockID:width:)` — the SAME
    /// seeding path the row-vending code uses — rather than poking
    /// `islandTextView.string`, so the string-integrity gate and the restyle pass
    /// both run and the island stays byte-identical to the document AND styled
    /// (`IslandSourceStylingTests`). The cell's recycling identity moves with it:
    /// `reconcileNow` requires `cell.blockID == island.originBlockID`, and the
    /// caller re-points `originBlockID` onto `blockID` immediately after.
    ///
    /// **The caret rule:** the caret keeps its UTF-16 offset within the island,
    /// clamped to the new text's length and snapped back to a composed-character
    /// boundary. A block that SHRANK past the caret parks it at the very end (the
    /// nearest surviving position) instead of crashing; a caret that still fits is
    /// preserved exactly. Byte-for-byte caret tracking across an arbitrary external
    /// rewrite is not knowable — there is no edit script — so "same offset, clamped"
    /// is the honest rule.
    private func reseedIsland(cell: BlockEditorCell, from source: String, blockID: BlockID) {
        // Task 5b: an EXTERNAL rewrite of the island's block collapses the virtual
        // line. Nothing is lost (it had no bytes) and nothing is written; keeping it
        // would mean re-seeding the document's bytes and then bolting a tail back
        // onto text the user did not put it after.
        virtualLine = nil
        let previousCaret = cell.islandTextView.selectedRange().location
        cell.configure(slice: source, blockID: blockID, width: cell.currentContentWidth)
        let text = source as NSString
        var caret = max(0, min(previousCaret, text.length))
        if caret > 0, caret < text.length {
            // Never leave the caret inside a surrogate pair / composed sequence.
            let sequence = text.rangeOfComposedCharacterSequence(at: caret)
            if sequence.location < caret { caret = sequence.location }
        }
        cell.islandTextView.setSelectedRange(NSRange(location: caret, length: 0))
        // The island now holds exactly the document's bytes: that IS the
        // unchanged-text baseline, so a flush with no further typing short-circuits
        // instead of replaying byte-identical bytes as a real edit (C3). Any pending
        // debounce is stale by construction — the island was clean when we got here.
        lastFlushedText = source
        pendingReconcile = false
        cancelReconcileTimer()
    }

    /// Drop the island because the document it was anchored to is gone, WITHOUT
    /// flushing and WITHOUT touching the recycler (its caller — `setDocument`, or
    /// the `updateDocumentPreservingEditing` fallback — is already replacing the
    /// rows). Unflushed island text is discarded; the log line names it and the
    /// counters make it observable to tests.
    func abandonIslandForInvalidatedDocument(reason: String) {
        guard activeIsland != nil else { return }
        let live = recycler.currentEditorCell.map { effectiveIslandText($0.islandTextView.string) }
        let unflushed = live != nil && live != lastFlushedText
        ilog("revalidate.abandon",
             "reason=\(reason) discardedUnflushed=\(unflushed) textLen=\((live as NSString?)?.length ?? 0)")
        invalidationTeardownCount += 1
        if unflushed { lastDiscardedIslandText = live }
        cancelReconcileTimer()
        virtualLine = nil
        pendingReconcile = false
        wasComposing = false
        reconcileInFlight = false
        inFlightOwner = nil
        pendingIntent = nil
        purgeDeferredMerges()
        activeIsland = nil
        activeIslandKind = nil
        activeIslandIndex = nil
        anchoredSource = nil
        lastFlushedText = nil
        state = .idle
    }

    /// The app's current document revision, refreshed on every projection pass so
    /// a parked IME activation replays against it (I3) rather than the revision
    /// captured at click time.
    public func noteBaseRevision(_ revision: Int) {
        currentBaseRevision = revision
    }

    /// Test seam (I4): adopt `document` as the controller's current parse WITHOUT
    /// revalidating the island against it — exactly the state a MISSED notification
    /// path leaves behind.
    ///
    /// It exists because the flush-time drift check is otherwise UNREACHABLE: every
    /// production path that delivers a new document runs `revalidateForDocumentRefresh`
    /// first, which tears a mis-anchored island down before any flush can be
    /// attempted. That is the point of a backstop — and a backstop with no way to
    /// exercise it is a backstop nobody can prove works.
    func adoptDocumentWithoutRevalidationForTest(_ document: QuoinDocument) {
        currentDocument = document
    }

    /// Install the island's responder seams onto `cell`: blur (resign), Return,
    /// and Backspace. Called at activation AND whenever a reload re-vends the live
    /// editing cell (`editingCellWasRebuilt`) — the closures live on the cell
    /// instance, so a rebuilt cell needs them re-installed.
    private func installIslandSeams(on cell: BlockEditorCell) {
        // Blur seam: a click outside the island — or the window handing first
        // responder to another view — flushes + swaps this row back to read-only.
        // A responder override, NOT a delegate method, so the cell's
        // ChangeForwarder delegate is untouched. Routed through
        // `handleIslandResignFirstResponder` so a TRANSIENT reload-induced resign
        // (the recycler rebuilding this very row) does NOT self-deactivate.
        cell.onResignFirstResponder = { [weak self] in
            self?.handleIslandResignFirstResponder()
        }
        // Return-key seam (Task 5): route Return through the controller so it
        // splits per `ReturnSemantics`. A nil return (no island / composing /
        // out-of-scope kind) falls through to the native newline.
        cell.onInsertNewline = { [weak self] in self?.handleReturn() ?? false }
        // Backspace-key seam (Task 7): route Backspace through the controller so a
        // caret at island start MERGES the block into its predecessor. A nil return
        // (no island / not at start / no predecessor / composing) falls through to
        // the native within-island delete.
        cell.onDeleteBackward = { [weak self] in self?.handleBackspace() ?? false }
    }

    /// The island's text view resigned first responder. Two very different causes:
    ///
    ///  • **Transient** — the recycler is rebuilding the editing row's view (the
    ///    read→edit residual reload, a projection refresh, or a height-driven
    ///    re-vend) and yanked our first-responder island out from under us. The
    ///    recycler restores first responder to the rebuilt cell immediately after
    ///    the reload, so this is NOT a user blur: DO NOT flush/deactivate. Detected
    ///    by `recycler.isReloadingEditingRow`.
    ///  • **Genuine** — focus moved to another view/block with no editing-row
    ///    reload in flight → flush + swap the row back to read-only.
    ///
    /// A swap to ANOTHER block already flushed `activeIsland` to nil in
    /// `activate(...)`, so the guard makes that resign a no-op too.
    private func handleIslandResignFirstResponder() {
        guard activeIsland != nil else { return }
        if recycler.isReloadingEditingRow {
            ilog("resign.transient", "suppressing deactivate during editing-row reload")
            return
        }
        deactivate()
    }

    /// A reload re-vended the live editing cell (see
    /// `BlockRecyclerView.reloadRows`): re-install the responder seams on the fresh
    /// cell before it retakes first responder. No-op unless an island is active on
    /// that cell (e.g. during a fresh activation / swap the island is not yet
    /// minted — `activate(...)` installs the seams itself).
    private func editingCellWasRebuilt() {
        guard let island = activeIsland, let cell = recycler.currentEditorCell,
              cell.blockID == island.originBlockID else { return }
        installIslandSeams(on: cell)
    }

    /// Blur: flush the active island and swap its row back to read-only.
    public func deactivate() {
        ilog("deactivate.enter", "activeIsland=\(activeIsland != nil) state=\(state) stack=\(islandShortStack(8))")
        guard activeIsland != nil else {
            state = .idle
            return
        }
        // C2: a Backspace-merge armed by THIS island must not survive its teardown.
        purgeDeferredMerges()
        flushActiveIsland()
        recycler.editingBlockID = nil
        activeIslandKind = nil
        state = .idle
        assertNoOrphanedEditorCell("deactivate")
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
        // I9: act ONLY on the live island cell. Without the `cell.blockID ==
        // island.originBlockID` check (the one `handleBackspace` already makes) a
        // reload that re-vended some OTHER row's cell would have Return splice into
        // the wrong block's text.
        guard let island = activeIsland, let kind = activeIslandKind,
              let cell = recycler.currentEditorCell,
              cell.blockID == island.originBlockID else {
            return false
        }
        let textView = cell.islandTextView
        // Never split mid-composition: splicing into half-composed marked text
        // corrupts the source. Let native handle the newline.
        if currentHasMarkedText() { return false }

        switch ReturnSemantics.mode(for: kind) {
        case .paragraphBreak:
            // At either END of the block — anywhere in the document — the new
            // paragraph is EMPTY, and Markdown cannot represent an empty paragraph:
            // nothing is written and the caret moves onto a transient VIRTUAL LINE
            // that materializes on the first keystroke.
            if let consumed = handleEmptyParagraphReturn(
                in: textView, cell: cell, island: island) {
                return consumed
            }
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
            return handleListReturn(in: textView, cell: cell, island: island, quote: false)
        case .quoteAware:
            return handleListReturn(in: textView, cell: cell, island: island, quote: true)
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
    ///   island alive on the blank line; a MID-document exit now takes Task 5b's
    ///   VIRTUAL LINE (`handleInteriorListExit`) — the empty item's real bytes are
    ///   removed and the caret lands on a byte-less new paragraph after the block,
    ///   instead of in the inter-block gap that used to tear the island down.
    ///
    /// Always returns `true` (the structural op consumed the Return).
    private func handleListReturn(
        in textView: NSTextView, cell: BlockEditorCell, island: IslandUnit, quote: Bool
    ) -> Bool {
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
            // Task 5b: mid-document, the exit lands the caret in an inter-block gap
            // — a virtual line hosts it instead.
            if handleInteriorListExit(
                in: textView, cell: cell, island: island, markerRange: markerRange) != nil {
                return true
            }
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

    // MARK: - Virtual line: the transient, byte-less new paragraph (Task 5b)

    /// `live` with the virtual affixes removed, or nil when there is no virtual
    /// line or the blank line is no longer empty (it MATERIALIZED — the user typed
    /// ON it, so the affix is no longer the island's leading/trailing content).
    private func strippingVirtualAffixes(_ live: String) -> String? {
        guard let virtual = virtualLine else { return nil }
        let ns = live as NSString
        let headLength = (virtual.head as NSString).length
        let tailLength = (virtual.tail as NSString).length
        guard ns.length >= headLength + tailLength,
              ns.substring(to: headLength) == virtual.head,
              ns.substring(from: ns.length - tailLength) == virtual.tail else { return nil }
        return ns.substring(with: NSRange(location: headLength,
                                          length: ns.length - headLength - tailLength))
    }

    /// The byte-less newlines that turn `logical` into "…and the caret is on a new
    /// empty paragraph below it". Two when the host block's range ends on its last
    /// character (a paragraph or heading), one when the range already swallowed the
    /// block's trailing newline (a list, a quote).
    private func virtualTail(for logical: String) -> String {
        var trailing = 0
        var index = logical.endIndex
        while index > logical.startIndex {
            let before = logical.index(before: index)
            guard logical[before] == "\n" else { break }
            trailing += 1
            index = before
        }
        return String(repeating: "\n", count: max(1, 2 - trailing))
    }

    /// The newlines that must follow the MATERIALIZED content so the block after
    /// the island is still separated from it by a blank line.
    ///
    /// The flush replaces the HOST BLOCK's byte range, so whatever the document
    /// holds between that range's end and the next block's start survives
    /// untouched. That gap is two newlines after a paragraph (nothing to add) but
    /// only ONE after a list — whose own range ate the other — so the typed content
    /// would land one newline away from the next block and cmark would merge them.
    /// Measured from the CURRENT document at materialization time, never cached
    /// (CLAUDE.md: "a `SourceEdit` must be COMPUTED where it is APPLIED").
    private func materializationSuffix(for island: IslandUnit) -> String {
        guard let document = currentDocument else { return "" }
        let end = island.byteRange.upperBound
        guard let next = BlockListModel(document: document).records
            .filter({ $0.byteRange.lowerBound >= end })
            .min(by: { $0.byteRange.lowerBound < $1.byteRange.lowerBound })
        else { return "" }
        let gap = document.source.substring(in: ByteRange(end ..< next.byteRange.lowerBound)) ?? ""
        return String(repeating: "\n", count: max(0, 2 - gap.filter { $0 == "\n" }.count))
    }

    /// **The one seam the virtual line touches.** The text the DOCUMENT should hold
    /// at the island's byte range, given the island's live string: the live string
    /// minus its unmaterialized virtual affixes. Identity when no virtual line is
    /// open, so every non-virtual path is byte-for-byte unchanged.
    private func effectiveIslandText(_ live: String) -> String {
        strippingVirtualAffixes(live) ?? live
    }

    /// The caret to hand a flush: an offset into the EFFECTIVE text. A byte-less
    /// HEAD shifts every live offset right by its length, so it has to come back
    /// off; the result is clamped into the effective text (a caret sitting on the
    /// byte-less line itself has no offset of its own to report).
    private func effectiveCaret(_ liveCaret: Int, in effective: String) -> Int {
        let head = ((virtualLine?.head ?? "") as NSString).length
        return max(0, min(liveCaret - head, (effective as NSString).length))
    }

    /// True while the virtual line is still EMPTY (nothing typed onto it).
    private func isUnmaterializedVirtual(_ live: String) -> Bool {
        strippingVirtualAffixes(live) != nil
    }

    /// A keystroke landed past the tail: the blank line has EARNED bytes.
    ///
    /// Drop the virtual state — the flush now writes the whole live string, tail
    /// included — and top the island up with `materializationSuffix` so the block
    /// that follows it stays separated. Appending that suffix to the TEXT VIEW
    /// (rather than only to the flushed text) is what keeps the island 1:1 with the
    /// bytes it is about to write: a flushed text that differs from the live string
    /// would read as "changed" on the very next flush and splice twice.
    ///
    /// Called from both flush paths BEFORE their unchanged-text check, so a virtual
    /// line can never survive its own materialization.
    private func noteVirtualMaterializationIfNeeded(_ live: String, island: IslandUnit) {
        guard let virtual = virtualLine, !isUnmaterializedVirtual(live) else { return }
        virtualLineMaterializedCountForTest += 1
        virtualLine = nil
        // Only a line BELOW the block needs the separation top-up: it is the new
        // LAST content of the island's range, so what follows the range has to
        // stay a blank line away. A line ABOVE leaves the island's tail exactly as
        // the document already has it — topping up there would write a stray byte.
        let suffix = virtual.tail.isEmpty ? "" : materializationSuffix(for: island)
        ilog("virtual.materialized",
             "textLen=\((live as NSString).length) suffix=\(suffix.utf8.count)")
        guard !suffix.isEmpty, let cell = recycler.currentEditorCell,
              cell.blockID == island.originBlockID else { return }
        let caret = cell.islandTextView.selectedRange().location
        cell.setSourceText(live + suffix, caretUTF16: caret)
    }

    /// Does the island's block have a LATER block in the document? That is what
    /// makes the gap after it INTERIOR rather than the trailing end of the file —
    /// the terminal case keeps Task 5's own branch ("the last block absorbs through
    /// EOF"), which is already shipped and pinned by `IslandReturnSplitTests`.
    private func hasFollowingBlock(after islandEnd: Int) -> Bool {
        guard let document = currentDocument else { return false }
        return BlockListModel(document: document).records
            .contains { $0.byteRange.lowerBound >= islandEnd }
    }

    /// Open the virtual line ABOVE or BELOW the island's text and put the caret on
    /// it. Writes NOTHING.
    ///
    /// `logical` is what the DOCUMENT should hold at the island's byte range. For
    /// an end-of-block Return that is the island's unchanged text (so nothing is
    /// flushed at all); for a mid-document list/quote EXIT — or a Return that
    /// replaced a selection — it is the island minus the removed bytes, real bytes
    /// that DO have to be written, so the debounce is armed for exactly that
    /// difference and the blank line still rides along for free.
    private func enterVirtualLine(logical: String, position: VirtualLinePosition,
                                  in cell: BlockEditorCell, reason: String) {
        // ABOVE is always two newlines: a block's range never starts with one, so
        // (unlike the tail) there is nothing to measure. BELOW is measured, because
        // a list's range already swallowed its own trailing newline.
        let head = position == .above ? "\n\n" : ""
        let tail = position == .below ? virtualTail(for: logical) : ""
        let base = head + logical + tail
        // Decide the flush BEFORE touching the text view: `setSourceText` is not a
        // user edit, but nothing here may depend on whether AppKit echoes a
        // programmatic string swap back through `textDidChange`.
        let needsFlush = logical != lastFlushedText
        virtualLine = VirtualLine(openedWith: logical, head: head, tail: tail)
        virtualLineEnteredCountForTest += 1
        // THE CARET. Below: on the new blank line (the end of the tail). Above: at
        // the START OF THE BLOCK, i.e. just past the head — the natural editor
        // behaviour is that Return at a block's start pushes the BLOCK down and
        // takes the caret with it, leaving the empty paragraph above it. So typing
        // continues in the original block (the blank line stays byte-less until
        // the user goes UP into it), and an abandoned one leaves no trace either way.
        cell.setSourceText(
            base,
            caretUTF16: position == .above
                ? (head as NSString).length : (base as NSString).length)
        pendingReconcile = needsFlush
        if needsFlush { scheduleReconcileTimer() } else { cancelReconcileTimer() }
        ilog("virtual.enter",
             "reason=\(reason) position=\(position) logicalLen=\(logical.utf8.count) needsFlush=\(needsFlush)")
        // The row has to grow by the new line NOW (a programmatic swap does not
        // reach `editingCellDidChangeText`), inside the viewport bracket.
        recycler.noteEditingRowHeightPreservingViewport(tag: "virtual.\(reason)")
    }

    /// Close the virtual line, leaving the island exactly as it was before Return.
    /// Writes nothing (there was never anything to un-write). The caret goes back
    /// to the end the line was opened from.
    private func collapseVirtualLine(in cell: BlockEditorCell, logical: String,
                                     caretAtStart: Bool) {
        virtualLine = nil
        let needsFlush = logical != lastFlushedText
        cell.setSourceText(logical, caretUTF16: caretAtStart ? 0 : (logical as NSString).length)
        pendingReconcile = needsFlush
        if needsFlush { scheduleReconcileTimer() } else { cancelReconcileTimer() }
        ilog("virtual.collapse", "logicalLen=\(logical.utf8.count) needsFlush=\(needsFlush)")
        recycler.noteEditingRowHeightPreservingViewport(tag: "virtual.collapse")
    }

    /// Re-establish the virtual line after an apply re-anchored / re-seeded the
    /// island. The apply wrote the island's LOGICAL text (the affixes are byte-less
    /// by construction), so the cell may now show the block without them.
    ///
    /// Three cases, and the third is the ASYNC DEGRADATION WINDOW: in the app
    /// `onReconcile` is a `Task`, so keystrokes can land between a flush and its
    /// apply.
    ///
    ///  1. **The affixes are still on the island** (the KEEP branch re-anchors
    ///     without re-seeding the string). Nothing to rebuild. The caret is put
    ///     back exactly where the user had it: the apply's re-seat computed it in
    ///     LOGICAL coordinates, which are short by the head and clamp off the tail.
    ///  2. **The island holds exactly the logical text** (the re-home branch
    ///     re-seeded it). Rebuild the affixes around it.
    ///  3. **Neither** — the user typed ONTO the blank line while the apply was in
    ///     flight, so it has earned bytes. MATERIALIZE it: the typing AND the blank
    ///     line both survive, with the separation top-up computed against the
    ///     document the apply just produced. (Before this it dropped the virtual
    ///     state instead, which was not merely a lost blank line: with the state
    ///     gone the still-displayed affix newlines became REAL on the next flush —
    ///     two stray bytes, and for a list host a missing separator that welded the
    ///     next block onto it.)
    private func restoreVirtualLineIfNeeded(logical: String, island: IslandUnit,
                                            caretBeforeApply: Int?) {
        guard let virtual = virtualLine else { return }
        guard let cell = recycler.currentEditorCell else {
            ilog("virtual.restore.dropped", "reason=noCell")
            virtualLine = nil
            return
        }
        let live = cell.islandTextView.string
        let headLength = (virtual.head as NSString).length
        // (1) Still there — only the caret may have been disturbed.
        if strippingVirtualAffixes(live) != nil {
            if let caretBeforeApply {
                let length = (live as NSString).length
                cell.islandTextView.setSelectedRange(
                    NSRange(location: max(0, min(caretBeforeApply, length)), length: 0))
            }
            ilog("virtual.restore", "kept=true logicalLen=\(logical.utf8.count)")
            return
        }
        // (2) Re-seeded to the logical text — rebuild the affixes around it.
        if live == logical {
            let caret = cell.islandTextView.selectedRange().location
            let tail = virtual.tail.isEmpty ? "" : virtualTail(for: logical)
            let head = virtual.head
            let base = head + logical + tail
            virtualLine = VirtualLine(openedWith: logical, head: head, tail: tail)
            let newCaret: Int
            if !tail.isEmpty, caret >= (logical as NSString).length {
                newCaret = (base as NSString).length
            } else if !head.isEmpty, caret <= 0 {
                newCaret = 0
            } else {
                newCaret = caret + headLength
            }
            cell.setSourceText(base, caretUTF16: newCaret)
            ilog("virtual.restore", "logicalLen=\(logical.utf8.count) caret=\(caret)")
            recycler.noteEditingRowHeightPreservingViewport(tag: "virtual.restore")
            return
        }
        // (3) The blank line earned bytes while the apply was in flight. Put the
        // user's caret back FIRST: the branch above re-seated it in logical
        // coordinates (which do not describe this string at all), and
        // materialization reads the live caret to re-seat it across the top-up.
        if let caretBeforeApply {
            let length = (live as NSString).length
            cell.islandTextView.setSelectedRange(
                NSRange(location: max(0, min(caretBeforeApply, length)), length: 0))
        }
        ilog("virtual.restore.materialized", "reason=islandChangedDuringApply")
        noteVirtualMaterializationIfNeeded(live, island: island)
        // A live string that matches NEITHER shape and is not a materialization
        // (unreachable today) must not leave a stale affix behind.
        virtualLine = nil
    }

    /// **Every Return whose new paragraph would be EMPTY**, at either END of the
    /// island's text, anywhere in the document — interior or terminal — and with or
    /// without a selection to replace first. Returns nil when this Return is NOT
    /// such a case, so the caller falls through to the native `\n\n` split (which
    /// is correct exactly when BOTH halves have content).
    ///
    /// An empty paragraph is not representable in Markdown wherever it sits, so all
    /// of these get the same answer: write nothing, host the blank line in the
    /// island, materialize on the first keystroke. Terminal used to have its own
    /// mechanism (write `\n\n`, then keep the island alive on the last block with
    /// its slice extended through EOF) — it produced the right final bytes but grew
    /// the file by two bytes the moment Return was pressed, so a Return the user
    /// abandoned left them behind. Unifying it here DELETED that branch.
    ///
    /// The rules, each load-bearing:
    ///  • **A virtual line is already open** → consume. Return AGAIN on the empty
    ///    line is a NO-OP (two adjacent empty paragraphs are no more representable
    ///    than one, and inserting `\n\n` would push the caret into a gap
    ///    `record(at:)` cannot resolve). Return at the OPPOSITE end MOVES the
    ///    byte-less line there — free, since neither position has bytes.
    ///  • **A non-empty selection** → delete it first (real bytes: that part IS
    ///    flushed), then apply these same rules to the caret's resulting position,
    ///    so the whole thing is ONE edit and one undo step. A selection whose
    ///    deletion would empty the block outright is a block deletion, not a
    ///    Return: fall through.
    ///  • **The caret at the very END** → the blank line goes BELOW.
    ///  • **The caret at the very START** → the blank line goes ABOVE (the natural
    ///    editor behaviour: an empty paragraph is inserted above and the block,
    ///    with the caret still in it, is pushed down).
    ///  • **The anchor is intact** → a virtual line is only meaningful over a byte
    ///    range the document still holds; on drift, fall through and let the
    ///    existing refuse-on-drift machinery deal with it.
    private func handleEmptyParagraphReturn(
        in textView: NSTextView, cell: BlockEditorCell, island: IslandUnit
    ) -> Bool? {
        let live = textView.string
        let ns = live as NSString
        let selection = textView.selectedRange()

        if let virtual = virtualLine {
            // A MATERIALIZED line (the user typed on it, unflushed) is ordinary
            // island text again: let the normal rules split it for real.
            guard let logical = strippingVirtualAffixes(live), selection.length == 0
            else { return nil }
            let headLength = (virtual.head as NSString).length
            let logicalEnd = headLength + (logical as NSString).length
            if !logical.isEmpty, virtual.tail.isEmpty, selection.location >= logicalEnd {
                enterVirtualLine(logical: logical, position: .below, in: cell,
                                 reason: "virtualMovedBelow")
                return true
            }
            if !logical.isEmpty, virtual.head.isEmpty, selection.location <= 0 {
                enterVirtualLine(logical: logical, position: .above, in: cell,
                                 reason: "virtualMovedAbove")
                return true
            }
            ilog("virtual.secondReturn", "consumed as a no-op")
            return true
        }

        guard anchorIsIntact(range: island.byteRange) else { return nil }

        if selection.length > 0 {
            let remaining = ns.replacingCharacters(in: selection, with: "")
            guard !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  selection.location == 0 || selection.location == (remaining as NSString).length
            else { return nil }
            // Replace the selection through the NATIVE input path (so the height
            // and debounce signals fire), then open the line at the caret it left.
            textView.insertText("", replacementRange: selection)
            textView.setSelectedRange(NSRange(location: selection.location, length: 0))
            enterVirtualLine(logical: remaining,
                             position: selection.location == 0 ? .above : .below,
                             in: cell, reason: "selectionReturn")
            return true
        }

        guard !live.isEmpty else { return nil }
        if selection.location == ns.length {
            enterVirtualLine(logical: live, position: .below, in: cell, reason: "endReturn")
            return true
        }
        if selection.location == 0 {
            enterVirtualLine(logical: live, position: .above, in: cell, reason: "startReturn")
            return true
        }
        return nil
    }

    /// Mid-document list/quote EXIT: the empty marker is removed (real bytes, so it
    /// IS flushed) and the caret moves onto a virtual line after the block, instead
    /// of into an inter-block gap that tears the island down. Returns nil when the
    /// exit is not the mid-document end-of-block case (terminal exits keep Task 6's
    /// behaviour, pinned by `IslandListReturnTests`).
    private func handleInteriorListExit(
        in textView: NSTextView, cell: BlockEditorCell, island: IslandUnit,
        markerRange: NSRange
    ) -> Bool? {
        let ns = textView.string as NSString
        // Delete the empty item's WHOLE LINE, not just the `lineStart ..< caret`
        // marker: what is left has to be the block's canonical source again, and
        // for a list that includes the block's own trailing newline (which the
        // marker range does not cover). `"- a\n- \n"` → `"- a\n"`, the exact bytes
        // the block had before the item was added.
        let lineRange = ns.lineRange(for: NSRange(location: markerRange.location, length: 0))
        guard NSMaxRange(lineRange) == ns.length,
              hasFollowingBlock(after: island.byteRange.upperBound),
              anchorIsIntact(range: island.byteRange)
        else { return nil }
        let logical = ns.replacingCharacters(in: lineRange, with: "")
        // An exit that would empty the block outright is not an exit — it is a
        // block deletion, which is not this feature's job. Fall through to native.
        guard !logical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        enterVirtualLine(logical: logical, position: .below, in: cell, reason: "listExit")
        return true
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
        // Task 5b: Backspace on an EMPTY virtual line closes it — the inverse of
        // the Return that opened it. Letting native run instead would delete into
        // the tail (`"Middle\n\n"` → `"Middle\n"`) and the flush would then write a
        // stray newline over the host block; one more and it would eat the real
        // inter-block separator, MERGING two blocks the user never touched.
        // (A line ABOVE collapses the same way, from the caret at its own end —
        // offset 0, the start of the head.)
        if let virtual = virtualLine, let logical = strippingVirtualAffixes(textView.string) {
            let selection = textView.selectedRange()
            let atTail = !virtual.tail.isEmpty
                && selection == NSRange(location: (textView.string as NSString).length, length: 0)
            // For a line ABOVE, BOTH boundaries collapse it: the caret on the line
            // itself (0) and the caret at the start of the text below it (past the
            // head) — deleting backwards from either is "remove the blank line".
            // Letting native run at the head's end would eat one of the head's own
            // newlines and the flush would then write the other as a real byte.
            let atHead = !virtual.head.isEmpty
                && (selection == NSRange(location: 0, length: 0)
                    || selection == NSRange(location: (virtual.head as NSString).length, length: 0))
            if atTail || atHead {
                collapseVirtualLine(in: cell, logical: logical, caretAtStart: atHead)
                return true
            }
        }
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

        // ORDERING (Fix round 1, extended by I2): the real app's `onReconcile` is
        // async, so an apply that is PENDING (debounced, not yet fired) *or already
        // IN FLIGHT* lands LATER. Firing the merge now would race it (non-FIFO
        // Tasks) and could splice the merge FIRST — everything then shifts left by
        // the separator length and the flush's whole-island range splices at offsets
        // short by exactly that much (the CLAUDE.md "compute-where-applied /
        // stale-base" bug class). Defer the merge behind whatever is outstanding,
        // KEYED to this island (C2), and let the landing `applyReconciled` fire it
        // against the refreshed document + re-anchored island range.
        if reconcileInFlight {
            // Something is already in flight; its `applyReconciled` will drain us.
            // (I2: the original code fired immediately in the
            // `reconcileInFlight && !pendingReconcile` case — a direct race.)
            deferredOps.append(.backspaceMerge(island.id))
        } else if pendingReconcile {
            deferredOps.append(.backspaceMerge(island.id))
            // If the flush turns out to be a NO-OP (unchanged text — C1's
            // short-circuit), nothing will ever call `applyReconciled`, so the
            // deferred merge would never be drained and Backspace would silently do
            // nothing while still consuming the keystroke. Fire it directly instead.
            if !reconcileNow() {
                purgeDeferredMerges()
                fireBackspaceMerge()
            }
        } else {
            fireBackspaceMerge()
        }
        return true
    }

    /// Drop every DEFERRED Backspace-merge. Called at each island-identity
    /// transition (`activate`, `deactivate`, `teardownIsland`) so a merge armed by
    /// an island that no longer exists can never be consumed. Deferred TERMINAL
    /// flushes are deliberately KEPT — they carry an outgoing island's unwritten
    /// text and are self-contained (no island identity is needed to fire them), so
    /// purging them would DROP AN EDIT.
    private func purgeDeferredMerges() {
        guard deferredOps.contains(where: { if case .backspaceMerge = $0 { return true }; return false })
        else { return }
        ilog("deferred.purgeMerges", "count=\(deferredOps.count)")
        deferredOps.removeAll { if case .backspaceMerge = $0 { return true }; return false }
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
        // I4 backstop: the separator offsets below are derived from the island's
        // byte range. If the document moved underneath it, they are meaningless.
        guard anchorIsIntact(range: island.byteRange) else {
            ilog("merge.refused", "reason=byteDrift range=\(island.byteRange)")
            refusedFlushCount += 1
            teardownIsland()
            return
        }
        guard let prev = predecessorRecord(before: islandStart, in: document) else { return }
        let separator = prev.byteRange.upperBound ..< islandStart
        // EMPTY-SPLICE GUARD: only fire for a real, positive-length separator.
        guard separator.lowerBound < separator.upperBound else { return }
        lastFlushedText = cell.islandTextView.string
        reconcileInFlight = true
        inFlightOwner = .island(island.id)
        onReconcile?(ByteRange(separator), "", 0)
    }

    // MARK: - Flush

    /// Read the outgoing island's live text + caret and emit `onReconcile`, then
    /// drop the active island. Leaves the recycler row alone — the caller either
    /// re-points `editingBlockID` at the incoming block (swap) or clears it
    /// (deactivate). This is a TERMINAL flush: the island is dropped BEFORE
    /// `onReconcile` fires, so a synchronous `applyReconciled` from the app's
    /// apply is a no-op (there is nothing left to re-anchor).
    ///
    /// SYNCHRONOUS AND SAFE FROM THE CALLER'S PERSPECTIVE (C1). `activate` and
    /// `deactivate` call this and then proceed immediately; the outgoing island's
    /// content is guaranteed to reach the document exactly once, by one of three
    /// mutually exclusive exits:
    ///
    ///  1. **Unchanged** (`text == lastFlushedText`) — the document ALREADY holds
    ///     these exact bytes (the baseline is seeded at `activate` and re-set on
    ///     every fire), so there is nothing to write. Firing here is the C3 bug:
    ///     a byte-identical replay costs a dead undo step, an autosave/mtime bump
    ///     on the user's real file, and a full recycler refresh.
    ///  2. **Nothing in flight** — fire `onReconcile` right now, exactly as before.
    ///  3. **An apply IS in flight** — the island's `byteRange` is about to move
    ///     under us, so firing now would splice a stale span AND could land out of
    ///     order (the C1 double-apply: "Helloabc" written twice → "Helloabcabc").
    ///     Park a `.terminalFlush` on the deferral channel; it fires from the
    ///     landing `applyReconciled`, against the range the in-flight apply
    ///     actually wrote. See `fireDeferredTerminalFlush` for why that range is
    ///     exact and why this cannot lose the text.
    private func flushActiveIsland() {
        guard let island = activeIsland else { return }
        ilog("flush.enter", "originBlockID=\(island.originBlockID) byteRange=\(island.byteRange) inFlight=\(reconcileInFlight)")
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
            ilog("flush.fired", "fired=false reason=noCell")
            activeIsland = nil
            activeIslandKind = nil
            activeIslandIndex = nil
            anchoredSource = nil
            lastFlushedText = nil
            reconcileInFlight = false
            state = .idle
            return
        }
        // Task 5b: an UNMATERIALIZED virtual line is not part of the document, so
        // the text that goes to the document is the live string minus its tail.
        // That is what makes an ABANDONED empty line byte-lossless: the effective
        // text is what the document already holds, so exit (1) below fires and
        // nothing is written at all.
        var live = textView.string
        noteVirtualMaterializationIfNeeded(live, island: island)
        live = textView.string
        let text = effectiveIslandText(live)
        let caret = min(textView.selectedRange().location, (text as NSString).length)
        virtualLine = nil
        let priorFlushed = lastFlushedText
        // Drop the island FIRST so any synchronous applyReconciled is inert.
        activeIsland = nil
        activeIslandKind = nil

        // (1) UNCHANGED → no edit at all (C3, and half of C1).
        if let priorFlushed, priorFlushed == text {
            ilog("flush.fired", "fired=false reason=unchanged textLen=\((text as NSString).length)")
            state = .idle
            return
        }
        // (3) An apply is IN FLIGHT → park behind it (C1).
        if reconcileInFlight, let priorFlushed {
            deferredOps.append(.terminalFlush(TerminalFlush(
                islandStart: island.byteRange.lowerBound, priorText: priorFlushed,
                text: text, caretUTF16: caret)))
            ilog("flush.deferred", "islandStart=\(island.byteRange.lowerBound) priorLen=\(priorFlushed.utf8.count) textLen=\((text as NSString).length) queued=\(deferredOps.count)")
            state = .idle
            return
        }
        // (4) I4 backstop — REFUSE ON DRIFT. The island's range is only meaningful
        // if the document still holds the bytes the island was anchored to. When an
        // external change (⌘Z is the canonical one) moved them, splicing `text` here
        // would overwrite whatever now occupies the old span. Refuse and discard.
        guard anchorIsIntact(range: island.byteRange) else {
            ilog("flush.fired", "fired=false reason=byteDrift range=\(island.byteRange) textLen=\((text as NSString).length)")
            refusedFlushCount += 1
            lastDiscardedIslandText = text
            lastFlushedText = nil
            anchoredSource = nil
            activeIslandIndex = nil
            state = .idle
            return
        }
        // (2) Fire now.
        lastFlushedText = text
        inFlightOwner = .orphan
        ilog("flush.fired", "fired=true textLen=\((text as NSString).length) changed=\(priorFlushed != text) caret=\(caret)")
        onReconcile?(ByteRange(island.byteRange), text, caret)
    }

    /// Fire a `.terminalFlush` parked behind an apply that has now LANDED.
    ///
    /// ## Why the range is exact
    ///
    /// The in-flight apply replaced the island's byte range with `priorText`. An
    /// island's own edit never moves the bytes BEFORE it, so after that apply the
    /// island's content occupies exactly
    /// `islandStart ..< islandStart + priorText.utf8.count` — derived from the two
    /// values captured at arm time, with NO dependence on block structure (which a
    /// structural edit would have changed) and no re-parse guesswork. Replacing that
    /// span with the outgoing island's final `text` yields precisely the document the
    /// island represented when it was torn down.
    ///
    /// ## Refuse-on-drift
    ///
    /// The span is byte-re-validated against the landed document before firing
    /// (CLAUDE.md: "refuse-on-drift byte re-validation"). A mismatch means the apply
    /// did NOT write what we fired (e.g. the session rejected it on a stale base), in
    /// which case splicing would corrupt; refuse and log instead.
    ///
    /// Returns true when an `onReconcile` was fired (so the drain waits for ITS
    /// apply before releasing the next deferred op).
    private func fireDeferredTerminalFlush(_ flush: TerminalFlush) -> Bool {
        guard let document = currentDocument else {
            ilog("deferred.flush.refused", "reason=noDocument")
            return false
        }
        guard flush.text != flush.priorText else {
            ilog("deferred.flush.skipped", "reason=unchanged")
            return false
        }
        let length = flush.priorText.utf8.count
        let range = ByteRange(offset: flush.islandStart, length: length)
        guard flush.islandStart >= 0,
              flush.islandStart + length <= document.source.utf8.count,
              document.source.substring(in: range) == flush.priorText else {
            ilog("deferred.flush.refused",
                 "reason=byteDrift islandStart=\(flush.islandStart) priorLen=\(length) sourceLen=\(document.source.utf8.count)")
            return false
        }
        ilog("deferred.flush.fired", "range=\(range) textLen=\(flush.text.utf8.count)")
        // The island is long gone: this is an ORPHAN apply — nothing to re-anchor,
        // and it must NOT be mistaken for the CURRENT island's reconcile.
        inFlightOwner = .orphan
        onReconcile?(range, flush.text, flush.caretUTF16)
        return true
    }

    /// Release the NEXT deferred op, if any. Drained one-per-`applyReconciled` so
    /// each op is ordered behind the one before it; ops whose island is gone are
    /// skipped (not fired) and the drain moves on.
    private func fireNextDeferredOp() {
        while !deferredOps.isEmpty {
            let op = deferredOps.removeFirst()
            switch op {
            case .backspaceMerge(let islandID):
                guard activeIsland?.id == islandID else {
                    // C2: the island that armed this merge is gone (the user clicked
                    // into another block before the flush landed). Consuming it here
                    // would delete the separator between the CURRENT island and ITS
                    // predecessor — two untouched blocks merged.
                    ilog("deferred.merge.skipped", "reason=islandChanged")
                    continue
                }
                fireBackspaceMerge()
                return
            case .terminalFlush(let flush):
                if fireDeferredTerminalFlush(flush) { return }
                continue
            }
        }
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
    /// there is no active island, the text is UNCHANGED since the last flush, or an
    /// IME composition is still live.
    ///
    /// Returns whether an `onReconcile` was actually fired — callers that DEFER work
    /// behind this flush's apply (the Backspace-merge) must know, because a no-op
    /// flush never calls back and would strand the deferral forever.
    @discardableResult
    private func reconcileNow() -> Bool {
        cancelReconcileTimer()
        guard pendingReconcile, let island = activeIsland else {
            pendingReconcile = false
            return false
        }
        // Minor fix (stale-range guard): a prior reconcile's apply/re-anchor is
        // still in flight, so `island.byteRange` is about to move. Computing a
        // whole-island replace against it now would splice a stale span. Leave
        // `pendingReconcile` set and re-arm the debounce so this fires once the
        // re-anchor lands.
        if reconcileInFlight {
            scheduleReconcileTimer()
            return false
        }
        guard let cell = recycler.currentEditorCell,
              cell.blockID == island.originBlockID else { return false }
        // Never splice mid-composition; the commit keystroke will re-drive this.
        if currentHasMarkedText() { return false }
        pendingReconcile = false
        // Task 5b: strip an unmaterialized virtual tail (see `effectiveIslandText`)
        // — the blank line has no bytes until something is typed into it. A
        // keystroke PAST the tail materializes it: the virtual state is dropped and
        // the whole live string (tail included) is what gets written.
        var live = cell.islandTextView.string
        noteVirtualMaterializationIfNeeded(live, island: island)
        live = cell.islandTextView.string
        let newText = effectiveIslandText(live)
        // C3/C1: the document already holds exactly these bytes (typed-then-undone,
        // a re-seed, or an activation with no typing). Firing would be a no-op edit
        // with real costs: a dead undo step and an autosave rewrite of the file.
        if newText == lastFlushedText {
            ilog("reconcile.skipped", "reason=unchanged textLen=\((newText as NSString).length)")
            return false
        }
        // I4 backstop — REFUSE ON DRIFT (see `anchorIsIntact`). The whole-island
        // replace below is computed against `island.byteRange`; if the document no
        // longer holds the island's anchored bytes there, that range belongs to
        // something else now. Refuse, and tear the island down rather than leave a
        // live editor bound to a range it cannot write.
        guard anchorIsIntact(range: island.byteRange) else {
            ilog("reconcile.refused", "reason=byteDrift range=\(island.byteRange) textLen=\((newText as NSString).length)")
            refusedFlushCount += 1
            lastDiscardedIslandText = newText
            teardownIsland()
            return false
        }
        // Mapped into the EFFECTIVE text: with a virtual line open the caret sits on
        // a byte-less line — past the effective text's end (a line BELOW) or shifted
        // right by the head (a line ABOVE) — and the caret we hand out is an offset
        // into `newText`.
        let caret = effectiveCaret(cell.islandTextView.selectedRange().location, in: newText)
        lastFlushedText = newText
        reconcileInFlight = true
        inFlightOwner = .island(island.id)
        onReconcile?(ByteRange(island.byteRange), newText, caret)
        return true
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
        ilog("apply.enter", "caretDocByte=\(caretDocByte.map { "\($0)" } ?? "nil") activeIsland=\(activeIsland != nil) hasFlushed=\(lastFlushedText != nil)")
        // The in-flight apply has landed — clear the stale-range guard regardless
        // of the outcome below.
        reconcileInFlight = false
        let owner = inFlightOwner
        inFlightOwner = nil
        // Refresh the retained parse in EVERY branch (before any early return) so
        // a subsequent structural op sees the latest document.
        currentDocument = newDocument
        // Fix round 1 (generalized by the Phase-3 critical-fix wave): work DEFERRED
        // behind this apply is released here, at EVERY exit (whichever branch the
        // apply took), ONE op per apply — so each deferred op is ordered behind the
        // one before it. The op is removed from the queue before it fires, so its
        // own `applyReconciled` cannot re-consume it (no re-entrant loop).
        defer { fireNextDeferredOp() }
        // …and a projection refresh the recycler PARKED because it would have
        // restructured the table while this apply was in flight. Declared AFTER
        // the drain's `defer`, so LIFO runs it FIRST: the table is re-projected
        // around the island's freshly re-anchored row BEFORE any deferred op can
        // fire another edit against it. Every exit below is covered.
        defer { recycler.replayParkedRefreshIfNeeded() }

        // OWNERSHIP GUARD: an apply is only allowed to re-anchor the island that
        // FIRED it. `.orphan` = a terminal flush (the island was dropped before the
        // fire), and a mismatched `.island` = the user clicked into a different
        // block while this apply was in flight. Re-anchoring in either case would
        // move (or tear down) an island that had nothing to do with the edit. A nil
        // owner means the caller drove `applyReconciled` directly (tests / legacy
        // callers), which keeps the pre-existing behaviour exactly.
        switch owner {
        case .orphan:
            ilog("apply.branch", "branch=orphanTerminalFlush")
            return
        case .island(let id) where id != activeIsland?.id:
            ilog("apply.branch", "branch=crossIsland")
            return
        case .island, .none:
            break
        }

        guard let island = activeIsland, let flushed = lastFlushedText else {
            ilog("apply.branch", "branch=noIslandOrFlushed")
            return
        }
        // The caret the user actually has, in the LIVE island's coordinates, read
        // before either branch below re-seats it. With a virtual line open the
        // island's string is not what the apply wrote (it carries byte-less
        // affixes), so the re-seat's logical-coordinate answer is off by the head
        // and clamped by the tail; `restoreVirtualLineIfNeeded` puts this back.
        let caretBeforeApply = virtualLine == nil
            ? nil : recycler.currentEditorCell?.islandTextView.selectedRange().location
        let model = BlockListModel(document: newDocument)

        // KEEP: the island's origin byte still resolves to a block whose content is
        // EXACTLY the flushed text → 1:1 re-anchor in place. The byte-range OFFSET is
        // unchanged (bytes before the island never moved) but its length tracks the
        // new text; the origin block id changes (content-hash) so hand it to the
        // recycler so its editing identity tracks in lockstep across the projection
        // refresh (`updateDocumentPreservingEditing`).
        if let record = model.record(at: island.byteRange.lowerBound),
           newDocument.source.substring(in: ByteRange(record.byteRange)) == flushed {
            ilog("apply.branch", "branch=keep newID=\(record.blockID)")
            let oldStart = island.byteRange.lowerBound
            activeIsland?.byteRange = record.byteRange
            activeIsland?.originBlockID = record.blockID
            activeIslandKind = record.kind
            // I4: the document is KNOWN to hold `flushed` at this range (that is the
            // branch condition) — advance the anchor with it.
            anchoredSource = flushed
            activeIslandIndex = model.records.firstIndex {
                $0.byteRange.lowerBound == record.byteRange.lowerBound
            }
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
            // The apply wrote the island's LOGICAL text, so a still-open virtual
            // line has to be put back on top of it (the mid-document list/quote
            // exit and the selection-replacing Return take exactly this path: the
            // removal is a KEEP reconcile, and the blank line rides above it).
            restoreVirtualLineIfNeeded(logical: flushed, island: activeIsland ?? island,
                                       caretBeforeApply: caretBeforeApply)
            return
        }

        // No caret (legacy caller) → safe teardown; the edit is already applied.
        guard let caretDocByte else {
            ilog("apply.branch", "branch=teardown reason=noCaret")
            teardownIsland()
            return
        }

        // (Task 5's TERMINAL EMPTY PARAGRAPH branch used to sit here: Return at the
        // end of the LAST block wrote `"Hello\n\n"`, which re-parses to ONE block,
        // so the reconcile-time caret landed past all content and the island was
        // kept alive on the last block with its slice EXTENDED through EOF. It is
        // GONE: the terminal Return no longer writes anything at all — the virtual
        // line hosts it exactly as it hosts an interior one — so the state this
        // branch existed to rescue is unreachable, and a Return the user abandons
        // at the end of the document no longer leaves two bytes behind.)

        // SPLIT / structural change → RE-ACTIVATE AT CARET. Re-home the island onto
        // the block that now CONTAINS the reconcile-time caret. Caret in a separator
        // gap (not the terminal case above) → safe teardown (the edit is applied).
        guard let rec = caretRecord(model, at: caretDocByte) else {
            ilog("apply.branch", "branch=teardown reason=caretInSeparatorGap")
            teardownIsland()
            return
        }
        ilog("apply.branch", "branch=split newID=\(rec.blockID)")
        let islandSource = newDocument.source.substring(in: ByteRange(rec.byteRange)) ?? ""
        activeIsland?.byteRange = rec.byteRange
        activeIsland?.originBlockID = rec.blockID
        activeIslandKind = rec.kind
        // The island now flushes the caret block's text; keep `lastFlushedText` in
        // step so a subsequent KEEP reconcile maps 1:1 against it.
        lastFlushedText = islandSource
        // I4: `islandSource` is read straight out of `newDocument` at `rec.byteRange`.
        anchoredSource = islandSource
        activeIslandIndex = model.records.firstIndex {
            $0.byteRange.lowerBound == rec.byteRange.lowerBound
        }
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
        // A virtual line does not normally survive to here (materializing clears it
        // at flush time), but a LOGICAL-text flush that happened to restructure the
        // document would land here with one open. Keep the two in step.
        restoreVirtualLineIfNeeded(logical: islandSource, island: activeIsland ?? island,
                                   caretBeforeApply: nil)
    }

    /// The block a reconcile-time caret belongs to.
    ///
    /// `BlockListModel.record(at:)` is content-ranges-only, and a caret at the END
    /// of a block sits on that block's `upperBound` — outside its half-open range.
    /// The model special-cases only the LAST block's end (so a trailing caret has
    /// somewhere to land); every INTERIOR block's end answers nil, which is what
    /// dropped the island the moment a materializing keystroke put the caret at the
    /// end of a freshly created interior block.
    ///
    /// A caret at a block's end IS in that block — there is no ambiguity to
    /// resolve, because the one position that reads as "in the gap after it"
    /// (an empty new paragraph) is never expressed as an edit any more: 5b's
    /// virtual line hosts it WITHOUT writing bytes, so it never reaches an apply.
    private func caretRecord(_ model: BlockListModel, at caretDocByte: Int) -> BlockRecord? {
        if let record = model.record(at: caretDocByte) { return record }
        return model.records.first { $0.byteRange.upperBound == caretDocByte }
    }

    /// Tear the island down WITHOUT a flush (the edit that split the block is
    /// already applied): drop the island, clear the editing row, settle idle.
    /// Same observable end state `deactivate()` reaches (idle, no island) but
    /// without re-firing `onReconcile` — re-flushing here would re-apply the
    /// text against a now-stale byte range.
    private func teardownIsland() {
        cancelReconcileTimer()
        virtualLine = nil
        pendingReconcile = false
        wasComposing = false
        reconcileInFlight = false
        inFlightOwner = nil
        // C2: the island that could have armed a merge is going away.
        purgeDeferredMerges()
        activeIsland = nil
        activeIslandKind = nil
        activeIslandIndex = nil
        anchoredSource = nil
        lastFlushedText = nil
        recycler.editingBlockID = nil
        state = .idle
        assertNoOrphanedEditorCell("teardownIsland")
    }

    // MARK: - Debounce timer

    private func scheduleReconcileTimer() {
        cancelReconcileTimer()
        reconcileTimer = Timer.scheduledTimer(
            withTimeInterval: reconcileDebounceInterval, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.reconcileNow() }
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
        // I3: re-read the CURRENT document + revision. The parked intent carries
        // identity only; replaying the click-time parse would mint the incoming
        // island's `byteRange` from block ranges any apply landed since the park has
        // already moved, and its first flush would splice at those wrong offsets.
        guard let document = currentDocument else {
            ilog("intent.drain.refused", "reason=noCurrentDocument blockID=\(intent.blockID)")
            state = .idle
            return
        }
        ilog("intent.drain", "blockID=\(intent.blockID) baseRevision=\(currentBaseRevision)")
        activate(blockID: intent.blockID, localPoint: intent.localPoint,
                 in: document, baseRevision: currentBaseRevision)
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
        // Clamp the point INTO the text view's content box first. The island's
        // glyphs are inset by the decoration gutter/bleed so they line up with
        // `BlockRenderCell`'s (Phase 3), which means a row-local point in the
        // padding — `(0, 0)`, the "top-left of the row" every non-click
        // activation passes — lands OUTSIDE the container. AppKit answers such a
        // point with a nonsense index, and the `min(index, length)` below then
        // reads as "end of block": activating at the row's top-left put the
        // caret at the END of the text (the harness end-to-end test caught it).
        let inset = textView.textContainerInset
        let bounds = textView.bounds
        let point = CGPoint(
            x: min(max(localPoint.x, inset.width), max(inset.width, bounds.maxX - inset.width)),
            y: min(max(localPoint.y, inset.height), max(inset.height, bounds.maxY - inset.height)))
        let index = textView.characterIndexForInsertion(at: point)
        let clamped = max(0, min(index, length))
        textView.setSelectedRange(NSRange(location: clamped, length: 0))
    }
}
#endif
