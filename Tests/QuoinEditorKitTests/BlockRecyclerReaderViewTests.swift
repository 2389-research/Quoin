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

    /// A re-apply that changes nothing must NOT reload (that would discard scroll
    /// position); a re-apply whose CONTENT differs must.
    ///
    /// PROVEN VACUOUS AND REWRITTEN ONCE (the old body re-applied the SAME
    /// representable and asserted `numberOfRowsForTest` + `appliedRevision`, both
    /// equally true under an unconditional always-reload; measured — with the gate
    /// deleted in production the old test still passed). The rewrite makes the
    /// applies differ in DOCUMENT CONTENT, so "did the refresh run?" has a directly
    /// observable answer that does not depend on AppKit's reload timing:
    /// content-hash `BlockID`s change with the text, so the recycler either knows
    /// the new document's blocks or it does not.
    ///
    /// **RE-POINTED AT THE CONTENT GATE (I6).** The gate used to be
    /// `appliedRevision != rendered.revision`, so this test asserted that a new
    /// document at an UNCHANGED revision must be ignored. That polarity is now
    /// inverted, deliberately: `rendered.revision` is a PROJECTION counter that
    /// `ReaderModel` bumps without changing a byte (`restoreCaret`,
    /// `rerenderAsync`, the 120 ms decode debounce), so the gate keys off
    /// `document.sourceHash`. New bytes are re-projected whether or not the
    /// revision moved (showing stale bytes would be the worse failure), and a bare
    /// revision bump re-projects nothing. `RecyclerRefreshGateTests` owns the
    /// churn measurements; this stays as the wrapper-level statement of the gate.
    func testContentIdentityGuardsReload() {
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

        // 1. SAME document, BUMPED revision → the gate must hold. A projection-only
        // bump must not re-project anything: no reload, no scroll position thrown
        // away, and (elsewhere) no settled heights discarded.
        repr(revision: 2, document: doc).apply(to: view, coordinator: coordinator, initial: false)
        XCTAssertNotNil(view.rowForBlockID(doc.blocks[1].id),
                        "a bare revision bump must leave the projected document alone")
        XCTAssertEqual(coordinator.appliedRevision, 2,
                       "…while still consuming the revision, so it is not re-evaluated forever")

        // 2. NEW document → the refresh must genuinely run, because the CONTENT is
        // what the gate keys off. Anti-vacuity for step 1: a gate welded shut would
        // satisfy it forever.
        repr(revision: 3, document: edited).apply(to: view, coordinator: coordinator, initial: false)
        XCTAssertNotNil(view.rowForBlockID(edited.blocks[1].id),
                        "a content change must re-run the refresh onto the new document")
        XCTAssertNil(view.rowForBlockID(doc.blocks[1].id),
                     "…and the superseded document's blocks are gone")
        XCTAssertEqual(coordinator.appliedRevision, 3)
        XCTAssertEqual(view.numberOfRowsForTest, edited.blocks.count)

        // 3. And the content gate does not need the revision's permission: a
        // FURTHER content change at the SAME revision is adopted too (stale bytes
        // on screen would be the worse failure).
        let again = MarkdownConverter.parse("# H\n\nBody, edited twice.")
        repr(revision: 3, document: again).apply(to: view, coordinator: coordinator, initial: false)
        XCTAssertNotNil(view.rowForBlockID(again.blocks[1].id),
                        "content identity, not the projection counter, decides")
    }
}
#endif
