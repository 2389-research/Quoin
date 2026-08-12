#if canImport(AppKit)
import AppKit
import QuoinCore
import QuoinRender

/// Phase 1, Task 6: the view-based `NSTableView` host that puts the per-block
/// cells (Tasks 1–5) into a recycling, scrolling list with deterministic row
/// heights. This is the substrate the Phase-0.5 spike validated: one reused
/// `BlockRenderCell` per visible row, drawn top-down, with row heights taken
/// verbatim from `BlockRowMetrics` so the recycler's content matches the
/// monolithic reader's projection height.
///
/// ## Two hazards carried from prior-task reviews (both real bugs)
///
/// (A) *Edge-cell bleed clipping* [Task 4]. A cell's FRAME is
/// `2 * DecorationDraw.verticalBleed` taller than its ROW: `BlockRowMetrics`
/// omits the first row's top bleed and the last row's bottom bleed, delegating
/// the document's two outer margins to the scroll view's content insets — the
/// same outer air the monolith has. So the scroll view MUST reserve
/// `>= verticalBleed` of top and bottom `contentInsets`, or the first block's
/// top decoration and the last block's bottom decoration clip. Set here in
/// `setUp` (see `scrollView.contentInsets`); pinned by
/// `BlockRecyclerViewTests.testContentInsetsReserveEdgeBleed`.
///
/// (B) *Async decode registration steal* [Task 5]. `AsyncImageStore` registers
/// a decode's `onReady` callback FIRST-CALLER-WINS, keyed by
/// `(path|mtime|maxDimension)`. A `BlockRenderCell` arms its `onContentSettled`
/// by rendering its block through an observing renderer that registers that
/// callback. If the recycler pre-sizes a PENDING image row by rendering the
/// same image through a DIFFERENT renderer first, it becomes the first caller,
/// the cell's later render returns nil without re-registering, and the cell's
/// `onContentSettled` never fires → the row freezes at placeholder height.
///
/// **Approach (i), chosen.** The height path never renders a pending image, so
/// the CELL always wins the registration. `heightRenderer` is a copy of the
/// supplied renderer with `imageResolution = .textReference`, which returns a
/// deterministic text placeholder for an image WITHOUT ever calling
/// `AsyncImageStore` (verified: `AttributedRenderer.imageAttributed` returns at
/// the `.textReference` branch before any `image(at:…)` call). For every
/// non-image block `.textReference` renders identically to `.async`, so those
/// heights are final immediately. For an image block the provisional row height
/// is the placeholder height; the cell (rendering through the real `.async`
/// `renderer`) is the sole first caller, so its `onContentSettled` fires when
/// the decode lands. That callback is wired to `contentDidSettle`, which
/// re-queries the row height through the real `renderer` — the decode is cached
/// by then, so `AsyncImageStore.image` returns the cache hit synchronously
/// (never re-registering) — records the settled height, and calls
/// `noteHeightOfRows(withIndexesChanged:)` for that block's row.
@MainActor
public final class BlockRecyclerView: NSView {

    // The real renderer (typically `.async`): handed to cells so THEY are the
    // first callers that arm the async decode, and used to re-query a settled
    // row height once the decode is cached (a cache hit, so no re-registration).
    private let renderer: AttributedRenderer
    // A non-stealing copy used ONLY for row-height pre-sizing: `.textReference`
    // renders images as a deterministic text placeholder without touching
    // `AsyncImageStore`, so it can never steal a decode registration from a cell
    // (hazard B). Identical to `renderer` for every non-image block.
    private let heightRenderer: AttributedRenderer
    private let theme: Theme

    private let scrollView = NSScrollView()
    private let tableView = ClickReportingTableView()

    private var document = QuoinDocument.empty
    private var contentWidth: CGFloat = 600

    // Settled (final) row heights, recorded when a previously-pending row's
    // decode lands. A block absent here is sized by `heightRenderer` — final for
    // non-image blocks, provisional (placeholder) for a still-decoding image.
    private var settledHeights: [BlockID: CGFloat] = [:]
    // Row index for a block id, rebuilt on every `setDocument`.
    private var rowByBlockID: [BlockID: Int] = [:]

    // Every `BlockRenderCell` we have ever handed out, held WEAKLY: with real
    // recycling the table's reuse pool retains only a bounded set and evicted
    // cells deallocate, so `allObjects.count` stays near "visible + buffer",
    // never one-per-block. This is the recycling instrument the brief's test
    // asserts (< 60 live for 400 blocks).
    private let liveCells = NSHashTable<BlockRenderCell>.weakObjects()

    // Phase 2, Task 5: the ONE block currently promoted to an editable island
    // (nil in pure read mode). `viewFor` returns a `BlockEditorCell` for exactly
    // this block's row and a `BlockRenderCell` for every other. Setting it
    // reloads the affected rows through `reloadData(forRowIndexes:)` — the
    // read↔edit transition MUST go through the table's reload (NOT a hand-swap
    // of the row view, which corrupts `settledHeights`/`rowByBlockID`). The
    // `IslandController` (this task) drives it.
    //
    // Phase 3 (click-seam re-shape): the read→edit direction is NO LONGER a
    // `didSet` side effect whose commit timing is an AppKit implementation detail
    // — it routes through `promoteRow(to:)`, an explicit synchronous operation
    // that forces the reload to commit and hands back the realized cell. Setting
    // this property to a non-nil id is now just sugar for `promoteRow` with the
    // result discarded; callers that need the cell (the `IslandController`) call
    // `promoteRow` directly. Clearing it (edit→read) still goes through the
    // table's reload.
    public var editingBlockID: BlockID? {
        get { _editingBlockID }
        set {
            guard newValue != _editingBlockID else { return }
            ilog("editingBlockID.set", "old=\(_editingBlockID.map { "\($0)" } ?? "nil") new=\(newValue.map { "\($0)" } ?? "nil")")
            if let newValue {
                _ = promoteRow(to: newValue)
            } else {
                demoteEditingRow()
            }
        }
    }
    private var _editingBlockID: BlockID?
    // The live editor cell for the current editing row, held weakly (the table
    // owns it in its reuse pool). Used to source the editing row's height from
    // the live island layout and to reach `islandTextView` for first-responder
    // handoff + flush read-back.
    private weak var liveEditorCell: BlockEditorCell?

    /// Phase 3 hotfix: true for the duration of a `reloadData(forRowIndexes:)`
    /// that rebuilds the LIVE editing row's cell. Such a rebuild removes the
    /// first-responder `IslandTextView` from the window, firing a TRANSIENT
    /// `resignFirstResponder`. The `IslandController`'s blur seam reads this flag
    /// and SUPPRESSES its deactivate for that transient resign (it is a table
    /// re-vend, NOT a user blur) — the recycler restores first responder to the
    /// rebuilt cell immediately after the reload. A genuine focus change (no
    /// editing-row reload in flight) leaves this false, so the island still
    /// deactivates. Read by `IslandController.handleIslandResignFirstResponder()`.
    private(set) var isReloadingEditingRow = false

    /// Fired AFTER the live editing row's cell is re-vended by a reload but BEFORE
    /// it retakes first responder, so the `IslandController` can re-install its
    /// responder seams (blur / Return / Backspace closures) onto the freshly built
    /// cell — those closures live on the cell instance, so a rebuild would
    /// otherwise drop them. Installed by the controller.
    var onEditingCellRebuilt: (() -> Void)?

    /// Report the top-most visible block (drives the outline sync).
    public var onTopBlockChange: ((BlockID) -> Void)?
    private var lastReportedTop: BlockID?

