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
    private let tableView = NSTableView()

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

    /// Report the top-most visible block (drives the outline sync).
    public var onTopBlockChange: ((BlockID) -> Void)?
    private var lastReportedTop: BlockID?

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

    public override func mouseDown(with event: NSEvent) {
        // Report the click, but do NOT consume it or change selection — the
        // table keeps `selectionHighlightStyle = .none` and Task 5 is what
        // decides to activate an island. Fall through to super so default
        // hit-testing (links inside cells, etc.) is unaffected.
        if let hit = blockAndPoint(forWindowPoint: event.locationInWindow) {
            onBlockClicked?(hit.0, hit.1)
        }
        super.mouseDown(with: event)
    }

    // MARK: - Height

    private func rowHeight(atRow row: Int) -> CGFloat {
        guard row >= 0, row < document.blocks.count else { return 1 }
        let block = document.blocks[row]
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
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
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
}

extension BlockRecyclerView: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        document.blocks.count
    }
}

extension BlockRecyclerView: NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rowHeight(atRow: row)
    }

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard row >= 0, row < document.blocks.count else { return nil }
        let cell: BlockRenderCell
        if let reused = tableView.makeView(
            withIdentifier: Self.cellIdentifier, owner: self) as? BlockRenderCell {
            cell = reused
        } else {
            cell = BlockRenderCell()
            cell.identifier = Self.cellIdentifier
            liveCells.add(cell)
        }
        let block = document.blocks[row]
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
}
#endif
