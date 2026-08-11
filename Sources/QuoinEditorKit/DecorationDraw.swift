#if canImport(AppKit)
import AppKit
import QuoinCore
import QuoinRender

/// Phase 1, Task 2: the per-block-local decoration chrome a `BlockRenderCell`
/// draws behind its text, ported verbatim (geometry + CoreGraphics) from the
/// projection reader's `QuoinTextView.measureVisibleRuns()` / `draw(_:)`
/// (`Sources/QuoinRender/AppKit/QuoinTextView.swift`). The renderer tags a
/// block's character range with `QuoinAttribute.blockDecoration` carrying a
/// `BlockDecoration`; here we scan those runs in the cell's own TextKit-2
/// stack, union each run's fragment frames into a box, and draw it.
///
/// Draw-only, read-only: no layout mutation, no editing. This task ports ONLY
/// the PER-BLOCK-LOCAL kinds — `.codeCanvas`, `.diagramFrame`, `.chip`,
/// `.tableRules`. The SPANNING/bleeding kinds (`.callout`, `.quoteRule`, the
/// negative-inset bleed) are Task 3, and `.editingFrame` is editor-only; all
/// are measured but drawn as no-ops here.
///
/// Colors and line widths come off the `BlockDecoration.Kind` payloads
/// (`fill:` / `color:` / `width:`), NOT from `Theme` globals — the renderer
/// already resolved them against the theme when it stamped the run (mirrors
/// `QuoinTextView.draw(_:)`). The `Theme` parameter on `draw` is kept for API
/// stability / future kinds.
@MainActor
public enum DecorationDraw {

    // MARK: Padding / gutter contract (SINGLE SOURCE — consumed by Task 4)
    //
    // The spanning/bleeding chrome deliberately draws OUTSIDE a block's raw
    // fragment box: the code canvas / callout / diagram frame bleed VERTICALLY
    // into the inter-block gap (negative dy insets), and the quote rule sits in
    // a LEFT GUTTER to the left of the text column. An NSTableView-style cell
    // clips to its bounds, so the cell must reserve room for both. These are the
    // named constants Task 4's row-height contract folds into the row metric —
    // do not inline the numbers elsewhere; read them from here.

    /// Symmetric vertical padding reserved above and below the text so the
    /// negative-inset bleed fits inside the cell. Sized to the LARGEST bleed
    /// (the callout's `dy:-5`); the code canvas (`-2`) and diagram frame (`-4`)
    /// fit within it. Task 4 adds `2 * verticalBleed` to the row height.
    public static let verticalBleed: CGFloat = 5

    /// Left gutter reserved for the quote rule, which draws at `box.minX - 14`
    /// (verbatim from `QuoinTextView.draw(_:)`). The text column is shifted
    /// right by this much so the 3pt bar lands at the cell's leading edge
    /// instead of being clipped off the left. Also used as the symmetric
    /// horizontal pad so a full-width box's border clears the trailing edge.
    public static let leftGutter: CGFloat = 14

    /// One decoration ready to draw, in cell-local (fragment-frame) coords.
    /// - `rect`: the union of the run's fragment frames, with full-width kinds
    ///   reset to the content column. For `.chip` the width/height clamp is
    ///   folded in here (the `Box` carries no `textWidth`, so the chip's
    ///   `min(textWidth + 16, box.width)` sizing is resolved at measure time
    ///   and `rect` is the final chip rect).
    /// - `rowFrames`: the per-fragment frames, in document order — `.tableRules`
    ///   draws one rule per row from these.
    public struct Box {
        public let kind: BlockDecoration.Kind
        public let rect: CGRect
        public let rowFrames: [CGRect]

        public init(kind: BlockDecoration.Kind, rect: CGRect, rowFrames: [CGRect]) {
            self.kind = kind
            self.rect = rect
            self.rowFrames = rowFrames
        }
    }