    /// Fan-out hook the `IslandController` installs (Phase 2, Task 6) to drive
    /// its reconcile debounce. The recycler stays the SOLE owner of the editing
    /// cell's single `onTextDidChange` slot (Task-5 invariant): its
    /// `editingCellDidChangeText` fans that ONE signal out to BOTH the row-height
    /// re-notify (`noteHeightOfRows`) AND this closure. Do NOT wire the cell's
    /// `onTextDidChange` from elsewhere — install here instead.
    var onEditingTextChanged: (() -> Void)?

    /// Single-click seam (Phase 2, Task 2): fired when the user clicks a row,
    /// reporting the clicked block and the click's CELL-LOCAL point (origin at
    /// the cell's top-left, flipped like the cell). Phase 2 only REPORTS the
    /// click here — swapping the row's cell to an editable island is Task 5,
    /// which consumes this callback. Selection highlight stays `.none`.
    public var onBlockClicked: ((BlockID, CGPoint) -> Void)?

    /// Wrap long lines to the column, or (false) let them run under a horizontal
    /// scroller — the reader-wide `QuoinWordWrap` preference, forwarded so the
    /// flag-on recycler honours it instead of silently always wrapping. Phase 1
    /// is read-only and lays every cell at the fixed content column, so today
    /// this only toggles the container's horizontal scroller; per-cell no-wrap
    /// layout is a Phase-2 item (tracked with the editing surface). Defaults to
    /// wrap, the projection reader's default.
    public var wordWrap: Bool = true {
        didSet {
            guard wordWrap != oldValue else { return }
            scrollView.hasHorizontalScroller = !wordWrap
        }
    }

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("QuoinBlockRenderCell")
    // Phase 2, Task 5: the SECOND reuse identifier — the editable island cell.
    // A distinct pool keeps the read cells' recycling instrument (`liveCells`)
    // clean and lets `viewFor` dequeue the right leaf per row.
    private static let blockEditorCellIdentifier = NSUserInterfaceItemIdentifier("QuoinBlockEditorCell")
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("QuoinBlockColumn")

    public init(renderer: AttributedRenderer, theme: Theme) {
        self.renderer = renderer
        self.theme = theme
        self.heightRenderer = AttributedRenderer(
            theme: renderer.theme,
            baseURL: renderer.baseURL,
            loadsRemoteImages: renderer.loadsRemoteImages,
            imageResolution: .textReference
        )
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setUp() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        // Hazard (A): the first row omits its top bleed and the last row omits
        // its bottom bleed (BlockRowMetrics delegates the document's outer
        // margins to the container). Reserve that bleed as content insets so the
        // edge cells' decorations don't clip.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: DecorationDraw.verticalBleed, left: 0,
            bottom: DecorationDraw.verticalBleed, right: 0)

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .none
        tableView.style = .plain
        tableView.usesAutomaticRowHeights = false
        tableView.rowSizeStyle = .custom
        // Rows already carry their own decoration bleed + inter-block separator
        // (BlockRowMetrics), so the table must add no extra inter-cell air.
        tableView.intercellSpacing = .zero

        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = []
        column.width = contentWidth + 2 * DecorationDraw.leftGutter
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        // Click seam (Phase 2, Task 2): the table forwards its own `mouseDown`
        // (the view the click actually hits) so `onBlockClicked` fires for a
        // real click. Reporting happens BEFORE the table's internal row
        // tracking, so the callback does not depend on that loop completing.
        tableView.onMouseDown = { [weak self] event in
            self?.handleTableMouseDown(event) ?? false
        }
        // Defense in depth for the first-responder theft the live trace showed
        // (`NSWindow._realMakeFirstResponder` reclaiming focus for the table from
        // inside `super.mouseDown`'s tracking loop, in a KEY window). The forward
        // path below never calls `super.mouseDown`, so the table cannot reach that
        // code — but nothing else in this view wants the table to hold first
        // responder either: it has no selection (`.none`), no type-select, and no
        // keyboard behaviour of its own. Every keystroke belongs to the island.
        tableView.refusesFirstResponder = true

        scrollView.documentView = tableView
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        // Top-block reporting: observe the clip view's bounds so a scroll (from
        // `scroll(to:)` or the user) recomputes the top visible row.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsDidChange),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    // MARK: - Public API

    /// Reload the list for `document`, laying every cell's text out at
    /// `contentWidth`.
    public func setDocument(_ document: QuoinDocument, contentWidth: CGFloat) {
        ilog("setDocument", "blocks=\(document.blocks.count) stack=\(islandShortStack(6))")
        // A fresh document dissolves any active island: clear editing WITHOUT the
        // didSet's partial reload (the full `reloadData` below covers it).
        clearEditingWithoutReload()
        self.document = document
        self.contentWidth = contentWidth
        settledHeights.removeAll()
        rowByBlockID.removeAll()
        for (index, block) in document.blocks.enumerated() {
            rowByBlockID[block.id] = index
        }
        lastReportedTop = nil
        tableView.tableColumns.first?.width = contentWidth + 2 * DecorationDraw.leftGutter
        tableView.reloadData()
    }

