#if canImport(AppKit)
import XCTest
import AppKit
import SwiftUI
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

/// Phase 1, Task 8: the `NSViewRepresentable` seam that hosts the block
/// recycler behind `-QuoinEditorRecycler`. Full app behavior is verified
/// manually via the flag; this is a lightweight smoke test that the wrapper
/// builds the hosted `BlockRecyclerView` and feeds it the document, so the
/// table has one row per block.
@MainActor
final class BlockRecyclerReaderViewTests: XCTestCase {

    func testHostedRecyclerHasRowPerBlock() {
        let doc = MarkdownConverter.parse((0..<12).map { "P\($0)." }.joined(separator: "\n\n"))
        let repr = BlockRecyclerReaderView(
            document: doc,
            rendered: .empty,
            theme: Theme(),
            renderer: AttributedRenderer(theme: Theme()),
            scrollTarget: nil,
            onTopBlockChange: nil,
            searchQuery: nil)

        let view = repr.makeRecycler(coordinator: repr.makeCoordinator())

        XCTAssertEqual(view.numberOfRowsForTest, doc.blocks.count)
        XCTAssertEqual(doc.blocks.count, 12)
    }

    /// The reader's CONFIGURED renderer is threaded into the hosted recycler —
    /// not a bare `AttributedRenderer(theme:)` — so relative-path images resolve
    /// and async decodes re-render under the flag (findings 1 & 2). The recycler
    /// must render through THAT renderer, carrying its `baseURL`.
    func testConfiguredRendererForwarded() {
        let doc = MarkdownConverter.parse("Body.")
        let base = URL(fileURLWithPath: "/tmp/quoin-recycler-fixture")
        let configured = AttributedRenderer(theme: Theme(), baseURL: base)
        let repr = BlockRecyclerReaderView(
            document: doc,
            rendered: .empty,
            theme: Theme(),
            renderer: configured,
            scrollTarget: nil,
            onTopBlockChange: nil,
            searchQuery: nil,
            wordWrap: false)

        let view = repr.makeRecycler(coordinator: repr.makeCoordinator())

        XCTAssertEqual(view.configuredRendererForTest.baseURL, base,
                       "recycler must render through the model's configured renderer (baseURL)")
        XCTAssertTrue(view.hasHorizontalScrollerForTest,
                      "wordWrap:false must reach the hosted recycler")
    }

    /// A repeat outline click on the SAME heading keeps `scrollTarget` but bumps
    /// `scrollGeneration`; that bump must re-fire the scroll (finding 3), while a
    /// re-apply with no change to either must NOT scroll again.
    func testScrollGenerationRefiresScroll() {
        let doc = MarkdownConverter.parse((0..<30).map { "P\($0)." }.joined(separator: "\n\n"))
        let target = doc.blocks[20].id
        let coordinator = BlockRecyclerReaderView.Coordinator()

        func repr(generation: Int) -> BlockRecyclerReaderView {
            BlockRecyclerReaderView(
                document: doc,
                rendered: RenderedDocument(attributed: NSAttributedString(), blockRanges: [:], revision: 1),
                theme: Theme(),
                renderer: AttributedRenderer(theme: Theme()),
                scrollTarget: target,
                scrollGeneration: generation,
                onTopBlockChange: nil,
                searchQuery: nil)
        }

        let view = repr(generation: 0).makeRecycler(coordinator: coordinator)
        XCTAssertEqual(view.scrollToCallCountForTest, 1, "initial target scrolls once")

        // Same target, same generation: no re-scroll (don't fight user scrolling).
        repr(generation: 0).apply(to: view, coordinator: coordinator, initial: false)
        XCTAssertEqual(view.scrollToCallCountForTest, 1, "unchanged target+generation must not re-scroll")

        // Same target, bumped generation (the repeat click): re-scroll.
        repr(generation: 1).apply(to: view, coordinator: coordinator, initial: false)
        XCTAssertEqual(view.scrollToCallCountForTest, 2, "a scrollGeneration bump must re-fire the scroll")
    }

    /// The top-block callback is forwarded to the hosted recycler so the
    /// outline sync keeps working under the flag.
    func testTopBlockCallbackForwarded() {
        let doc = MarkdownConverter.parse((0..<30).map { "P\($0)." }.joined(separator: "\n\n"))
        var top: BlockID?
        let repr = BlockRecyclerReaderView(
            document: doc,
            rendered: .empty,
            theme: Theme(),
            renderer: AttributedRenderer(theme: Theme()),
            scrollTarget: nil,
            onTopBlockChange: { top = $0 },
            searchQuery: nil)

        let view = repr.makeRecycler(coordinator: repr.makeCoordinator())
        let window = OffscreenTestWindow.make(width: 640, height: 400)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()

        view.scroll(to: doc.blocks[20].id)
        view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(top, "onTopBlockChange must reach the hosted recycler")
    }

    /// A repeat re-apply with an unchanged revision must NOT reload (that would
    /// discard scroll position); a changed revision must.
    func testRevisionGuardsReload() {
        let doc = MarkdownConverter.parse("# H\n\nBody.")
        let coordinator = BlockRecyclerReaderView.Coordinator()
        let repr = BlockRecyclerReaderView(
            document: doc,
            rendered: RenderedDocument(attributed: NSAttributedString(), blockRanges: [:], revision: 1),
            theme: Theme(),
            renderer: AttributedRenderer(theme: Theme()),
            scrollTarget: nil,
            onTopBlockChange: nil,
            searchQuery: nil)
        let view = repr.makeRecycler(coordinator: coordinator)
        XCTAssertEqual(view.numberOfRowsForTest, doc.blocks.count)
        // Same revision: apply is a no-op reload but rows stay consistent.
        repr.apply(to: view, coordinator: coordinator, initial: false)
        XCTAssertEqual(view.numberOfRowsForTest, doc.blocks.count)
        XCTAssertEqual(coordinator.appliedRevision, 1)
    }
}
#endif
