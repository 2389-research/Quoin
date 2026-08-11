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