    /// Phase 2 final-review fix: refresh the list for a NEW document produced by
    /// the ACTIVE island's own KEEP reconcile, WITHOUT tearing the island down.
    ///
    /// The plain `setDocument` unconditionally `clearEditingWithoutReload()`s and
    /// full-`reloadData()`s — correct for an external document swap, catastrophic
    /// for a revision bump that came from the island's OWN reconcile: it reverts
    /// the just-edited row to a read-only cell, drops first responder + caret, and
    /// leaves the `IslandController` desynced (its `activeIsland` still set against
    /// a now-missing editor cell → the next flush empty-splices and DELETES the
    /// block). See the reader view's `apply` and `IslandController.applyReconciled`
    /// for the coordinated seam.
    ///
    /// A KEEP reconcile changes the edited block's CONTENT, so its content-hash
    /// `BlockID` changes. This method locates the editing row by the island's
    /// STABLE START BYTE (`islandStartByte`) — bytes BEFORE the island never move
    /// across the island's own edits, so the start offset is invariant while the
    /// content-hash id mutates on every keystroke. It re-points the recycler's
    /// editing identity (`_editingBlockID` + the live cell's `blockID`) onto the
    /// block that now owns that offset, rebuilds the row map, reloads every
    /// NON-editing row, and KEEPS the editing row's `BlockEditorCell` (and thus its
    /// first responder + caret) untouched.
    ///
    /// Locating by position (not the stale id) makes this refresh IDEMPOTENT with
    /// `IslandController.applyReconciled` in EITHER order: both do the same
    /// `record(at:)`-based re-anchor, and re-pointing no-ops when the id is already
    /// current. Previously the guard was `document.blocks.contains { $0.id ==
    /// _editingBlockID }`, which failed when this refresh raced AHEAD of
    /// `applyReconciled` (id not yet re-anchored) → fell back to `setDocument` →
    /// island torn down. Now the ordering no longer matters.
    ///
    /// Falls back to `setDocument` whenever the invariants don't hold (not editing,
    /// no island start byte, the start offset resolves to no block, or the row
    /// count changed) — so the read-only / flag-off path is byte-identical to
    /// before.
    public func updateDocumentPreservingEditing(_ document: QuoinDocument, contentWidth: CGFloat, islandStartByte: Int?) {
        ilog("preserve.enter", "islandStartByte=\(islandStartByte.map { "\($0)" } ?? "nil") oldRowCount=\(tableView.numberOfRows) newRowCount=\(document.blocks.count)")
        // Read-only / flag-off path: no active editing island (or no island start)
        // → full swap, byte-identical to before.
        guard _editingBlockID != nil, liveEditorCell != nil,
              let islandStartByte else {
            ilog("preserve.fallback.setDocument", "reason=noActiveIsland")
            setDocument(document, contentWidth: contentWidth)
            return
        }
        // Locate the editing row by the island's STABLE start byte. `record(at:)`
        // is content-ranges-only (nil for a separator-gap offset), but the island
        // start is always inside a block's content, so this resolves. A KEEP
        // reconcile leaves the block COUNT unchanged; a Phase-3 structural op
        // (split/merge) changes it — Task 4 handles that WITHOUT tearing down (see
        // the count-change branch below), so the guard only bails when the island
        // start resolves to no block at all.
        guard let record = BlockListModel(document: document).record(at: islandStartByte) else {
            ilog("preserve.fallback.setDocument", "reason=noRecordAtStartByte")
            setDocument(document, contentWidth: contentWidth)
            return
        }
        let newID = record.blockID
        let oldRowCount = tableView.numberOfRows
        let newRowCount = document.blocks.count
        // The editing cell's CURRENT physical slot (before the model rebuild), so a
        // structural count change can shift its view to the right row via row
        // insert/remove instead of a full reload (which would re-vend it and drop
        // first responder + caret).
        let oldEditingRow = _editingBlockID.flatMap { rowByBlockID[$0] }
        self.document = document
        self.contentWidth = contentWidth
        // WIDTH DRIFT (Phase 3): the KEEP path below spares the editing row from
        // the reload, which is the only path that re-`configure`s the island's text
        // container. Re-lay the LIVE island at the new column explicitly — geometry
        // only, so unflushed keystrokes are never clobbered. No-op at equal width.
        updateEditingCellWidth(contentWidth)
        settledHeights.removeAll()
        rowByBlockID.removeAll()
        for (index, block) in document.blocks.enumerated() {
            rowByBlockID[block.id] = index
        }
        // Re-point the editing identity onto the block that now owns the island's
        // start byte (folds `reanchorEditing`'s body): the content-hash id changed
        // with the edit, so update `_editingBlockID` and the live cell's `blockID`.
        // No-ops when already current (e.g. `applyReconciled` re-anchored first),
        // which is what makes the two paths order-independent.
        if _editingBlockID != newID {
            _editingBlockID = newID
            liveEditorCell?.reassignBlockID(newID)
        }
        lastReportedTop = nil
        tableView.tableColumns.first?.width = contentWidth + 2 * DecorationDraw.leftGutter
        let editingRow = rowByBlockID[newID]
        if newRowCount == oldRowCount {
            ilog("preserve.keep", "editingRow=\(editingRow.map { "\($0)" } ?? "nil") newID=\(newID)")
            // KEEP path: reload every row EXCEPT the live editing row, which keeps
            // its realized `BlockEditorCell` (first responder + caret survive).
            var rows = IndexSet(integersIn: 0..<newRowCount)
            if let editingRow { rows.remove(editingRow) }
            if !rows.isEmpty {
                withoutAnimation {
                    tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
                }
            }
            // The editing block's byte content changed; re-size its row off the live
            // cell layout (its height is excluded from `settledHeights`).
            if let editingRow {
                noteRowHeights(IndexSet(integer: editingRow))
            }
        } else {
            // STRUCTURAL count change (Phase 3, Task 4): a split/merge changed the
            // row count. Reconcile the table WITHOUT tearing the island down —
            // shift the editing cell to its new row via insert/remove (which move
            // existing row views instead of re-vending them, so first responder +
            // caret survive), then refresh every other row's content.
            ilog("preserve.rowcount", "oldRowCount=\(oldRowCount) newRowCount=\(newRowCount) oldEditingRow=\(oldEditingRow.map { "\($0)" } ?? "nil") newEditingRow=\(editingRow.map { "\($0)" } ?? "nil")")
            reconcileRowCountKeepingEditing(
                oldRowCount: oldRowCount, newRowCount: newRowCount,
                oldEditingRow: oldEditingRow, newEditingRow: editingRow)
        }
    }

    /// Reconcile a structural row-count change while KEEPING the live editing cell
    /// (first responder + caret). The island's edit is localized to the editing
    /// block's region, so the delta rows are inserted/removed around it: rows added
    /// BEFORE the editing block shift its view DOWN, rows added AFTER leave it in
    /// place — `insert`/`removeRows` move existing views rather than re-vend them,
    /// which is what preserves the editor cell. Every non-editing row is then
    /// reloaded to pick up its new content/position.
    private func reconcileRowCountKeepingEditing(
        oldRowCount: Int, newRowCount: Int, oldEditingRow: Int?, newEditingRow: Int?
    ) {
        // Without a realized editing row to preserve, a full reload is correct.
        guard let oldEditingRow, let newEditingRow else {
            tableView.reloadData()
            return
        }
        let delta = newRowCount - oldRowCount
        withoutAnimation {
            tableView.beginUpdates()
            if delta > 0 {
                // `insertedBefore` rows land ahead of the editing block (shifting its
                // view down from `oldEditingRow` to `newEditingRow`); the rest land
                // just after it.
                let insertedBefore = min(max(0, newEditingRow - oldEditingRow), delta)
                let insertedAfter = delta - insertedBefore
                if insertedBefore > 0 {
                    tableView.insertRows(
                        at: IndexSet(integersIn: oldEditingRow..<(oldEditingRow + insertedBefore)),
                        withAnimation: [])
                }
                if insertedAfter > 0 {
                    tableView.insertRows(
                        at: IndexSet(integersIn: (newEditingRow + 1)..<(newEditingRow + 1 + insertedAfter)),
                        withAnimation: [])
                }
            } else if delta < 0 {
                let removed = -delta
                // Symmetric: rows removed BEFORE the editing block shift its view up.
                let removedBefore = min(max(0, oldEditingRow - newEditingRow), removed)
                let removedAfter = removed - removedBefore
                if removedBefore > 0 {
                    tableView.removeRows(
                        at: IndexSet(integersIn: newEditingRow..<(newEditingRow + removedBefore)),
                        withAnimation: [])
                }
                if removedAfter > 0 {
                    tableView.removeRows(
                        at: IndexSet(integersIn: (newEditingRow + 1)..<(newEditingRow + 1 + removedAfter)),
                        withAnimation: [])
                }
            }
            tableView.endUpdates()
            // Refresh every NON-editing row (their blocks/positions changed); the
            // editing row keeps its shifted, still-realized cell.
            var rows = IndexSet(integersIn: 0..<newRowCount)
            rows.remove(newEditingRow)
            if !rows.isEmpty {
                tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
            }
        }
        noteRowHeights(IndexSet(integer: newEditingRow))
    }

    /// KEEP-path re-anchor handoff from `IslandController.applyReconciled`: a
    /// reconcile changed the edited block's content, so its content-hash id
    /// changed. Re-point the recycler's editing identity — `_editingBlockID`, the
    /// live cell's `blockID`, and the row map — onto the NEW id WITHOUT any reload,
    /// so the still-live editor cell (first responder + caret) is left exactly as
    /// it is. The subsequent revision-driven `updateDocumentPreservingEditing`
    /// swaps the document around this already-re-pointed editing row.
    func reanchorEditing(to newID: BlockID) {
        guard let oldID = _editingBlockID, oldID != newID else { return }
        if let row = rowByBlockID[oldID] {
            rowByBlockID[oldID] = nil
            rowByBlockID[newID] = row
        }
        _editingBlockID = newID
        liveEditorCell?.reassignBlockID(newID)
    }

