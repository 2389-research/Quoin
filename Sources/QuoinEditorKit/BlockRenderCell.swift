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

        let fragment = renderer.renderReadFragment(block, document: document).fragment
        // NSTextContentStorage projects an NSTextStorage; replacing it wholesale
        // is what makes reconfigure cheap and total (no residual runs).
        contentStorage.textStorage = NSTextStorage(attributedString: fragment)

        textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: contentStorage.documentRange)

        // Single source of truth for height — do NOT derive it from the local
        // layout pass above.
        measuredHeight = renderer.measuredHeight(of: block, in: document, width: width)

        setFrameSize(NSSize(width: width, height: measuredHeight))
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
        layoutManager.enumerateTextLayoutFragments(
            from: contentStorage.documentRange.location
        ) { fragment in
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
            return true
        }
    }

    /// The decoration boxes for this cell's currently-configured block, in
    /// cell-local coords. `leadingInset` is 0 until row padding lands (Task 4).
    private func decorationBoxes() -> [DecorationDraw.Box] {
        DecorationDraw.boxes(in: layoutManager,
                             contentStorage: contentStorage,
                             contentWidth: textContainer.size.width,
                             leadingInset: 0)
    }

    /// Test hook (DecorationParityTests): the decoration geometry the cell
    /// would draw for its configured block, without a draw pass.
    func decorationBoxesForTest() -> [DecorationDraw.Box] {
        decorationBoxes()
    }
}
#endif
