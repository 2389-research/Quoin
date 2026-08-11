#if canImport(AppKit)
import AppKit
import QuoinCore

extension AttributedRenderer {
    /// Deterministic laid-out height of a single block's KEEP projection at
    /// `width`. `BlockRenderCell` (Phase 1) uses this for its row height —
    /// the cell-sizing contract — so it must match what the cell draws.
    public func measuredHeight(of block: Block, in document: QuoinDocument, width: CGFloat) -> CGFloat {
        withLayout(of: block, in: document, width: width) { layoutManager, contentStorage in
            var total: CGFloat = 0
            layoutManager.enumerateTextLayoutFragments(from: contentStorage.documentRange.location) { fragment in
                total += fragment.layoutFragmentFrame.height
                return true
            }
            return total
        }
    }

    /// The top y of each laid-out visual line for a block's KEEP projection
    /// at `width`, in ascending order (a wrapping paragraph is one text
    /// layout fragment carrying several line fragments). Feeds click-to-caret
    /// line mapping (Phase 2).
    public func lineTops(of block: Block, in document: QuoinDocument, width: CGFloat) -> [CGFloat] {
        withLayout(of: block, in: document, width: width) { layoutManager, contentStorage in
            var tops: [CGFloat] = []
            layoutManager.enumerateTextLayoutFragments(from: contentStorage.documentRange.location) { fragment in
                let originY = fragment.layoutFragmentFrame.minY
                for line in fragment.textLineFragments {
                    tops.append(originY + line.typographicBounds.minY)
                }
                return true
            }
            return tops
        }
    }

    /// Render the block via the existing single-block KEEP renderer
    /// (`renderReadFragment` wraps `render(block:depth:document:)`), then run
    /// a TextKit-2 layout pass — mirroring `RevealFidelityTests.measureHeight`.
    private func withLayout<T>(
        of block: Block, in document: QuoinDocument, width: CGFloat,
        _ body: (NSTextLayoutManager, NSTextContentStorage) -> T
    ) -> T {
        let attributed = renderReadFragment(block, document: document).fragment
        let storage = NSTextStorage(attributedString: attributed)
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = storage
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = NSTextContainer(
            size: NSSize(width: width, height: .greatestFiniteMagnitude))
        layoutManager.ensureLayout(for: contentStorage.documentRange)
        return body(layoutManager, contentStorage)
    }
}
#endif