    /// Outline-click target: bring `blockID`'s row into view.
    public func scroll(to blockID: BlockID) {
        guard let row = rowByBlockID[blockID], row < tableView.numberOfRows else { return }
        scrollToCallCountForTest += 1
        tableView.scrollRowToVisible(row)
        // `scrollRowToVisible` posts the clip view's bounds change, but report
        // directly too so the top-block sync is deterministic in tests and does
        // not depend on notification-delivery timing.
        reportTopBlock()
    }

    /// Count of live `BlockRenderCell` instances — bounded by recycling, never
    /// one-per-block (the recycling contract the brief's test asserts).
    public var visibleCellCount: Int { liveCells.allObjects.count }

    // MARK: - Editing island (Phase 2, Task 5)

    /// Row index for `blockID` in the current document, or nil.
    func rowForBlockID(_ blockID: BlockID) -> Int? { rowByBlockID[blockID] }

    /// The live `BlockEditorCell` currently hosting the island (nil when not
    /// editing or the row is not yet realized). The `IslandController` reaches
    /// through this for first-responder handoff and flush read-back.
    var currentEditorCell: BlockEditorCell? { liveEditorCell }

    /// Force-realize and return the editable island cell for the current editing
    /// row, so the controller can make it first responder and place the caret
    /// synchronously (not on a later display pass).
    func editorCellForEditingRow() -> BlockEditorCell? {
        guard let id = _editingBlockID, let row = rowByBlockID[id],
              row < tableView.numberOfRows else { return nil }
        return tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? BlockEditorCell
    }

    /// **Promote `blockID`'s row to the editable island, synchronously.**
    ///
    /// This is the read→edit transition as an EXPLICIT OPERATION rather than a
    /// `didSet` side effect. The old shape set `editingBlockID`, whose `didSet`
    /// armed a `reloadData(forRowIndexes:)` and returned; whether that reload had
    /// COMMITTED by the time the controller handed first responder to the island
    /// was an AppKit implementation detail (synchronous on a clean bare table —
    /// which is why the hotfix tested green — DEFERRED under `NSHostingView`, where
    /// it commits later, inside `super.mouseDown`'s tracking loop, re-vending the
    /// row and evicting the just-focused island). Nothing may depend on that timing
    /// again, so the commit is forced here and the REALIZED cell is the return
    /// value: the caller proceeds only if it gets a live cell.
    ///
    /// Contract:
    ///  • Sets the editing identity, reloads the incoming row (and the outgoing
    ///    editing row, back to read-only) through the TABLE'S RELOAD — never a
    ///    hand-swap of the row view (see the `editingBlockID` invariant above).
    ///  • Forces the reload to commit (`layoutSubtreeIfNeeded`), realizes the row's
    ///    view, re-queries the row height off the LIVE island layout, and commits
    ///    that too.
    ///  • Runs the whole swap inside a zero-duration `NSAnimationContext` and
    ///    restores the viewport anchor afterwards (spec §4 steps 3 + 6), so the
    ///    height flip neither animates nor moves the clicked row on screen.
    ///  • `isReloadingEditingRow` is raised as a LEXICAL bracket around the actual
    ///    re-vend, so the controller's blur seam provably cannot read the re-vend's
    ///    transient resign as a user blur.
    ///  • Returns the in-hierarchy `BlockEditorCell`, or nil if the row could not be
    ///    realized as one — a nil is a clean failure (no half-promoted row): the
    ///    caller (`IslandController.activate`) abandons the swap.
    @discardableResult
    func promoteRow(to blockID: BlockID) -> BlockEditorCell? {
        // Re-promoting the row that is ALREADY the island is a no-op swap: no
        // reload, no churn — just hand back the live cell.
        if _editingBlockID == blockID {
            let cell = editorCellForEditingRow()
            ilog("promote.alreadyEditing", "blockID=\(blockID) cell=\(cell != nil)")
            return cell
        }
        let outgoing = _editingBlockID
        guard let row = rowByBlockID[blockID], row < tableView.numberOfRows else {
            // No row for this block (not in the current document / not yet
            // realized). Move the identity so `viewFor` vends an island when the row
            // does appear, but report FAILURE: there is no cell to focus.
            ilog("promote.fail", "reason=noRow blockID=\(blockID)")
            _editingBlockID = blockID
            liveEditorCell = nil
            return nil
        }

        var rows = IndexSet(integer: row)
        // The editing row is sized from the LIVE island layout, so drop any stale
        // settled (read-path) height for both the incoming and outgoing rows.
        settledHeights[blockID] = nil
        if let outgoing {
            settledHeights[outgoing] = nil
            if let oldRow = rowByBlockID[outgoing], oldRow != row,
               oldRow < tableView.numberOfRows {
                rows.insert(oldRow)
            }
        }

        // FREEZE (spec §4 step 3): record the scroll origin + the target row's
        // frame before anything moves.
        let anchor = viewportAnchor(forRow: row)
        var realized: BlockEditorCell?
        // LEXICAL suppression bracket: raised here, lowered below, with the actual
        // re-vend provably inside it (not a flag around a deferred call).
        isReloadingEditingRow = true
        withoutAnimation {
            _editingBlockID = blockID
            liveEditorCell = nil
            tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
            // FORCE the commit: under `NSHostingView` this reload would otherwise
            // coalesce into a later pass.
            tableView.layoutSubtreeIfNeeded()
            realized = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? BlockEditorCell
            if let realized { liveEditorCell = realized }
            // Re-query the row height so it comes off the LIVE island layout (raw
            // source) instead of the projected read height — for headings (`#`),
            // code (fences) and tables (pipes) the two differ, and the row would
            // otherwise stay mis-sized on a click with no edit.
            noteEditingRowHeight()
            tableView.layoutSubtreeIfNeeded()
        }
        isReloadingEditingRow = false
        // UNFREEZE (spec §4 step 6): the target row's layout is committed; put the
        // viewport back so the clicked line has not moved on screen.
        restoreViewportAnchor(anchor, forRow: row)

        guard let realized, realized.blockID == blockID else {
            ilog("promote.fail", "reason=notAnEditorCell blockID=\(blockID) row=\(row)")
            return nil
        }
        ilog("promote.ok", "blockID=\(blockID) row=\(row) frame=\(NSStringFromRect(realized.frame))")
        return realized
    }

    /// The edit→read direction: drop the editing identity and reload the row that
    /// was the island so `viewFor` vends a read-only cell again.
    private func demoteEditingRow() {
        let old = _editingBlockID
        _editingBlockID = nil
        reloadRows(forBlocks: [old])
        liveEditorCell = nil
    }

    /// Re-query the editing row's height so it picks up the LIVE island layout
    /// (raw source) instead of the projected read height. Fired once at promotion
    /// and again on every keystroke (`editingCellDidChangeText`).
    func noteEditingRowHeight() {
        guard let id = _editingBlockID, let row = rowByBlockID[id],
              row < tableView.numberOfRows else { return }
        noteRowHeights(IndexSet(integer: row))
    }

    /// Phase 3 (width drift, the confirmed defect): re-lay the LIVE island cell at
    /// `width` without re-vending it and WITHOUT re-seeding its text.
    ///
    /// `updateDocumentPreservingEditing`'s KEEP path spares the editing row from the
    /// reload (so first responder + caret survive), and the reload is the only path
    /// that reaches `BlockEditorCell.configure(slice:blockID:width:)` — the only
    /// setter of the island's text-container width. A re-apply at a NEW width
    /// therefore re-framed the cell while the island still laid out at the OLD
    /// column, and `rowHeight(atRow:)` measured the row at a width it did not have:
    /// mis-size then re-size, i.e. the visible jiggle. This is the explicit path
    /// that keeps the two in step. The island's text is authoritative — only
    /// geometry moves.
    func updateEditingCellWidth(_ width: CGFloat) {
        guard let cell = liveEditorCell, cell.currentContentWidth != width else { return }
        ilog("width.reconfigureLiveIsland",
             "old=\(cell.currentContentWidth) new=\(width) blockID=\(cell.blockID.map { "\($0)" } ?? "nil")")
        cell.updateWidth(width)
    }

