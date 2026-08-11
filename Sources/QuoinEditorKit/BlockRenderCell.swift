#if canImport(AppKit)
import AppKit
import QuoinCore
import QuoinRender

/// Phase 1, Task 1: a read-only view that renders ONE block's KEEP
/// projection in a cell-local TextKit-2 stack, sized to a configured width.
///
/// This is the leaf the block recycler (later tasks) reconfigures across many
/// rows, so `configure` is idempotent and re-targetable: each call re-points
/// the cell at a new block/width and refreshes `blockID`. Decorations (the
/// chrome `QuoinTextView` draws in `drawBackground(in:)`) and row padding are
/// out of scope here — this task is text render + metric-matched height only.
///
/// Height is NOT computed a second way: `fittingHeightForConfiguredWidth`
/// forwards to `AttributedRenderer.measuredHeight(of:in:width:)`, the single
/// source of truth the metric contract is pinned to. The cell's own layout
/// stack exists only to DRAW the same fragment; it never becomes an
/// alternative height authority.
@MainActor
public final class BlockRenderCell: NSView {
    /// Which block this cell currently shows. `nil` before the first
    /// `configure`. Used by the recycler as recycling identity.
    public private(set) var blockID: BlockID?

    /// The row height for the configured block+width, taken verbatim from the
    /// renderer's metric (the cell-sizing contract). Zero before configure.
    public var fittingHeightForConfiguredWidth: CGFloat { measuredHeight }

    /// Phase 1, Task 5: true when the last `configure` produced a fragment that
    /// is still waiting on async content (an image/diagram/math placeholder
    /// tagged `QuoinAttribute.pendingContent`). While this is true the cell's
    /// `fittingHeightForConfiguredWidth` is PROVISIONAL — it is the
    /// deterministic placeholder height, not the final content height. The
    /// recycler (Task 6) must NOT cache a pending row's height as final; it
    /// re-queries height when `onContentSettled` fires. `false` before the first
    /// `configure`.
    public private(set) var hasPendingContent: Bool = false

    /// Phase 1, Task 5: fired once when a previously-pending cell's content
    /// finishes decoding and becomes available, carrying the `BlockID` that
    /// settled (captured at `configure` time). This is wired to the SAME
    /// readiness signal the monolithic reader uses —
    /// `AttributedRenderer.onContentReady`, which `AsyncImageStore` invokes off
    /// its shared, path-keyed decode (`image(at:maxDimension:onReady:)`); the
    /// cell never starts a parallel decode. Delivered on the main actor.
    ///
    /// Because the cell recycles, the decode it armed for one block can complete
    /// after the cell has been reconfigured for another. The callback therefore
    /// reports the block that settled, not "this cell's current block": Task 6
    /// treats it as "the row for `BlockID` needs its height re-queried," which is
    /// correct whether or not this cell still displays that block.
    public var onContentSettled: ((BlockID) -> Void)?

