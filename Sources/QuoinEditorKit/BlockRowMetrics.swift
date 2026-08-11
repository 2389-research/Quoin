#if canImport(AppKit)
import AppKit
import QuoinCore
import QuoinRender

/// Phase 1, Task 4: the ROW-HEIGHT CONTRACT for the block recycler (Task 6).
///
/// `AttributedRenderer.measuredHeight(of:in:width:)` is the single source of
/// truth for a block's TEXT height — text-layout fragments only, no chrome and
/// no inter-block air (spec §13b #1). A recycled cell, however, draws MORE than
/// the text: Task 3 reserves `2 * DecorationDraw.verticalBleed` of vertical
/// padding so decoration boxes (code canvas, callout, quote rule, …) can bleed
/// past the glyphs, and the monolithic reader put an inter-block GAP between
/// every pair of blocks via `AttributedRenderer.separator(after:before:)`.
///
/// `rowHeight` reproduces the monolith's total document height by stacking, per
/// block:
///
///     rowHeight = measuredHeight            // block text (SSOT)
///               + topBleed + bottomBleed    // Task 3 decoration padding
///               + separatorContribution     // the inter-block gap this block
///                                           // contributes (kind-pair dependent)
///
/// Decoration bleed. Task 3 reserves `verticalBleed` above AND below a cell's
/// text so decoration boxes can bleed past the glyphs. The DOCUMENT's two outer
/// edges — the top of the first row and the bottom of the last row — are the
/// exception: their bleed is supplied by the scroll view's content insets, the
/// same outer margins the monolithic reader has (its glyphs don't touch y = 0
/// either). Counting them in row heights would make the recycler's content a
/// constant `2 * verticalBleed` TALLER than the projection — a fixed offset that
/// never appears at an interior seam. So the first row omits its top bleed and
/// the last row omits its bottom bleed; every interior seam still carries the
/// full `2 * verticalBleed`.
///
/// Separator. Two bare Task-3 cells stacked abut with only `2 * verticalBleed`
/// (10pt) of air between their glyphs, but the monolith's inter-block gap is
/// larger (12pt for prose = `theme.paragraphSpacing`; more when a card block is
/// involved). `separatorContribution` is exactly that shortfall, DERIVED — not
/// hardcoded — from the renderer's own separator string measured in a neutral
/// two-paragraph context, so a change to `blockSeparator` flows through
/// automatically. The last block contributes no separator (no following
/// neighbour), exactly as the monolith omits the trailing separator.
@MainActor
public enum BlockRowMetrics {
    /// Deterministic row height a recycled cell will draw at for `block` when it
    /// sits at `index` in `document`, laid out at `width`.
    ///
    /// Provisional heights (Phase 1, Task 5). For a block whose content decodes
    /// asynchronously (an image/diagram/math still tagged
    /// `QuoinAttribute.pendingContent`), `measuredHeight` here is the block's
    /// PLACEHOLDER height — deterministic, but not yet the final content height.
    /// This value is correct to lay the row out RIGHT NOW; it MUST NOT be cached
    /// as the block's final height. The owning `BlockRenderCell` surfaces
    /// `hasPendingContent` and fires `onContentSettled(blockID)` when the decode
    /// lands; the recycler (Task 6) invalidates that row and re-queries
    /// `rowHeight`, which then returns the settled content height. Caching a
    /// pending height as final would freeze a placeholder-sized row under
    /// decoded content.
    public static func rowHeight(
        for block: Block, at index: Int, in document: QuoinDocument,
        renderer: AttributedRenderer, theme: Theme, width: CGFloat
    ) -> CGFloat {
        let isFirst = index == 0
        let isLast = index == document.blocks.count - 1
        let text = renderer.measuredHeight(of: block, in: document, width: width)
        // Outer document edges get their bleed from the container's content
        // insets, not the row (see the type doc); interior edges reserve it.
        let topBleed = isFirst ? 0 : DecorationDraw.verticalBleed
        let bottomBleed = isLast ? 0 : DecorationDraw.verticalBleed
        let separator = isLast ? 0 : separatorContribution(
            after: block.kind, before: document.blocks[index + 1].kind,
            renderer: renderer, width: width)
        return text + topBleed + bottomBleed + separator
    }