    // MARK: - Spec §4 steps 3 + 6: freeze / unfreeze the viewport

    /// The scroll origin plus the target row's position at FREEZE time.
    private struct ViewportAnchor {
        let scrollOrigin: CGPoint
        let rowMinY: CGFloat
    }

    private func viewportAnchor(forRow row: Int) -> ViewportAnchor {
        ViewportAnchor(
            scrollOrigin: scrollView.contentView.bounds.origin,
            rowMinY: (row >= 0 && row < tableView.numberOfRows)
                ? tableView.rect(ofRow: row).minY : 0)
    }

    /// Restore the recorded anchor: if the swap changed the target row's position
    /// in the document (rows above it re-sized), shift the scroll origin by exactly
    /// that delta so the row — and the line the user clicked on — stays where it was
    /// on screen. Spec §4's drift target is < 4 pt; this is exact. A no-op in the
    /// common case (only the target row's own height changed), which is what keeps
    /// the recycler from ever scrolling on a click.
    private func restoreViewportAnchor(_ anchor: ViewportAnchor, forRow row: Int) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        let delta = tableView.rect(ofRow: row).minY - anchor.rowMinY
        let target = CGPoint(x: anchor.scrollOrigin.x, y: anchor.scrollOrigin.y + delta)
        let current = scrollView.contentView.bounds.origin
        guard abs(current.x - target.x) > 0.01 || abs(current.y - target.y) > 0.01 else { return }
        ilog("viewport.restore",
             "row=\(row) delta=\(delta) \(NSStringFromPoint(current))→\(NSStringFromPoint(target))")
        withoutAnimation {
            scrollView.contentView.scroll(to: target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Run `body` with implicit animation OFF and a ZERO animation duration.
    ///
    /// Every `noteHeightOfRows(withIndexesChanged:)` used to be called bare, so
    /// AppKit ANIMATED each read-height↔island-height flip — the animated
    /// grow/shrink the user sees as the row "jiggling". Every table op that can
    /// change a row's height now runs inside this.
    private func withoutAnimation(_ body: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        // Instrumentation only (see `animationDurationsForTest`); bounded so a long
        // editing session cannot grow it without limit.
        if animationDurationsForTest.count >= 64 { animationDurationsForTest.removeFirst() }
        animationDurationsForTest.append(NSAnimationContext.current.duration)
        body()
        NSAnimationContext.endGrouping()
    }

    /// The ONE height-invalidation seam: always zero-duration (see
    /// `withoutAnimation`), and instrumented so a test can prove the height change
    /// was applied with no animation.
    private func noteRowHeights(_ rows: IndexSet) {
        guard !rows.isEmpty else { return }
        withoutAnimation {
            tableView.noteHeightOfRows(withIndexesChanged: rows)
        }
    }

    /// Reload the current editing row (the read↔edit transition goes through
    /// `reloadData(forRowIndexes:)`, never a hand-swap of the row view).
    func reloadEditingRow() {
        guard let id = _editingBlockID else { return }
        reloadRows(forBlocks: [id])
    }

    private func clearEditingWithoutReload() {
        ilog("clearEditing", "editingBlockID=\(_editingBlockID.map { "\($0)" } ?? "nil") stack=\(islandShortStack(6))")
        _editingBlockID = nil
        liveEditorCell = nil
    }

    /// Reload the rows for the given blocks (dedup + drop missing/out-of-range),
    /// so `viewFor` re-vends the correct leaf (read vs edit) for each.
    private func reloadRows(forBlocks blocks: [BlockID?]) {
        var rows = IndexSet()
        for case let id? in blocks {
            // The editing row is sized from the LIVE island layout, so drop any
            // stale settled (read-path) height for it.
            settledHeights[id] = nil
            if let row = rowByBlockID[id], row < tableView.numberOfRows {
                rows.insert(row)
            }
        }
        guard !rows.isEmpty else { return }

        // FIRST-RESPONDER CONTINUITY (Phase 3 hotfix): a `reloadData(forRowIndexes:)`
        // that includes the LIVE editing row DESTROYS + recreates its
        // `BlockEditorCell`, removing the first-responder `IslandTextView` from the
        // window → a TRANSIENT `resignFirstResponder`. The `IslandController` must
        // NOT read that as a genuine blur (it would self-deactivate the island the
        // click just created). Flag the reload so its blur seam suppresses
        // deactivate, then — if the island genuinely held first responder — restore
        // first responder + caret to the rebuilt cell and let the controller
        // re-install its responder seams on it.
        let editingRow = _editingBlockID.flatMap { rowByBlockID[$0] }
        let touchesEditingRow = editingRow.map { rows.contains($0) } ?? false
        let priorIslandTextView = liveEditorCell?.islandTextView
        let islandWasFirstResponder = touchesEditingRow
            && priorIslandTextView != nil
            && window?.firstResponder === priorIslandTextView
        let savedSelection = islandWasFirstResponder ? priorIslandTextView?.selectedRange() : nil

        if touchesEditingRow { isReloadingEditingRow = true }
        withoutAnimation {
            tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        }
        guard touchesEditingRow else { return }
        isReloadingEditingRow = false

        // Restore focus ONLY when the island actually HELD it before the rebuild.
        // A read→edit transition (activation) or an edit→read teardown
        // (deactivate) had no island first responder to preserve — each
        // installs/omits focus itself.
        guard islandWasFirstResponder, let cell = liveEditorCell,
              cell.blockID == _editingBlockID else { return }
        // Re-wire the controller's responder seams (blur/Return/Backspace) onto the
        // freshly vended cell before it takes first responder.
        onEditingCellRebuilt?()
        if let savedSelection {
            let length = (cell.islandTextView.string as NSString).length
            let loc = min(savedSelection.location, length)
            let len = min(savedSelection.length, length - loc)
            cell.islandTextView.setSelectedRange(NSRange(location: loc, length: len))
        }
        cell.window?.makeFirstResponder(cell.islandTextView)
        ilog("reloadRows.restoredFR", "editingRow=\(editingRow.map { "\($0)" } ?? "nil")")
    }

    // The island cell's live edits re-notify its own row height (the editing row
    // is excluded from `settledHeights`; its height is the live text layout) AND
    // fan out to the `IslandController`'s reconcile debounce (Task 6). This is
    // the SINGLE owner of the cell's `onTextDidChange` slot; both consumers are
    // driven from here so neither clobbers the other.
    private func editingCellDidChangeText(_ cell: BlockEditorCell) {
        if let id = cell.blockID, let row = rowByBlockID[id],
           row < tableView.numberOfRows {
            // Zero-duration: a height change WHILE TYPING must not animate either
            // (an animated grow on every keystroke is the same jiggle, per key).
            noteRowHeights(IndexSet(integer: row))
        }
        onEditingTextChanged?()
    }

    // MARK: - Click seam (Phase 2, Task 2)

    /// Resolve a WINDOW-space point to the block under it plus the point in that
    /// row's CELL-LOCAL coordinates (origin at the cell top-left, flipped). Pure
    /// resolver: no side effects, no cell swap — the click reporter and the test
    /// hook both go through it, so what a click reports is exactly what the test
    /// asserts. Returns nil when the point misses every row.
    public func blockAndPoint(forWindowPoint windowPoint: CGPoint) -> (BlockID, CGPoint)? {
        let tablePoint = tableView.convert(windowPoint, from: nil)
        let row = tableView.row(at: tablePoint)
        guard row >= 0, row < document.blocks.count else { return nil }
        let rowRect = tableView.rect(ofRow: row)
        // Cell-local: subtract the row's origin (table + cell are both flipped,
        // so y grows downward from the cell top).
        let local = CGPoint(x: tablePoint.x - rowRect.minX,
                            y: tablePoint.y - rowRect.minY)
        return (document.blocks[row].id, local)
    }

    /// True only for the LEXICAL duration of the forwarding click path below. The
    /// `IslandController` reads it to skip its row-local `placeCaret` math: on this
    /// path the ORIGINAL event is handed to the island's text view, which places its
    /// own caret from its own coordinate space (correct by construction, and the
    /// only way drag-select works on the promoting click). The row-local point fed
    /// to `characterIndexForInsertion` was measured from the ROW's top-left while
    /// the text view is inset by the decoration bleed/gutter — an off-by-inset
    /// caret.
    private(set) var isForwardingClickToIsland = false

    /// **The click seam: promote, then forward — never call `super`.**
    ///
    /// Returns `true` when this call fully handled the click (the row was promoted
    /// and the ORIGINAL event forwarded to the new island's text view), in which
    /// case `ClickReportingTableView` does NOT call `super.mouseDown`. The table
    /// then never processes the click at all: it cannot take first responder inside
    /// `NSWindow._realMakeFirstResponder` (the live trace's "island focused, then
    /// instantly de-focused, `firstResponder=ClickReportingTableView`"), cannot
    /// select the row, cannot start a row drag, and cannot spin its modal tracking
    /// loop (which is where the deferred row reload used to commit and evict the
    /// just-focused island).
    ///
    /// Decision tree — anything not listed FORWARDS:
    ///  • not a left mouse-down → `super` (right/control-click keeps table + menu
    ///    semantics; AppKit routes those through `rightMouseDown`/`menu(for:)`, and
    ///    a control-click that arrives as a left-down is caught by the modifier
    ///    test below).
    ///  • ANY of ⌘/⇧/⌥/⌃ held → `super`. Modifier-clicks are reserved for
    ///    (future) block selection, which is table-level semantics.
    ///  • resolves to NO block (empty area under the last row, scrollers) → `super`.
    ///  • the click did not produce a live island cell for that block → `super`
    ///    (never swallow a click that promoted nothing).
    ///  • DOUBLE / TRIPLE clicks → FORWARDED, deliberately. A double-click inside a
    ///    block means "select the word", which is the TEXT VIEW's job; the table has
    ///    no double-click action (`doubleAction` is unset, selection is `.none`), so
    ///    routing them to `super` would lose word/paragraph select on the promoting
    ///    click for no gain. The forwarded event carries its own `clickCount`, so
    ///    `NSTextView` does the right thing with it.
    ///
    /// The click report is armed on the table subclass (`ClickReportingTableView`),
    /// NOT via a `mouseDown` override on this ancestor: `NSTableView` consumes a row
    /// click in its own `mouseDown` and never bubbles it up the view hierarchy, so
    /// an override here would be dead for real clicks.
    @discardableResult
    func handleTableMouseDown(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown else {
            ilog("click.super", "reason=notLeftMouseDown type=\(event.type.rawValue)")
            return false
        }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        guard modifiers.isEmpty else {
            ilog("click.super", "reason=modifierClick flags=\(modifiers.rawValue)")
            return false
        }
        guard let (blockID, localPoint) = blockAndPoint(forWindowPoint: event.locationInWindow) else {
            ilog("click.super", "reason=noBlock")
            return false
        }
        ilog("click.report", "blockID=\(blockID) clickCount=\(event.clickCount)")

        // PROMOTE (synchronously, via `IslandController.activate` → `promoteRow`).
        isForwardingClickToIsland = true
        onBlockClicked?(blockID, localPoint)
        isForwardingClickToIsland = false

        guard let cell = liveEditorCell, let editing = _editingBlockID,
              cell.blockID == editing, cell.window != nil else {
            ilog("click.super", "reason=noLiveIslandAfterPromote blockID=\(blockID)")
            return false
        }
        // FORWARD: the island's text view runs its OWN native tracking loop for
        // this very event — it places its own caret and supports drag-select on
        // the promoting click.
        ilog("click.forward", "blockID=\(editing) clickCount=\(event.clickCount)")
        cell.islandTextView.mouseDown(with: event)
        // Belt and braces: the island owns focus at the end of the click, whatever
        // the text view's own tracking did with it.
        if window?.firstResponder !== cell.islandTextView {
            cell.window?.makeFirstResponder(cell.islandTextView)
        }
        ilog("click.forward.post", {
            let fr = self.window?.firstResponder
            return "firstResponder=\(fr.map { String(describing: type(of: $0)) } ?? "nil") "
                + "selectedRow=\(self.tableView.selectedRow) "
                + "sel=\(NSStringFromRange(cell.islandTextView.selectedRange()))"
        }())
        return true
    }

    // MARK: - Height

    private func rowHeight(atRow row: Int) -> CGFloat {
        guard row >= 0, row < document.blocks.count else { return 1 }
        let block = document.blocks[row]
        // The editing row is EXCLUDED from `settledHeights`/heightRenderer sizing:
        // its height is the LIVE island text layout, re-notified via
        // `noteHeightOfRows` on the cell's `onTextDidChange`. Fall back to the
        // read metric until the island cell is realized so the row never
        // collapses to zero.
        if block.id == _editingBlockID {
            if let cell = liveEditorCell, cell.blockID == block.id {
                // Same arithmetic as the read row (bleed + outer-edge carve-out
                // + separator contribution), with the LIVE island layout
                // standing in for the read metric — so promoting a row changes
                // only what the text itself measures.
                return BlockRowMetrics.rowHeight(
                    forTextHeight: cell.fittingHeightForConfiguredWidth,
                    of: block, at: row, in: document,
                    renderer: heightRenderer, width: contentWidth)
            }
            return BlockRowMetrics.rowHeight(
                for: block, at: row, in: document,
                renderer: heightRenderer, theme: theme, width: contentWidth)
        }
        if let settled = settledHeights[block.id] { return settled }
        // Non-stealing height (hazard B): `heightRenderer` is `.textReference`,
        // so a pending image is a placeholder here and never touches the decode
        // store — the cell stays the sole first caller. Final for every other
        // block kind.
        return BlockRowMetrics.rowHeight(
            for: block, at: row, in: document,
            renderer: heightRenderer, theme: theme, width: contentWidth)
    }

    private func contentDidSettle(for blockID: BlockID) {
        guard let row = rowByBlockID[blockID], row < document.blocks.count else { return }
        let block = document.blocks[row]
        // The decode is cached now (onReady fired after the store cached it), so
        // the real `renderer` hits the cache synchronously — the settled content
        // height, with no new registration.
        let height = BlockRowMetrics.rowHeight(
            for: block, at: row, in: document,
            renderer: renderer, theme: theme, width: contentWidth)
        settledHeights[blockID] = height
        didRecordSettledHeightForTest?(blockID)
        noteRowHeights(IndexSet(integer: row))
    }

    // MARK: - Top-block reporting

    @objc private func boundsDidChange() {
        reportTopBlock()
    }

    private func reportTopBlock() {
        guard !document.blocks.isEmpty else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        let topRow = visible.location
        guard topRow >= 0, topRow < document.blocks.count else { return }
        let id = document.blocks[topRow].id
        guard id != lastReportedTop else { return }
        lastReportedTop = id
        onTopBlockChange?(id)
    }

    // MARK: - Accessibility structure rotors (Phase 1, Task 7)

    // Retained here because `NSAccessibilityCustomRotor` holds its search
    // delegate weakly. The recycler is the rotors' owner / target element.
    private lazy var headingRotorDelegate = BlockStructureRotorDelegate(owner: self)
    private lazy var blockRotorDelegate = BlockStructureRotorDelegate(owner: self)

    /// Vends two VoiceOver custom rotors so a listener navigates the document
    /// by structure instead of stepping every row:
    ///   • **Headings** (`.heading`) — jump heading to heading.
    ///   • **Blocks** — flick through the other structural blocks (code, table,
    ///     list, callout, quote, diagram, math, …), each announced with its
    ///     `BlockAccessibility` label.
    /// Items are recomputed from `document.blocks` on each query (the table-level
    /// analogue of the monolith's storage scan) and stepped via
    /// `StructureRotor.result`. Either rotor is dropped when the document has
    /// none of its kind.
    public override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        var rotors = super.accessibilityCustomRotors()
        let items = BlockRecyclerAccessibility.rotorItems(for: document.blocks)
        headingRotorDelegate.items = items.headings
        blockRotorDelegate.items = items.blocks
        if !items.headings.isEmpty {
            rotors.append(NSAccessibilityCustomRotor(
                rotorType: .heading, itemSearchDelegate: headingRotorDelegate))
        }
        if !items.blocks.isEmpty {
            rotors.append(NSAccessibilityCustomRotor(
                label: "Blocks", itemSearchDelegate: blockRotorDelegate))
        }
        return rotors
    }

    // MARK: - Test hooks (internal; consumed by BlockRecyclerViewTests)

    var numberOfRowsForTest: Int { tableView.numberOfRows }
    /// The table-level Headings rotor items over the current document, in order.
    var headingRotorItemsForTest: [StructureRotor.Item] {
        BlockRecyclerAccessibility.rotorItems(for: document.blocks).headings
    }
    /// The table-level Blocks rotor items over the current document, in order.
    var blockRotorItemsForTest: [StructureRotor.Item] {
        BlockRecyclerAccessibility.rotorItems(for: document.blocks).blocks
    }
    /// Step the Headings rotor exactly as VoiceOver would, through the shared
    /// `StructureRotor.result` navigator.
    func headingRotorStepForTest(
        from currentLocation: Int?, direction: StructureRotor.Direction, filter: String = ""
    ) -> StructureRotor.Item? {
        StructureRotor.result(
            items: headingRotorItemsForTest,
            currentLocation: currentLocation, direction: direction, filter: filter)
    }
    var scrollInsetsForTest: NSEdgeInsets { scrollView.contentInsets }
    /// The renderer the recycler renders content through — exposed so tests can
    /// assert config parity (baseURL etc.) with the model's renderer.
    var configuredRendererForTest: AttributedRenderer { renderer }
    /// True when the container exposes a horizontal scroller (no-wrap mode).
    var hasHorizontalScrollerForTest: Bool { scrollView.hasHorizontalScroller }
    /// Count of executed `scroll(to:)` calls — proves a repeat outline click on
    /// the SAME heading (via a `scrollGeneration` bump) re-fires the scroll.
    var scrollToCallCountForTest = 0
    func rowHeightForTest(_ row: Int) -> CGFloat { rowHeight(atRow: row) }
    /// Map a point given in the table's (flipped) coordinate space to the
    /// window's, so a test can address a row by `y` deterministically and feed
    /// the result straight into `blockAndPoint(forWindowPoint:)` — an exact
    /// round trip through the same scroll/flip transform a real click takes.
    func windowPointForTableY(_ tablePoint: CGPoint) -> CGPoint {
        tableView.convert(tablePoint, to: nil)
    }
    /// The table-space rect of `row` (flipped). Lets a test address a row's
    /// on-screen center after a scroll, so a real dispatched click over it
    /// proves the scroll offset is honoured by the window→table conversion.
    func rowRectForTest(_ row: Int) -> CGRect { tableView.rect(ofRow: row) }
    /// Force the table to instantiate + configure the view for `row` (drives
    /// `viewFor`, so the cell registers its async decode) without waiting on a
    /// display pass. Returns the configured cell.
    @discardableResult
    func forceLoadRowForTest(_ row: Int) -> BlockRenderCell? {
        tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? BlockRenderCell
    }
    /// Fires after a settled height is recorded (hazard-B acceptance: proves the
    /// cell won the decode registration and the settle → noteHeightOfRows wiring
    /// ran).
    var didRecordSettledHeightForTest: ((BlockID) -> Void)?
    /// The row currently promoted to an editable island, or nil (Task 5).
    var editingRowForTest: Int? { _editingBlockID.flatMap { rowByBlockID[$0] } }
    /// True when `row`'s realized view is a `BlockEditorCell` (the island).
    /// Forces the view so the assertion reflects what `viewFor` actually vends.
    func isEditingRow(_ row: Int) -> Bool {
        guard row >= 0, row < tableView.numberOfRows else { return false }
        return tableView.view(atColumn: 0, row: row, makeIfNecessary: true) is BlockEditorCell
    }

    // MARK: - Churn instrumentation (Phase 3 falsifiers; test-only, behavior-free)
    //
    // The "jiggle" bug class — a clicked row animating grow/shrink and never
    // settling into an editable island — is an OSCILLATION, not a wrong final
    // state. Every prior test asserted a final state at a moment of our
    // choosing, so all three shipped-broken states were green. These counters
    // make the churn ITSELF observable: how many times `viewFor` re-vends a row
    // and how many times the table re-asks for its height across ONE click.
    //
    // Strictly additive: only recorded into, never read by production code, and
    // the recording is two dictionary writes on paths that already do table
    // work (no measurable cost, no behavior change).

    /// `viewFor` vends per row across the observation window, split by leaf kind.
    /// One click must produce EXACTLY ONE editor-cell vend for the clicked row;
    /// more means the row is being rebuilt in a loop.
    private(set) var editorCellVendsByRowForTest: [Int: Int] = [:]
    /// Read-only `BlockRenderCell` vends per row (a clicked row that keeps
    /// re-vending a READ cell is a swap that keeps reverting).
    private(set) var renderCellVendsByRowForTest: [Int: Int] = [:]
    /// Every height the table asked for, per row, in query order. The COUNT is
    /// the churn signal; the VALUES localize a grow/shrink oscillation (two
    /// alternating heights) versus a monotone settle.
    private(set) var heightQueriesByRowForTest: [Int: [CGFloat]] = [:]

    /// The `NSAnimationContext.duration` in force for every table op that can
    /// change a row's height (`withoutAnimation`). Spec §4 steps 3/6 require the
    /// read-height↔island-height flip to be applied with NO animation — a bare
    /// `noteHeightOfRows` inherits whatever duration is current (0.25 s by
    /// default), which is the animated grow/shrink the user sees as the jiggle.
    /// Every entry here must be 0.
    private(set) var animationDurationsForTest: [TimeInterval] = []

    /// Zero the churn counters, so a test observes exactly one interaction
    /// (call immediately before dispatching the click).
    func resetChurnCountersForTest() {
        editorCellVendsByRowForTest.removeAll()
        renderCellVendsByRowForTest.removeAll()
        heightQueriesByRowForTest.removeAll()
        animationDurationsForTest.removeAll()
    }

    /// The table's selected row (-1 when nothing is selected). Half of the
    /// OWNERSHIP evidence: a promoting click that reached `super.mouseDown` would
    /// have let `NSTableView` select the row.
    var selectedRowForTest: Int { tableView.selectedRow }

    /// How many times the table has actually called `super.mouseDown` — the DIRECT
    /// measurement of the "never call super" rule (the other half of the ownership
    /// evidence, independent of whatever `NSTableView` chooses to do with a click).
    var tableSuperMouseDownCountForTest: Int { tableView.superMouseDownCountForTest }

    /// Whether the table itself would accept first responder. `false` (via
    /// `refusesFirstResponder`) is the defense-in-depth against the live trace's
    /// `NSWindow._realMakeFirstResponder` reclaiming focus for the table.
    var tableAcceptsFirstResponderForTest: Bool { tableView.acceptsFirstResponder }

    /// The table's `validateProposedFirstResponder` verdict for a responder — the
    /// override that lets the ISLAND (not the table) own focus inside a cell.
    func tableValidatesFirstResponderForTest(_ responder: NSResponder) -> Bool {
        tableView.validateProposedFirstResponder(responder, for: nil)
    }

    /// The clip view's scroll origin — the recycler's analogue of the
    /// projection reader's viewport anchor. The CLAUDE.md viewport invariant
    /// says a click must not move the content under the caret; this is half of
    /// the evidence (the other half is the row's window-space position).
    var scrollOriginForTest: CGPoint { scrollView.contentView.bounds.origin }

    /// The hosted table, so a test can put it in the DIRTY state the app is
    /// permanently in under `NSHostingView` (pending layout ⇒ a
    /// `reloadData(forRowIndexes:)` coalesces instead of running synchronously).
    var tableViewForTest: NSTableView { tableView }

    /// Back-reference to the `IslandController` driving this recycler, set by the
    /// controller's `init`. Weak and never read by production code — it exists so
    /// a test that stands the stack up through a REAL `NSHostingView` (where
    /// SwiftUI, not the test, owns the Coordinator that owns the controller) can
    /// still reach `activeIsland`.
    weak var islandControllerForTest: IslandController?
}

extension BlockRecyclerView: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        document.blocks.count
    }
}

