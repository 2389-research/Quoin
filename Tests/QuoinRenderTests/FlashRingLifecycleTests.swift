#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Flash-ring and transient-chrome lifecycle (#72, stray overlay in the
/// sidebar region): a ring's frame is frozen at flash time and its removal
/// rides a 1.8s animation completion, so rapid flashes must REPLACE the
/// live ring (never stack), and editor teardown must remove chrome
/// explicitly instead of waiting on animations or popover behaviors.
final class FlashRingLifecycleTests: XCTestCase {

    private struct Harness {
        let coordinator: MarkdownReaderView.Coordinator
        let textView: QuoinTextView
        let document: QuoinDocument
    }

    private func makeHarness(source: String) -> Harness {
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let result = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.textContentStorage?.textStorage?.setAttributedString(result.attributed)

        let view = MarkdownReaderView(
            rendered: RenderedDocument(
                attributed: result.attributed, blockRanges: result.blockRanges,
                activeBlockID: nil, activeEditableRange: nil,
                activeSourceText: nil),
            onEditIntent: { _, _, _ in },
            onActivateBlock: { _, _, _ in }
        )
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView
        coordinator.blockRanges = result.blockRanges
        return Harness(coordinator: coordinator, textView: textView, document: document)
    }

    private func rings(in textView: NSTextView) -> [FlashRingView] {
        textView.subviews.compactMap { $0 as? FlashRingView }
    }

    /// No suggestion mark at the offset → the fallback block-pulse path;
    /// what matters here is only that a ring is mounted.
    private func flash(_ harness: Harness) throws {
        let block = try XCTUnwrap(harness.document.blocks.first)
        harness.coordinator.flashSuggestionMark(
            byteOffset: .max, fallbackBlockID: block.id, in: harness.textView)
    }

    func testFlashMountsExactlyOneRing() throws {
        let harness = makeHarness(source: "One paragraph of body text.\n")
        try flash(harness)
        XCTAssertEqual(rings(in: harness.textView).count, 1)
        XCTAssertNotNil(harness.coordinator.activeFlashRing)
    }

    func testSecondFlashReplacesThePredecessorRing() throws {
        let harness = makeHarness(source: "One paragraph of body text.\n")
        try flash(harness)
        let first = try XCTUnwrap(harness.coordinator.activeFlashRing)
        try flash(harness)

        let live = rings(in: harness.textView)
        XCTAssertEqual(live.count, 1, "rapid flashes must not stack rings")
        XCTAssertFalse(live.contains(first), "the stale-framed predecessor is gone")
        XCTAssertTrue(first.superview == nil)
    }

    func testTeardownRemovesTheLiveRingAndDropsPopovers() throws {
        let harness = makeHarness(source: "One paragraph of body text.\n")
        try flash(harness)
        harness.coordinator.annotationPopover = NSPopover()

        harness.coordinator.teardownTransientChrome()

        XCTAssertTrue(rings(in: harness.textView).isEmpty,
                      "teardown must not wait on the fade-out completion")
        XCTAssertNil(harness.coordinator.activeFlashRing)
        XCTAssertNil(harness.coordinator.annotationPopover)
    }

    func testDismantleTearsDownTransientChrome() throws {
        let harness = makeHarness(source: "One paragraph of body text.\n")
        try flash(harness)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = harness.textView

        MarkdownReaderView.dismantleNSView(scrollView, coordinator: harness.coordinator)

        XCTAssertTrue(rings(in: harness.textView).isEmpty)
    }
}
#endif