    /// Scan the cell's laid-out storage for `blockDecoration` runs and return
    /// the boxes to draw. Ported from `measureVisibleRuns()` (the viewport
    /// culling is dropped — a cell holds a single block, always "visible").
    ///
    /// - Parameters:
    ///   - contentWidth: the cell's TOTAL drawable width including the gutter
    ///     (full-width chrome spans from `leadingInset` to this edge, regardless
    ///     of the laid-out line widths).
    ///   - leadingInset: the cell's base left content inset — the reserved
    ///     `leftGutter` — added to each decoration's own nesting `leadingInset`
    ///     for the full-width reset AND used to shift every fragment frame right
    ///     into the text column. The quote rule draws back at `minX - leftGutter`,
    ///     i.e. in that reserved gutter.
    ///   - topInset: the cell's reserved top padding — the `verticalBleed` — that
    ///     shifts every fragment down so the negative-inset bleed lands at or
    ///     below the cell's top edge instead of clipping negative.
    ///
    /// The returned `Box.rect` is the FINAL drawn geometry for every kind: the
    /// negative-inset bleed (code canvas `-2`, callout `-5`, diagram `-4`), the
    /// chip clamp, and the quote bar are all folded in here so `draw` paints
    /// `box.rect` verbatim and `decorationBoxesForTest()` reports true geometry.
    public static func boxes(in layoutManager: NSTextLayoutManager,
                             contentStorage: NSTextContentStorage,
                             contentWidth: CGFloat,
                             leadingInset: CGFloat,
                             topInset: CGFloat = 0) -> [Box] {
        guard let storage = contentStorage.textStorage, storage.length > 0 else { return [] }

        var result: [Box] = []
        storage.enumerateAttribute(
            QuoinAttribute.blockDecoration,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let decoration = value as? BlockDecoration,
                  let textRange = textRange(range, in: contentStorage) else { return }

            var frames: [CGRect] = []
            var textWidth: CGFloat = 0
            layoutManager.enumerateTextLayoutFragments(
                from: textRange.location,
                options: [.ensuresLayout]
            ) { fragment in
                if fragment.rangeInElement.location.compare(textRange.endLocation) != .orderedAscending {
                    return false
                }
                // Shift each fragment into the gutter-reserved, top-padded cell
                // coordinate space; the text draw is translated by the same
                // (leadingInset, topInset) so chrome and glyphs stay aligned.
                frames.append(fragment.layoutFragmentFrame.offsetBy(dx: leadingInset, dy: topInset))
                for line in fragment.textLineFragments {
                    textWidth = max(textWidth, line.typographicBounds.width)
                }
                return true
            }
            guard var union = frames.first else { return }
            for frame in frames.dropFirst() { union = union.union(frame) }

            // Full-width chrome spans the text column regardless of how wide
            // the laid-out lines happen to be (QuoinTextView.swift:677-689).
            // The inset is the cell's base inset plus the decoration's own
            // nesting inset (nested cards start at their container column).
            let inset = leadingInset + decoration.leadingInset
            switch decoration.kind {
            case .codeCanvas, .callout, .diagramFrame, .editingFrame:
                union.origin.x = inset
                union.size.width = contentWidth - inset
            default:
                break
            }

            // `rect` is the FINAL drawn rect per kind: the negative-inset bleed,
            // the chip clamp, and the quote bar are resolved here (the Box has
            // no textWidth field, and this makes the bleed visible in test
            // geometry). `draw` paints `box.rect` directly.
            let rect: CGRect
            switch decoration.kind {
            case .codeCanvas:
                rect = union.insetBy(dx: 0, dy: -2)
            case .callout:
                rect = union.insetBy(dx: 0, dy: -5)
            case .diagramFrame:
                rect = union.insetBy(dx: 0, dy: -4)
            case .chip:
                rect = CGRect(x: union.minX,
                              y: union.minY + 1,
                              width: min(textWidth + 16, union.width),
                              height: union.height - 2)
            case .quoteRule:
                // The 3pt bar in the reserved left gutter: `box.minX - leftGutter`
                // lands it at the cell's leading edge (QuoinTextView.swift:766).
                rect = CGRect(x: union.minX - leftGutter,
                              y: union.minY + 3,
                              width: 3,
                              height: union.height - 6)
            case .tableRules, .editingFrame:
                rect = union
            }

            result.append(Box(kind: decoration.kind, rect: rect, rowFrames: frames))
        }
        return result
    }