extension BlockRecyclerView: NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let height = rowHeight(atRow: row)
        // Churn instrumentation (test-only, see `heightQueriesByRowForTest`).
        heightQueriesByRowForTest[row, default: []].append(height)
        return height
    }

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard row >= 0, row < document.blocks.count else { return nil }
        let block = document.blocks[row]
        // Phase 2, Task 5: the ONE editing row vends an editable island cell;
        // every other row vends the read-only render cell.
        if block.id == _editingBlockID {
            // Churn instrumentation (test-only, see `editorCellVendsByRowForTest`).
            editorCellVendsByRowForTest[row, default: 0] += 1
            return editorView(for: block)
        }
        // Churn instrumentation (test-only, see `renderCellVendsByRowForTest`).
        renderCellVendsByRowForTest[row, default: 0] += 1
        let cell: BlockRenderCell
        if let reused = tableView.makeView(
            withIdentifier: Self.cellIdentifier, owner: self) as? BlockRenderCell {
            cell = reused
        } else {
            cell = BlockRenderCell()
            cell.identifier = Self.cellIdentifier
            liveCells.add(cell)
        }
        // The settle callback reports the block that settled (the cell may have
        // recycled onto another block by then); route it to that block's row.
        cell.onContentSettled = { [weak self] settledBlockID in
            self?.contentDidSettle(for: settledBlockID)
        }
        // Cells render through the REAL renderer, so THEY arm the async decode
        // (hazard B): the height path used `.textReference` and never touched
        // the store, so this is the first caller.
        cell.configure(
            block: block, document: document,
            renderer: renderer, theme: theme, width: contentWidth)
        return cell
    }

    /// Vend (dequeue/create) the editable island cell for `block`, seeded with
    /// its RAW source. Wires `onTextDidChange` back to the recycler so the
    /// editing row's height tracks the live text layout.
    private func editorView(for block: Block) -> BlockEditorCell {
        let cell: BlockEditorCell
        if let reused = tableView.makeView(
            withIdentifier: Self.blockEditorCellIdentifier, owner: self) as? BlockEditorCell {
            cell = reused
        } else {
            cell = BlockEditorCell()
            cell.identifier = Self.blockEditorCellIdentifier
        }
        // Phase 3: the island renders its raw source STYLED — per-line type ramp
        // + faded, caret-scoped delimiters — through the renderer's own
        // derivation, so the active and inactive projections of a block agree on
        // typography and (within a documented epsilon) on height. Installed
        // BEFORE `configure` so the first layout the row is measured at is the
        // styled one.
        cell.sourceStyler = { [renderer] source, caret in
            renderer.styledIslandSource(source, caretUTF16: caret)
        }
        let slice = document.source.substring(in: block.range) ?? ""
        cell.configure(slice: slice, blockID: block.id, width: contentWidth)
        cell.onTextDidChange = { [weak self, weak cell] in
            guard let self, let cell else { return }
            self.editingCellDidChangeText(cell)
        }
        liveEditorCell = cell
        return cell
    }
}

