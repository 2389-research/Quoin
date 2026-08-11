#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

@MainActor
final class BlockRowMetricsTests: XCTestCase {
    func testRowHeightExceedsBareTextHeight() {
        let doc = MarkdownConverter.parse("```\ncode\n```\n\nplain paragraph")
        let r = AttributedRenderer()
        let text = r.measuredHeight(of: doc.blocks[0], in: doc, width: 600)
        let row = BlockRowMetrics.rowHeight(
            for: doc.blocks[0], at: 0, in: doc, renderer: r, theme: Theme(), width: 600)
        XCTAssertGreaterThanOrEqual(row, text, "row includes decoration padding + separator spacing")
    }

    func testSumOfRowHeightsApproxDocumentHeight() {
        let doc = MarkdownConverter.parse("# H\n\nOne.\n\nTwo.\n\nThree.")
        let r = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let full = r.render(doc, cache: &cache)                 // the monolith projection
        let docHeight = measureAttributedHeight(full.attributed, width: 600)
        let sum = doc.blocks.enumerated().reduce(CGFloat.zero) { acc, e in
            acc + BlockRowMetrics.rowHeight(
                for: e.element, at: e.offset, in: doc, renderer: r, theme: Theme(), width: 600)
        }
        XCTAssertEqual(sum, docHeight, accuracy: max(8, docHeight * 0.05))   // within ~5% / 8pt
    }

    /// The parity gate isn't a prose-only accident: a document mixing cards
    /// (code, table), a quote, and a list must also stack to ≈ the monolith's
    /// height, since a card seam contributes MORE inter-block air than a prose
    /// seam and the separator model must track that per kind-pair.
    func testSumOfRowHeightsApproxDocumentHeightForMixedDocument() {
        let doc = MarkdownConverter.parse(
            "# H\n\n```\ncode line\nmore\n```\n\nAfter para.\n\n> a quote\n\n- item one\n- item two")
        let r = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let full = r.render(doc, cache: &cache)
        let docHeight = measureAttributedHeight(full.attributed, width: 600)
        let sum = doc.blocks.enumerated().reduce(CGFloat.zero) { acc, e in
            acc + BlockRowMetrics.rowHeight(
                for: e.element, at: e.offset, in: doc, renderer: r, theme: Theme(), width: 600)
        }
        XCTAssertEqual(sum, docHeight, accuracy: max(8, docHeight * 0.05))
    }

    /// `separatorContribution` is memoized by `(after, before, width)`: the eager
    /// per-row `heightOfRow` queries must share ONE measurement per key, not pay
    /// three TextKit layouts per row. The cached value must be byte-identical to
    /// the uncached one (a cache must not change the number).
    func testSeparatorContributionMemoizedAndIdentical() {
        BlockRowMetrics.resetSeparatorCacheForTest()
        let r = AttributedRenderer()
        // Real block kinds (they carry associated values) to key the seam on.
        let doc = MarkdownConverter.parse("One.\n\nTwo.\n\n```\ncode\n```\n\n# H")
        let paraA = doc.blocks[0].kind          // "One."
        let paraB = doc.blocks[1].kind          // "Two." — different inlines, same prose separator
        let code = doc.blocks[2].kind           // a CARD — larger inter-block gap

        let first = BlockRowMetrics.separatorContribution(
            after: paraA, before: paraB, renderer: r, width: 600)
        XCTAssertEqual(BlockRowMetrics.separatorComputeCountForTest, 1, "first query measures")

        // Same seam repeated many times: served from cache, value unchanged.
        for _ in 0..<50 {
            let again = BlockRowMetrics.separatorContribution(
                after: paraA, before: paraB, renderer: r, width: 600)
            XCTAssertEqual(again, first, "cached value must equal the measured value")
        }
        XCTAssertEqual(BlockRowMetrics.separatorComputeCountForTest, 1, "repeat seams must not re-measure")

        // A DIFFERENT prose pair (distinct kinds, but the SAME "\n" separator)
        // is the same cache key — the whole point of keying on content, not
        // kinds — so it must NOT re-measure.
        _ = BlockRowMetrics.separatorContribution(
            after: paraB, before: paraA, renderer: r, width: 600)
        XCTAssertEqual(BlockRowMetrics.separatorComputeCountForTest, 1,
                       "a distinct prose pair shares the prose separator key — no re-measure")

        // A card seam emits a LARGER separator (distinct content) → new key, and
        // a different width is a distinct key too.
        _ = BlockRowMetrics.separatorContribution(
            after: paraA, before: code, renderer: r, width: 600)
        _ = BlockRowMetrics.separatorContribution(
            after: paraA, before: paraB, renderer: r, width: 320)
        XCTAssertEqual(BlockRowMetrics.separatorComputeCountForTest, 3, "distinct keys each measure once")
    }

    // TextKit-2 measure copied from RevealFidelityTests.measureHeight (maxY of
    // the last laid-out fragment = total laid-out height of the whole string).
    private func measureAttributedHeight(_ attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributed)
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = storage
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        layoutManager.ensureLayout(for: contentStorage.documentRange)
        var maxY: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(from: contentStorage.documentRange.location) { fragment in
            maxY = max(maxY, fragment.layoutFragmentFrame.maxY)
            return true
        }
        return maxY
    }
}
#endif