    /// Memo key for `separatorContribution`. The seam gap is a pure function of
    /// the separator's CONTENT and the layout width: the measurement below feeds
    /// the separator between two fixed anchor paragraphs, so two seams that emit
    /// the same separator string measure identically. We key on the separator's
    /// content (derived from the renderer, never re-classified here — so this can
    /// never diverge from the renderer's card/prose rule) rather than the raw
    /// `(after, before)` kind-pair: the pair over-specialises (two prose blocks
    /// with different inlines are DIFFERENT kinds but the SAME "\n" separator), so
    /// keying on kinds would miss on every prose seam and never actually cache.
    private struct SeparatorKey: Hashable {
        let separator: String
        let width: CGFloat
    }

    /// Cache of measured separator contributions, keyed by `(separatorContent,
    /// width)`. `NSTableView` queries `heightOfRow` for every row eagerly and on
    /// every reload, so without this each query pays three TextKit layouts (two
    /// anchor measures + one paired measure). Main-actor isolated (the enum is
    /// `@MainActor`), so no synchronization is needed.
    private static var separatorCache: [SeparatorKey: CGFloat] = [:]

    /// Test hook: number of times `separatorContribution` actually measured
    /// (a cache MISS). A repeat call with the same key must not increment it.
    static var separatorComputeCountForTest = 0

    /// Test hook: drop the memo so a test starts from a known-empty cache.
    static func resetSeparatorCacheForTest() {
        separatorCache.removeAll()
        separatorComputeCountForTest = 0
    }

    /// The EXTRA inter-block air the monolith placed at an `after`→`before` seam
    /// beyond the `2 * verticalBleed` two abutting cells already provide.
    /// Measured — not guessed — as the height the renderer's own separator adds
    /// between two neutral body paragraphs, minus the `2 * verticalBleed` the
    /// neighbouring cells contribute. Clamped at zero (a seam never subtracts).
    ///
    /// Memoized (see `SeparatorKey`): the value is width- and separator-content
    /// deterministic, so the eager per-row `heightOfRow` queries share one
    /// measurement instead of re-laying-out three paragraphs per row. The cheap
    /// part (building the separator string) still runs per call; only the three
    /// TextKit layouts are cached.
    static func separatorContribution(
        after: BlockKind, before: BlockKind,
        renderer: AttributedRenderer, width: CGFloat
    ) -> CGFloat {
        let separator = renderer.separator(after: after, before: before, revealedSlice: nil)
        let key = SeparatorKey(separator: separator.string, width: width)
        if let cached = separatorCache[key] { return cached }
        separatorComputeCountForTest += 1
        let contribution = measureSeparatorContribution(separator, renderer: renderer, width: width)
        separatorCache[key] = contribution
        return contribution
    }

    /// The uncached measurement behind `separatorContribution` (extracted so the
    /// memo wrapper stays a thin cache lookup).
    private static func measureSeparatorContribution(
        _ separator: NSAttributedString,
        renderer: AttributedRenderer, width: CGFloat
    ) -> CGFloat {
        // Isolate the separator's true in-context contribution with the exact
        // pairwise measure the render loop realises: an authentic body paragraph
        // (rendered by the SAME renderer, so its terminating paragraph metrics
        // match a real block's) on either side of the separator, minus each
        // paragraph measured alone. A bare separator measured by itself lays out
        // as a full empty line — it has no following block to merge into, which
        // is not how it behaves in the document — so it cannot be measured in
        // isolation.
        let anchorDoc = MarkdownConverter.parse("x")
        guard let anchorBlock = anchorDoc.blocks.first else { return 0 }
        let anchor = renderer.renderReadFragment(anchorBlock, document: anchorDoc).fragment
        let paired = NSMutableAttributedString(attributedString: anchor)
        paired.append(separator)
        paired.append(anchor)
        let seamGap = measure(paired, width: width) - 2 * measure(anchor, width: width)
        return max(0, seamGap - 2 * DecorationDraw.verticalBleed)
    }

    /// TextKit-2 laid-out height of an attributed fragment at `width` — the same
    /// measure pattern the metric SSOT uses (`RevealFidelityTests.measureHeight`
    /// / `AttributedRenderer.measuredHeight`).
    private static func measure(_ attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributed)
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = storage
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = NSTextContainer(
            size: NSSize(width: width, height: .greatestFiniteMagnitude))
        layoutManager.ensureLayout(for: contentStorage.documentRange)
        var total: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(from: contentStorage.documentRange.location) { fragment in
            total += fragment.layoutFragmentFrame.height
            return true
        }
        return total
    }
}
#endif