    // Cell-local TextKit-2 stack used purely to draw the block fragment.
    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(
        size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

    private var measuredHeight: CGFloat = 0

    // The theme this cell was last configured with. Decoration colors come off
    // the BlockDecoration payloads, not this value; it is held for API parity
    // with DecorationDraw.draw and future theme-dependent chrome.
    private var theme = Theme()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Spanning chrome (the code/callout/diagram bleed and the quote-rule
        // gutter bar) deliberately draws OUTSIDE the raw text box. The cell
        // reserves room for it (see `configure`) AND must not clip: a table-cell
        // clips to bounds by default, which would guillotine the bleed.
        clipsToBounds = false
        layer?.masksToBounds = false
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = textContainer
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // AppKit's default is bottom-left origin; a top-down text stack reads more
    // naturally flipped, and the recycler places rows top-down.
    public override var isFlipped: Bool { true }

    /// Point the cell at `block` from `document`, laying its KEEP fragment out
    /// at content `width`. Reusable: safe to call repeatedly on one instance to
    /// recycle it across rows.
    public func configure(
        block: Block,
        document: QuoinDocument,
        renderer: AttributedRenderer,
        theme: Theme,
        width: CGFloat
    ) {
        blockID = block.id
        self.theme = theme

        // Observe the SAME async readiness signal the monolith uses without
        // starting a parallel decode: `AttributedRenderer` is a value type whose
        // `onContentReady` is what `AsyncImageStore` fires off its shared,
        // path-keyed decode. We render this cell's block through a copy of the
        // passed renderer that reuses ITS configuration (theme/baseURL/image
        // resolution → identical fragment + height) but points `onContentReady`
        // at THIS cell, so when a pending image settles the store calls us back.
        // The copy must be the render of record: `AsyncImageStore` keeps only the
        // first caller's `onReady` per key (a later render of an already-pending
        // key returns nil without re-registering), so drawing through this copy
        // is what wires the settle callback to the real decode.
        let settledBlockID = block.id
        let observingRenderer = AttributedRenderer(
            theme: renderer.theme,
            baseURL: renderer.baseURL,
            loadsRemoteImages: renderer.loadsRemoteImages,
            imageResolution: renderer.imageResolution,
            onContentReady: { [weak self] in
                // Fires off-main from the shared decode; hop to the main actor to
                // touch the cell and deliver the row-invalidation signal.
                Task { @MainActor in self?.onContentSettled?(settledBlockID) }
            }
        )

        let read = observingRenderer.renderReadFragment(block, document: document)
        hasPendingContent = read.hasPendingContent
        // NSTextContentStorage projects an NSTextStorage; replacing it wholesale
        // is what makes reconfigure cheap and total (no residual runs).
        contentStorage.textStorage = NSTextStorage(attributedString: read.fragment)

        // The text is laid out at the CONTENT-COLUMN width; the cell frame is
        // wider/taller by the reserved gutter + vertical bleed so the spanning
        // chrome fits inside bounds (Task 4's row-height contract folds in the
        // same DecorationDraw constants).
        textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: contentStorage.documentRange)

        // Single source of truth for height — do NOT derive it from the local
        // layout pass above. For a pending block this is the deterministic
        // PLACEHOLDER height; it is provisional until `onContentSettled` fires
        // and the recycler re-queries (see `hasPendingContent`).
        measuredHeight = observingRenderer.measuredHeight(of: block, in: document, width: width)

        setFrameSize(NSSize(
            width: width + 2 * DecorationDraw.leftGutter,
            height: measuredHeight + 2 * DecorationDraw.verticalBleed))
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Block-level chrome (code canvas, diagram frame, chip, table rules)
        // draws BEHIND the text, exactly as QuoinTextView paints it in
        // drawBackground(in:) — per-glyph background attributes render as ugly
        // per-line strips, so decorations are drawn ink from fragment geometry.
        DecorationDraw.draw(decorationBoxes(), in: context, theme: theme)
        // Glyphs draw shifted into the gutter-reserved, top-padded content box
        // — the SAME (leftGutter, verticalBleed) offset the decoration boxes
        // already bake in, so chrome and text stay aligned.
        context.saveGState()
        context.translateBy(x: DecorationDraw.leftGutter, y: DecorationDraw.verticalBleed)
        layoutManager.enumerateTextLayoutFragments(
            from: contentStorage.documentRange.location
        ) { fragment in
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
            return true
        }
        context.restoreGState()
    }

    /// The decoration boxes for this cell's currently-configured block, in
    /// cell-local coords, shifted by the reserved gutter + vertical bleed so the
    /// spanning chrome lands inside the (non-clipping) cell bounds.
    private func decorationBoxes() -> [DecorationDraw.Box] {
        DecorationDraw.boxes(in: layoutManager,
                             contentStorage: contentStorage,
                             // Total drawable width: content column + left gutter,
                             // so a full-width box spans [leftGutter, column edge].
                             contentWidth: textContainer.size.width + DecorationDraw.leftGutter,
                             leadingInset: DecorationDraw.leftGutter,
                             topInset: DecorationDraw.verticalBleed)
    }

    /// Test hook (DecorationBleedTests): false when the cell will NOT clip the
    /// negative-inset decoration bleed / gutter bar to its bounds.
    var clipsDecorationForTest: Bool { clipsToBounds }

    /// Test hook (DecorationParityTests): the decoration geometry the cell
    /// would draw for its configured block, without a draw pass.
    func decorationBoxesForTest() -> [DecorationDraw.Box] {
        decorationBoxes()
    }
}
#endif
