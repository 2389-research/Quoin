#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// The chart ↔ source flip contract: activating a mermaid/code block (or
/// closing it again) replaces content whose height differs wildly, and the
/// flipped block must stay pinned where the user is looking — the viewport
/// must not lurch by the height delta, and the spliced region must lay out
/// cleanly (no overlapping line fragments — the "stacked lines" artifact).
final class EmbedFlipAnchoringTests: XCTestCase {

    /// A document long enough to scroll, with a mermaid chart mid-way.
    private func makeDocument() -> QuoinDocument {
        var source = "# Flip anchoring\n\n"
        for i in 0..<40 {
            source += "Paragraph \(i) with enough words to occupy a line or two of the viewport.\n\n"
        }
        source += """
        ```mermaid
        flowchart TD
            A[Weigh anchor] --> B{Wind fair?}
            B -->|yes| C[Set course]
            B -->|no| D[Wait in port]
        ```

        """
        for i in 40..<80 {
            source += "Paragraph \(i) with enough words to occupy a line or two of the viewport.\n\n"
        }
        return MarkdownConverter.parse(source)
    }

    /// The real TextKit 2 stack MarkdownReaderView builds, in a scroll view
    /// with a fixed viewport, no window needed.
    private func makeStack() -> (scroll: NSScrollView, textView: QuoinTextView) {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 0), textContainer: container)
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = textView
        return (scroll, textView)
    }

    private func mermaidBlockID(in document: QuoinDocument) -> BlockID? {
        document.blocks.first {
            if case .diagram = $0.kind { return true }
            return false
        }?.id
    }

    func testFlipKeepsBlockPinnedAndFragmentsNonOverlapping() throws {
        let document = makeDocument()
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let mermaidID = try XCTUnwrap(mermaidBlockID(in: document))

        // Rendered (chart) projection, then the flipped (source) projection.
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        cache.removeAll()
        let editing = renderer.render(document, activeBlockID: mermaidID, activeCaret: 5, cache: &cache)
        let readingRange = try XCTUnwrap(reading.blockRanges[mermaidID])
        let editingRange = try XCTUnwrap(editing.blockRanges[mermaidID])

        let (scroll, textView) = makeStack()
        let storage = try XCTUnwrap(textView.textContentStorage?.textStorage)
        storage.setAttributedString(reading.attributed)
        textView.textLayoutManager?.ensureLayout(for: try XCTUnwrap(
            textView.textContentStorage?.documentRange))
        textView.sizeToFit()

        // Scroll the chart into the middle of the viewport.
        let view = MarkdownReaderView(rendered: RenderedDocument(
            attributed: reading.attributed, blockRanges: reading.blockRanges,
            activeBlockID: nil, activeEditableRange: nil, activeSourceText: nil))
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView
        coordinator.scrollBlockTop(readingRange, toScreenY: 150, in: textView)
        let before = try XCTUnwrap(coordinator.blockTopScreenY(readingRange, in: textView))
        XCTAssertEqual(before, 150, accuracy: 2, "test setup: chart must start pinned at 150")

        // FLIP: splice the editing projection in (what updateNSView does),
        // then pin the flipped block back to its captured screen y.
        _ = MarkdownReaderView.Coordinator.spliceChanges(in: storage, to: editing.attributed)
        coordinator.scrollBlockTop(editingRange, toScreenY: before, in: textView)

        let after = try XCTUnwrap(coordinator.blockTopScreenY(editingRange, in: textView))
        XCTAssertEqual(after, before, accuracy: 2,
                       "flipped block must stay pinned on screen (was \(before), now \(after))")

        // The spliced region must lay out without overlapping fragments —
        // the "stacked lines" artifact class.
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        let contentStorage = try XCTUnwrap(textView.textContentStorage)
        let textRange = try XCTUnwrap(nsTextRange(
            NSRange(location: 0, length: storage.length), in: contentStorage))
        layoutManager.ensureLayout(for: textRange)
        var previousMaxY: CGFloat = -.greatestFiniteMagnitude
        var overlaps: [String] = []
        layoutManager.enumerateTextLayoutFragments(
            from: contentStorage.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY < previousMaxY - 1 {
                overlaps.append("fragment at y=\(frame.minY) overlaps previous ending y=\(previousMaxY)")
            }
            previousMaxY = max(previousMaxY, frame.maxY)
            return true
        }
        XCTAssertTrue(overlaps.isEmpty, "stacked lines after flip: \(overlaps.prefix(3))")

        // And the flip back (source → chart) re-pins just the same.
        _ = MarkdownReaderView.Coordinator.spliceChanges(in: storage, to: reading.attributed)
        coordinator.scrollBlockTop(readingRange, toScreenY: before, in: textView)
        let restored = try XCTUnwrap(coordinator.blockTopScreenY(readingRange, in: textView))
        XCTAssertEqual(restored, before, accuracy: 2,
                       "flip back must re-pin the chart (was \(before), now \(restored))")
    }
}
#endif