/// `NSTableView` subclass whose only job is to forward a `mouseDown` to the
/// recycler. The click has to be caught HERE — on the view AppKit hit-tests and
/// dispatches to — not on the ancestor `BlockRecyclerView`: `NSTableView`
/// consumes a row click in its own `mouseDown` (row tracking) and never bubbles
/// it up the view hierarchy, so an ancestor override is dead for real clicks.
///
/// **Phase 3 (click-seam re-shape).** The handler now returns whether it HANDLED
/// the click by promoting the row and forwarding the event to the new island's
/// text view. When it did, `super.mouseDown` is NOT called — the table never
/// processes the click, so it cannot reclaim first responder inside its modal
/// tracking loop (the live-trace failure), cannot select the row, and cannot
/// start a row drag. See `BlockRecyclerView.handleTableMouseDown` for the full
/// forward-vs-super decision tree.
@MainActor
private final class ClickReportingTableView: NSTableView {
    /// Returns `true` when the click was fully handled (promote + forward), in
    /// which case `super.mouseDown` must NOT run.
    var onMouseDown: ((NSEvent) -> Bool)?

    /// Test-only: how many times this view has actually deferred to
    /// `super.mouseDown` (see `BlockRecyclerView.tableSuperMouseDownCountForTest`).
    private(set) var superMouseDownCountForTest = 0

