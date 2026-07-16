#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Latency budgets for the render-layer paths the launch ledger flagged as
/// document-scale (perf #4/#5/#8/#11), in the EditingRenderLatencyTests
/// convention: manual best-of clocks against the shared 25ms budget — one
/// 60Hz frame is 16ms for the WHOLE loop; 25ms leaves shared-CI headroom
/// while still failing unmistakably on anything that regresses back to
/// O(document-blocks) per event.
///
/// Fixture sizes are chosen so the PRE-fix implementations fail these
/// budgets (measured: the bridged attribute-sync walk was ~110ms at novel
/// scale; the linear blockID scan was ~10µs × blocks × queries).
final class RenderPathLatencyTests: XCTestCase {

    private let budget: TimeInterval = 0.025

    /// ~600 paragraphs with inline spans plus periodic callouts — enough
    /// blocks and attribute runs to be unmistakably document-scale.
    private static let bigSource: String = {
        var source = "# Big Document\n\n"
        for i in 0..<600 {
            source += "Paragraph \(i) with **bold** and *italic* and `code` and [link](https://example.com/\(i)). "
            source += "Second sentence of paragraph \(i). Third sentence here.\n\n"
            if i % 50 == 0 {
                source += "> [!NOTE]\n> Callout \(i) body text here.\n\n"
            }
        }
        return source
    }()

    private struct Harness {
        let document: QuoinDocument
        let rendered: RenderedDocument
        let coordinator: MarkdownReaderView.Coordinator
        let textView: QuoinTextView
        let scroll: NSScrollView
    }

