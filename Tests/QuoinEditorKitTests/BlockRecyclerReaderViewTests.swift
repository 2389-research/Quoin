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
final class BlockRecyclerReaderViewTests: AppKitWindowTestCase {

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
        let window = makeTestWindow(width: 640, height: 400)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()

        view.scroll(to: doc.blocks[20].id)
        view.layoutSubtreeIfNeeded()
        // Not merely "something was reported": the forwarded callback must carry
        // the RIGHT block. Checked against AppKit's own visible-row range, not
        // against block 20 — `scroll(to:)` scrolls MINIMALLY, so block 20 lands at
        // the bottom and an earlier block is genuinely the top one (see
        // `BlockRecyclerViewTests.testTopBlockReported`).
        let visible = view.tableViewForTest.rows(in: view.tableViewForTest.visibleRect)
        XCTAssertGreaterThan(visible.length, 0, "precondition: some rows are visible")
        XCTAssertNotEqual(top, doc.blocks[0].id,
                          "the forwarded callback must have TRACKED the scroll")
        XCTAssertEqual(top, doc.blocks[visible.location].id,
                       "onTopBlockChange must reach the hosted recycler with the top-most visible "
                       + "block (row \(visible.location); got \(top.map { "\($0)" } ?? "nil"))")
    }

    /// A repeat re-apply with an unchanged revision must NOT reload (that would
    /// discard scroll position); a changed revision must.
    ///
    /// PROVEN VACUOUS AND REWRITTEN. The old body re-applied the SAME
    /// representable and then asserted `numberOfRowsForTest` and
    /// `appliedRevision` — both of which are equally true when `apply` reloads on
    /// every call, so it discriminated nothing. Measured: with the revision gate
    /// deleted in production (an unconditional `always-reload` branch), the old
    /// test still passed.
    ///
    /// The rewrite makes the two applies differ in DOCUMENT CONTENT, so the
    /// question "did the refresh run?" has a directly observable answer that does
    /// not depend on AppKit's reload timing: content-hash `BlockID`s change with
    /// the text, so the recycler either knows the new document's blocks or it
    /// does not. A gate that leaks (always reloads) adopts the new document at
    /// step 1 and fails; a gate welded shut never adopts it and fails step 2.
    func testRevisionGuardsReload() {
        let doc = MarkdownConverter.parse("# H\n\nBody.")
        let edited = MarkdownConverter.parse("# H\n\nBody, edited.")
        XCTAssertNotEqual(doc.blocks[1].id, edited.blocks[1].id,
                          "precondition: the edit changes the content-hash block id")

        let coordinator = BlockRecyclerReaderView.Coordinator()
        func repr(revision: Int, document: QuoinDocument) -> BlockRecyclerReaderView {
            BlockRecyclerReaderView(
                document: document,
                rendered: RenderedDocument(attributed: NSAttributedString(),
                                           blockRanges: [:], revision: revision),
                theme: Theme(),
                renderer: AttributedRenderer(theme: Theme()),
                scrollTarget: nil,
                onTopBlockChange: nil,
                searchQuery: nil)
        }
        let view = repr(revision: 1, document: doc).makeRecycler(coordinator: coordinator)
        let window = makeTestWindow(width: 640, height: 400)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.numberOfRowsForTest, doc.blocks.count)

        // Settle the applied WIDTH to the laid-out one, so the applies below
        // differ only in revision/document (width is the gate's other input).
        repr(revision: 1, document: doc).apply(to: view, coordinator: coordinator, initial: false)
        XCTAssertNotNil(view.rowForBlockID(doc.blocks[1].id),
                        "precondition: the recycler hosts the ORIGINAL document")

        // 1. NEW document, UNCHANGED revision → the gate must hold. The recycler
        // must still be showing the old document: re-applying here would discard
        // scroll position (and, with an island live, first responder).
        repr(revision: 1, document: edited).apply(to: view, coordinator: coordinator, initial: false)
        XCTAssertNil(view.rowForBlockID(edited.blocks[1].id),
                     "an unchanged revision must NOT adopt a new document (that reload would "
                     + "discard scroll position)")
        XCTAssertNotNil(view.rowForBlockID(doc.blocks[1].id),
                        "…the original document is still the one on screen")
        XCTAssertEqual(coordinator.appliedRevision, 1)

        // 2. Same new document, BUMPED revision → the refresh must genuinely run.
        // Anti-vacuity for step 1: a gate welded shut would satisfy it forever.
        repr(revision: 2, document: edited).apply(to: view, coordinator: coordinator, initial: false)
        XCTAssertNotNil(view.rowForBlockID(edited.blocks[1].id),
                        "a revision bump must re-run the refresh onto the new document")
        XCTAssertNil(view.rowForBlockID(doc.blocks[1].id),
                     "…and the superseded document's blocks are gone")
        XCTAssertEqual(coordinator.appliedRevision, 2)
        XCTAssertEqual(view.numberOfRowsForTest, edited.blocks.count)
    }
}
#endif