    override func mouseDown(with event: NSEvent) {
        ilog("click.mouseDown.pre", {
            let p = self.convert(event.locationInWindow, from: nil)
            let fr = self.window?.firstResponder
            return "row=\(self.row(at: p)) point=\(NSStringFromPoint(p)) firstResponder=\(fr.map { String(describing: type(of: $0)) } ?? "nil")"
        }())
        let handled = onMouseDown?(event) ?? false
        if !handled {
            ilog("click.mouseDown.super")
            superMouseDownCountForTest += 1
            super.mouseDown(with: event)
        }
        ilog("click.mouseDown.post", {
            let fr = self.window?.firstResponder
            return "handled=\(handled) selectedRow=\(self.selectedRow) firstResponder=\(fr.map { String(describing: type(of: $0)) } ?? "nil")"
        }())
    }

    /// `NSTableView` refuses first responder for most of its subviews so a click
    /// on a cell focuses the TABLE, not the cell. That is exactly backwards here:
    /// the island IS the editable surface. Approve it (and anything inside a
    /// `BlockEditorCell`) explicitly — defense in depth for any path that still
    /// reaches the table, since the forward path never calls `super.mouseDown`.
    override func validateProposedFirstResponder(
        _ responder: NSResponder, for event: NSEvent?
    ) -> Bool {
        var node = responder as? NSView
        while let current = node {
            if current is IslandTextView || current is BlockEditorCell { return true }
            node = current.superview
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}
#endif