    /// Draw the boxes with per-kind CoreGraphics, ported from
    /// `QuoinTextView.draw(_:)` (`:731-820`). Every kind paints its FINAL
    /// `box.rect` (bleed/clamp/gutter already folded in by `boxes`); the spanning
    /// `.callout` (multi-run + nested inset) and `.quoteRule` (left gutter) kinds
    /// paint here now. `.editingFrame` is editor-only and stays a no-op.
    public static func draw(_ boxes: [Box], in ctx: CGContext, theme: Theme) {
        _ = theme  // colors come off the payloads; kept for API stability.
        for box in boxes {
            ctx.saveGState()
            switch box.kind {
            case .codeCanvas(let fill):
                ctx.addPath(CGPath(roundedRect: box.rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
                ctx.setFillColor(fill.cgColor)
                ctx.fillPath()

            case .callout(let color):
                // Tinted rounded box + hairline border (QuoinTextView.swift:751).
                // A callout stamps this decoration on EVERY non-card gap range,
                // so a callout that wraps a code block / diagram produces several
                // `.callout` boxes in one cell — each is drawn here. Nested child
                // cards carry their OWN decoration at `inset(by: 12)`, surfaced as
                // separate boxes whose leadingInset moved their column in.
                ctx.addPath(CGPath(roundedRect: box.rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
                ctx.setFillColor(color.withAlphaComponent(0.05).cgColor)
                ctx.fillPath()
                ctx.addPath(CGPath(
                    roundedRect: box.rect.insetBy(dx: 0.5, dy: 0.5),
                    cornerWidth: 7.5, cornerHeight: 7.5, transform: nil
                ))
                ctx.setStrokeColor(color.withAlphaComponent(0.15).cgColor)
                ctx.setLineWidth(1)
                ctx.strokePath()

            case .quoteRule(let color):
                // The 3pt bar in the reserved left gutter; `box.rect` is already
                // the bar (QuoinTextView.swift:766, gutter reserved by the cell).
                ctx.addPath(CGPath(roundedRect: box.rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
                ctx.setFillColor(color.cgColor)
                ctx.fillPath()

            case .diagramFrame(let color):
                ctx.addPath(CGPath(
                    roundedRect: box.rect.insetBy(dx: 0.5, dy: 0.5),
                    cornerWidth: 8, cornerHeight: 8, transform: nil
                ))
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(1)
                ctx.strokePath()

            case .chip(let fill):
                // rect is already the final clamped chip rect (see `boxes`).
                ctx.addPath(CGPath(roundedRect: box.rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.setFillColor(fill.cgColor)
                ctx.fillPath()

            case .tableRules(let width, let header, let body):
                let lineWidth = min(width + 24, box.rect.width)
                for (index, frame) in box.rowFrames.enumerated() {
                    let y = frame.maxY - (index == 0 ? 0.75 : 0.5)
                    ctx.setStrokeColor((index == 0 ? header : body).cgColor)
                    ctx.setLineWidth(index == 0 ? 1.5 : 1)
                    ctx.move(to: CGPoint(x: frame.minX, y: y))
                    ctx.addLine(to: CGPoint(x: frame.minX + lineWidth, y: y))
                    ctx.strokePath()
                }

            case .editingFrame:
                break  // editor-only chrome — not drawn in a read-only cell.
            }
            ctx.restoreGState()
        }
    }

    /// UTF-16 `NSRange` → TextKit-2 `NSTextRange`. Mirrors QuoinRender's
    /// internal `nsTextRange` helper (not visible across the module boundary).
    private static func textRange(_ range: NSRange, in contentManager: NSTextContentManager) -> NSTextRange? {
        let documentStart = contentManager.documentRange.location
        guard let start = contentManager.location(documentStart, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }
}
#endif