    /// Real TextKit 2 stack in a scrollable 600×400 viewport (the
    /// CaretLineAnchorTests idiom), fully laid out.
    private func makeHarness(
        source: String, focusMode: Bool = false, sentenceScope: Bool = false
    ) throws -> Harness {
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 0), textContainer: container)
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = textView
        let storage = try XCTUnwrap(textView.textContentStorage?.textStorage)
        storage.setAttributedString(reading.attributed)
        textView.textLayoutManager?.ensureLayout(
            for: try XCTUnwrap(textView.textContentStorage?.documentRange))
        textView.sizeToFit()

        let view = MarkdownReaderView(
            rendered: reading,
            focusModeEnabled: focusMode,
            focusSentenceScope: sentenceScope
        )
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView
        coordinator.blockRanges = reading.blockRanges
        return Harness(document: document, rendered: reading,
                       coordinator: coordinator, textView: textView, scroll: scroll)
    }

    // MARK: Focus dimming (perf #4)

    /// A caret move into a DIFFERENT block — the full repaint path (remove
    /// + viewport-culled re-add). This is the per-caret-move cost while
    /// focus mode is on; it must be viewport-scale, never document-scale.
    func testFocusDimmingBlockMoveMeetsBudget() throws {
        let harness = try makeHarness(source: Self.bigSource, focusMode: true)
        let text = harness.textView.textContentStorage!.textStorage!.string as NSString
        let locA = text.range(of: "Paragraph 3 ").location
        let locB = text.range(of: "Paragraph 5 ").location
        XCTAssertNotEqual(locA, NSNotFound)
        XCTAssertNotEqual(locB, NSNotFound)

        var best = TimeInterval.greatestFiniteMagnitude
        for i in 0..<8 {
            harness.textView.setSelectedRange(NSRange(location: i % 2 == 0 ? locA : locB, length: 0))
            let start = Date()
            harness.coordinator.applyFocusDimming(in: harness.textView, theme: Theme())
            best = min(best, Date().timeIntervalSince(start))
        }
        XCTAssertLessThan(best, budget,
                          "focus-dim block move took \(best * 1000) ms per caret move")

        // Correctness: the caret's block keeps full ink; a neighbor in the
        // viewport is dimmed.
        let contentStorage = try XCTUnwrap(harness.textView.textContentStorage)
        let layoutManager = try XCTUnwrap(harness.textView.textLayoutManager)
        func renderingForeground(atCharIndex index: Int) -> Any? {
            guard let location = contentStorage.location(
                contentStorage.documentRange.location, offsetBy: index) else { return nil }
            var value: Any?
            layoutManager.enumerateRenderingAttributes(from: location, reverse: false) { _, attrs, range in
                // The enumeration can skip ahead to the next PAINTED run;
                // only a run containing the queried location counts.
                if range.contains(location) { value = attrs[.foregroundColor] }
                return false
            }
            return value
        }
        let caretBlock = try XCTUnwrap(harness.coordinator.blockID(atCharIndex: harness.textView.selectedRange().location))
        let caretRange = try XCTUnwrap(harness.coordinator.blockRanges[caretBlock])
        XCTAssertNil(renderingForeground(atCharIndex: caretRange.location + 1),
                     "the caret's block must not be dimmed")
        XCTAssertNotNil(renderingForeground(atCharIndex: locA),
                        "a visible non-caret block must be dimmed")
    }

    /// Sentence scope, caret moving between sentences of the SAME block —
    /// the pre-fix code repainted the whole document on every caret blink
    /// here (the dedupe was defeated by `|| sentenceScope`). The repaint
    /// must now be block-local.
    func testFocusDimmingSentenceMoveMeetsBudget() throws {
        let harness = try makeHarness(source: Self.bigSource, focusMode: true, sentenceScope: true)
        let text = harness.textView.textContentStorage!.textStorage!.string as NSString
        let first = text.range(of: "Paragraph 4 ").location
        let second = text.range(of: "Second sentence of paragraph 4").location
        XCTAssertNotEqual(first, NSNotFound)
        XCTAssertNotEqual(second, NSNotFound)

        var best = TimeInterval.greatestFiniteMagnitude
        for i in 0..<8 {
            harness.textView.setSelectedRange(NSRange(location: i % 2 == 0 ? first + 2 : second + 2, length: 0))
            let start = Date()
            harness.coordinator.applyFocusDimming(in: harness.textView, theme: Theme())
            best = min(best, Date().timeIntervalSince(start))
        }
        XCTAssertLessThan(best, budget,
                          "sentence-scope caret move took \(best * 1000) ms")

        // An unchanged caret is a pure no-op (the dedupe that was missing).
        var noopBest = TimeInterval.greatestFiniteMagnitude
        for _ in 0..<5 {
            let start = Date()
            harness.coordinator.applyFocusDimming(in: harness.textView, theme: Theme())
            noopBest = min(noopBest, Date().timeIntervalSince(start))
        }
        XCTAssertLessThan(noopBest, 0.005,
                          "unchanged caret must dedupe to a no-op, took \(noopBest * 1000) ms")
    }

    // MARK: Attribute sync (perf #8)

    /// The fallback-splice attribute sync across a document-scale
    /// projection. The pre-fix bridged walk measured ~55ms at this size
    /// (~110ms at 2×); the CF walk holds well under the budget with the
    /// same whole-document coverage (bounding it is unsound — see the
    /// LEDGER note in syncAttributesWhereDifferent).
    func testAttributeSyncSpliceMeetsBudget() throws {
        let document = MarkdownConverter.parse(Self.bigSource)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let a = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let b = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)

        var best = TimeInterval.greatestFiniteMagnitude
        for _ in 0..<4 {
            let storage = NSTextStorage()
            storage.setAttributedString(a.attributed)
            let start = Date()
            _ = MarkdownReaderView.Coordinator.spliceChanges(in: storage, to: b.attributed)
            best = min(best, Date().timeIntervalSince(start))
        }
        XCTAssertLessThan(best, budget,
                          "attribute-sync splice took \(best * 1000) ms per fallback splice")
    }

    // MARK: Block-range lookups (perf #11)

    /// Caret-path lookups: a burst of blockID(atCharIndex:) queries per
    /// budget window (every keystroke, click, caret move, and focus pass
    /// makes one). Includes the one-time lazy index rebuild. The pre-fix
    /// linear scan (full dictionary filter + max per query) was seconds
    /// at this scale.
    func testBlockIDLookupMeetsBudget() throws {
        var ranges: [BlockID: NSRange] = [:]
        for i in 0..<10_000 {
            // Adjacent ranges sharing a boundary character, like real
            // block ranges with trailing separators.
            ranges[BlockID(contentHash: i, occurrence: 0)] = NSRange(location: i * 10, length: 12)
        }
        let view = MarkdownReaderView(rendered: RenderedDocument(
            attributed: NSAttributedString(), blockRanges: [:]))
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.blockRanges = ranges

        let start = Date()
        var hits = 0
        for i in 0..<2_000 {
            if coordinator.blockID(atCharIndex: (i * 47) % 100_000) != nil { hits += 1 }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(hits, 1_800)
        XCTAssertLessThan(elapsed, budget,
                          "2k blockID lookups (incl. index build) took \(elapsed * 1000) ms")

        // Boundary semantics preserved: where two ranges overlap, the one
        // with the larger location wins (the historical tie-break).
        let boundary = try XCTUnwrap(coordinator.blockID(atCharIndex: 20))
        XCTAssertEqual(boundary, BlockID(contentHash: 2, occurrence: 0))
    }

    /// Scroll-path lookup: topVisibleBlockID per scroll tick. The pre-fix
    /// code allocated a description string PER KEY per tick.
    func testTopVisibleBlockIDMeetsBudget() throws {
        let harness = try makeHarness(source: Self.bigSource)
        harness.scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        harness.scroll.reflectScrolledClipView(harness.scroll.contentView)

        // Warm (lazy index build).
        XCTAssertNotNil(harness.coordinator.topVisibleBlockID(in: harness.textView))
        let start = Date()
        for _ in 0..<200 {
            _ = harness.coordinator.topVisibleBlockID(in: harness.textView)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, budget,
                          "200 topVisibleBlockID queries took \(elapsed * 1000) ms")
    }

    // MARK: Search (perf #5) — behavioral: the scan is debounced

    /// A query change must NOT rescan synchronously (the scan is
    /// debounced), and ⌘G ordinal cycling must recolor without any rescan
    /// — its match count reports synchronously from the cached matches.
    func testSearchScanIsDebouncedAndOrdinalCyclingNeverRescans() throws {
        var harness = try makeHarness(source: Self.bigSource)
        var reportedCounts: [Int] = []
        let view = MarkdownReaderView(
            rendered: harness.rendered,
            onMatchCount: { reportedCounts.append($0) }
        )
        harness.coordinator.parent = view

        // Direct scan primes the match state (this is what the debounce
        // fires; calling it directly keeps the test synchronous).
        harness.coordinator.performSearchScan(query: "Paragraph", activeOrdinal: 0)
        let scannedCount = try XCTUnwrap(reportedCounts.last)
        XCTAssertGreaterThan(scannedCount, 500)

        // Ordinal-only change (⌘G): synchronous, no rescan — the count
        // reports immediately from the cached matches.
        reportedCounts.removeAll()
        let start = Date()
        harness.coordinator.applySearch(query: "Paragraph", activeOrdinal: 1)
        let cycleElapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(reportedCounts.last, scannedCount,
                       "⌘G must report synchronously from cached matches")
        XCTAssertLessThan(cycleElapsed, 0.010,
                          "⌘G cycling took \(cycleElapsed * 1000) ms — smells like a rescan")

        // Query change: nothing synchronous happens (debounced).
        reportedCounts.removeAll()
        harness.coordinator.applySearch(query: "sentence", activeOrdinal: 0)
        XCTAssertTrue(reportedCounts.isEmpty,
                      "a query change must not scan synchronously")

        // The debounced scan lands with the new query's matches.
        let landed = expectation(description: "debounced scan")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + MarkdownReaderView.Coordinator.searchDebounceInterval + 0.08
        ) { landed.fulfill() }
        wait(for: [landed], timeout: 2)
        XCTAssertGreaterThan(try XCTUnwrap(reportedCounts.last), 500,
                             "the debounced scan must land with the new query's matches")
    }
}
#endif
