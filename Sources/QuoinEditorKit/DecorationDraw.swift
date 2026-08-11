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
    ///   - contentWidth: the cell's configured content width (full-width chrome
    ///     spans this column regardless of the laid-out line widths).
    ///   - leadingInset: the cell's base left content inset (Task 4 padding);
    ///     added to each decoration's own nesting `leadingInset` for the
    ///     full-width reset. Pass 0 until padding lands.
    public static func boxes(in layoutManager: NSTextLayoutManager,
                             contentStorage: NSTextContentStorage,
                             contentWidth: CGFloat,
                             leadingInset: CGFloat) -> [Box] {
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
                frames.append(fragment.layoutFragmentFrame)
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

            // `.chip` folds its textWidth-derived clamp into `rect` (the Box
            // has no textWidth field); every other kind keeps rect = union.
            let rect: CGRect
            if case .chip = decoration.kind {
                rect = CGRect(x: union.minX,
                              y: union.minY + 1,
                              width: min(textWidth + 16, union.width),
                              height: union.height - 2)
            } else {
                rect = union
            }

            result.append(Box(kind: decoration.kind, rect: rect, rowFrames: frames))
        }
        return result
    }

    /// Draw the boxes with per-kind CoreGraphics, ported from
    /// `QuoinTextView.draw(_:)` (`:731-820`). Only the four per-block-local
    /// kinds paint; `.callout` / `.quoteRule` (Task 3) and `.editingFrame`
    /// (editor-only) are no-ops.
    public static func draw(_ boxes: [Box], in ctx: CGContext, theme: Theme) {
        _ = theme  // colors come off the payloads; kept for API stability.
        for box in boxes {
            ctx.saveGState()
            switch box.kind {
            case .codeCanvas(let fill):
                let rect = box.rect.insetBy(dx: 0, dy: -2)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
                ctx.setFillColor(fill.cgColor)
                ctx.fillPath()

            case .diagramFrame(let color):
                let rect = box.rect.insetBy(dx: 0, dy: -4)
                ctx.addPath(CGPath(
                    roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
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

            case .callout, .quoteRule, .editingFrame:
                break  // Task 3 (spanning kinds) / editor-only — not drawn here.
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
