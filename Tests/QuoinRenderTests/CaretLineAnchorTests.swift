#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// THE viewport invariant, generalized: on any activate/deactivate flip,
/// the LINE THE CARET IS ON stays exactly where the user was looking —
/// whatever happens to the block's height around it (tables gain their
/// delimiter row on reveal; embeds swap attachments for source). "The user
/// should not be surprised."
final class CaretLineAnchorTests: XCTestCase {

    func testCaretLineStaysPutAcrossTableReveal() throws {
        var source = "# Anchor\n\n"
        for i in 0..<30 { source += "Paragraph \(i) of filler prose to make the document scroll.\n\n" }
        source += "| Name | Value |\n|------|------:|\n| alpha | 1 |\n| beta | 22 |\n| gamma | 333 |\n\n"
        for i in 30..<60 { source += "Paragraph \(i) of filler prose below the table.\n\n" }
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let table = try XCTUnwrap(document.blocks.first {
            if case .table = $0.kind { return true }
            return false
        })

        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)

        // Real TextKit stack in a scrollable viewport.
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
        let storage = try XCTUnwrap(textView.textContentStorage?.textStorage)
        storage.setAttributedString(reading.attributed)
        textView.textLayoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContentStorage?.documentRange))
        textView.sizeToFit()

        let view = MarkdownReaderView(rendered: RenderedDocument(
            attributed: reading.attributed, blockRanges: reading.blockRanges))
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView

        // "Click" a middle table row: caret on the beta row, scrolled into view.
        let tableRange = try XCTUnwrap(reading.blockRanges[table.id])
        let betaOffset = (reading.attributed.string as NSString)
            .range(of: "beta", options: [], range: tableRange).location
        XCTAssertNotEqual(betaOffset, NSNotFound)
        coordinator.scrollBlockTop(tableRange, toScreenY: 120, in: textView)
        let before = try XCTUnwrap(coordinator.lineScreenY(at: betaOffset, in: textView))

        // The flip (activation patches) lands, then the caret pin — exactly
        // what updateNSView does.
        let base = RenderedDocument(attributed: reading.attributed, blockRanges: reading.blockRanges)
        let update = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: base, from: nil, to: table.id, caret: nil))
        for patch in update.storagePatches {
            _ = MarkdownReaderView.Coordinator.applyStoragePatch(in: storage, patch: patch)
        }
        // The caret's storage position after the flip: same row, found in
        // the revealed source.
        let newTableRange = try XCTUnwrap(update.blockRanges[table.id])
        let newBeta = (storage.string as NSString)
            .range(of: "beta", options: [], range: newTableRange).location
        XCTAssertNotEqual(newBeta, NSNotFound)
        coordinator.pinCaretLine(at: newBeta, toScreenY: before, in: textView)

        let after = try XCTUnwrap(coordinator.lineScreenY(at: newBeta, in: textView))
        XCTAssertEqual(after, before, accuracy: 2,
                       "the clicked table row must stay where the user was looking (was \(before), now \(after))")
    }

    /// Phase 0.2 guard (editor-modes plan): above 200k chars the production
    /// path skips eager whole-document layout, so the pre-draw viewport
    /// settle (`viewWillDraw` → `layoutViewport`) is what resolves estimated
    /// heights — and it runs AFTER `pinCaretLine`. Resolving estimates above
    /// the caret must not move the pinned line, or the settle itself violates
    /// the viewport invariant on large documents.
    func testCaretPinSurvivesSettleOnHugeDocument() throws {
        var source = "# Huge\n\n"
        for i in 0..<2000 {
            source += "Paragraph \(i) with enough filler words to be a plausible line of prose in a very long document.\n\n"
        }
        source += "```swift\nlet marker = 42\nlet second = 43\n```\n\n"
        for i in 2000..<2500 {
            source += "Paragraph \(i) below the code block, more filler prose.\n\n"
        }
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        XCTAssertGreaterThan(reading.attributed.length, 200_000,
                             "fixture must exceed the eager-layout cutoff")
        let code = try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })

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
        let storage = try XCTUnwrap(textView.textContentStorage?.textStorage)
        storage.setAttributedString(reading.attributed)
        // Deliberately NO whole-document ensureLayout — mirror the >200k
        // production path, where heights beyond the viewport stay estimated.
        textView.sizeToFit()

        let view = MarkdownReaderView(rendered: RenderedDocument(
            attributed: reading.attributed, blockRanges: reading.blockRanges))
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView

        // Scroll the code block into view and put the "caret" on its marker.
        let codeRange = try XCTUnwrap(reading.blockRanges[code.id])
        coordinator.scrollBlockTop(codeRange, toScreenY: 120, in: textView)
        let markerOffset = (storage.string as NSString)
            .range(of: "marker", options: [], range: codeRange).location
        XCTAssertNotEqual(markerOffset, NSNotFound)
        let before = try XCTUnwrap(coordinator.lineScreenY(at: markerOffset, in: textView))

        // Activate the block (flip patches), then pin — what updateNSView does.
        let base = RenderedDocument(attributed: reading.attributed, blockRanges: reading.blockRanges)
        let update = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: base, from: nil, to: code.id, caret: nil))
        for patch in update.storagePatches {
            _ = MarkdownReaderView.Coordinator.applyStoragePatch(in: storage, patch: patch)
        }
        let newRange = try XCTUnwrap(update.blockRanges[code.id])
        let newMarker = (storage.string as NSString)
            .range(of: "marker", options: [], range: newRange).location
        XCTAssertNotEqual(newMarker, NSNotFound)
        // Production restores the caret before pinning — the settle's
        // caret-line guard keys off the view's selection.
        textView.setSelectedRange(NSRange(location: newMarker, length: 0))
        coordinator.pinCaretLine(at: newMarker, toScreenY: before, in: textView,
                                 ensuringLayoutOf: newRange)

        let pinned = try XCTUnwrap(coordinator.lineScreenY(at: newMarker, in: textView))

        // The settle that every draw now runs (viewWillDraw → layoutViewport):
        // resolving estimated heights elsewhere must not move the pinned line.
        textView.viewWillDraw()

        let after = try XCTUnwrap(coordinator.lineScreenY(at: newMarker, in: textView))
        XCTAssertEqual(after, pinned, accuracy: 2,
                       "the pre-draw settle must not move the pinned caret line (pinned \(pinned), after settle \(after))")
    }

    func testScrollCaretIntoViewIsNoOpWhenVisible() throws {
        var source = "# Visible\n\n"
        for i in 0..<50 { source += "Paragraph \(i) of filler prose to make the document scroll.\n\n" }
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
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = textView
        textView.textContentStorage?.textStorage?.setAttributedString(reading.attributed)
        textView.textLayoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContentStorage?.documentRange))
        textView.sizeToFit()

        let view = MarkdownReaderView(rendered: RenderedDocument(
            attributed: reading.attributed, blockRanges: reading.blockRanges))
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView

        // Scroll somewhere; pick a caret location mid-viewport.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        let originBefore = scroll.contentView.bounds.origin.y
        let mid = (reading.attributed.string as NSString).range(of: "Paragraph 20").location
        XCTAssertNotNil(coordinator.lineScreenY(at: mid, in: textView))
        // A caret already on screen must not move the viewport at all.
        if let y = coordinator.lineScreenY(at: mid, in: textView), y >= 8, y <= 392 {
            coordinator.scrollCaretIntoViewIfNeeded(mid, in: textView)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, originBefore, accuracy: 0.5,
                           "visible caret must not scroll the viewport")
        }
        // A caret far below the fold scrolls minimally (bottom-aligned).
        let deep = (reading.attributed.string as NSString).range(of: "Paragraph 45").location
        coordinator.scrollCaretIntoViewIfNeeded(deep, in: textView)
        let after = try XCTUnwrap(coordinator.lineScreenY(at: deep, in: textView))
        XCTAssertGreaterThan(after, 0)
        XCTAssertLessThan(after, 400, "off-screen caret must come into view")
    }

    // MARK: - Width-reflow anchoring (#65)

    /// Shared harness: long document in a 600pt scroll view, scrolled to
    /// paragraph 400. Returns (textView, coordinator, storage offset of
    /// paragraph 400).
    private func widthHarness() throws -> (QuoinTextView, MarkdownReaderView.Coordinator, Int) {
        var source = "# Wide\n\n"
        for i in 0..<800 {
            source += "Paragraph \(i) with enough filler words to wrap once or twice at six hundred points and differently at narrower widths.\n\n"
        }
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
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = textView
        let storage = try XCTUnwrap(textView.textContentStorage?.textStorage)
        storage.setAttributedString(reading.attributed)
        textView.sizeToFit()

        let view = MarkdownReaderView(rendered: RenderedDocument(
            attributed: reading.attributed, blockRanges: reading.blockRanges))
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView

        let target = (storage.string as NSString).range(of: "Paragraph 400 ").location
        XCTAssertNotEqual(target, NSNotFound)
        coordinator.scrollBlockTop(NSRange(location: target, length: 10), toScreenY: 120, in: textView)
        textView.viewWillDraw() // settled baseline
        return (textView, coordinator, target)
    }

    func testWidthChangePreservesTheCaretLine() throws {
        let (textView, coordinator, target) = try widthHarness()
        textView.setSelectedRange(NSRange(location: target, length: 0))
        let before = try XCTUnwrap(coordinator.lineScreenY(at: target, in: textView))

        // The sidebar-close / resize-end shape: one width commit, then draw.
        textView.setFrameSize(NSSize(width: 440, height: textView.frame.height))
        textView.viewWillDraw()

        let after = try XCTUnwrap(coordinator.lineScreenY(at: target, in: textView))
        XCTAssertEqual(after, before, accuracy: 2,
                       "the caret line must hold through a width reflow (\(before) → \(after))")
    }

    func testWidthChangePreservesTheTopVisibleLineWithoutACaret() throws {
        let (textView, coordinator, target) = try widthHarness()
        // Reading mode: the selection is far away (offscreen above).
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let before = try XCTUnwrap(coordinator.lineScreenY(at: target, in: textView))

        textView.setFrameSize(NSSize(width: 460, height: textView.frame.height))
        textView.viewWillDraw()

        let after = try XCTUnwrap(coordinator.lineScreenY(at: target, in: textView))
        // The anchor is the top VISIBLE fragment (some paragraph above the
        // target); rewrap growth between anchor and target allows small
        // drift — "content stays put", not pixel identity for every line.
        XCTAssertEqual(after, before, accuracy: 24,
                       "top-anchored width reflow must not scroll content away (\(before) → \(after))")
        // And repeated toggling (sidebar animation shape) stays bounded.
        for width in [520, 600] {
            textView.setFrameSize(NSSize(width: CGFloat(width), height: textView.frame.height))
            textView.viewWillDraw()
        }
        let round = try XCTUnwrap(coordinator.lineScreenY(at: target, in: textView))
        XCTAssertEqual(round, before, accuracy: 30,
                       "round-trip widths must return content home (\(before) → \(round))")
    }

}
#endif

#if canImport(AppKit)
/// Double-clicking INSIDE a code block's body must land the caret at the
/// clicked position, not the content start — the rendered body is 1:1 with
/// the source content. The old content-start shortcut teleported the caret
/// to the block's first line, and the caret-line pin then dragged that
/// first line down to the click (traced live at ~500pt in long blocks).
final class EmbedCaretHintTests: XCTestCase {
    func testDoubleClickMapsIntoCodeBody() throws {
        var source = "# Code\n\n"
        source += "```swift\n"
        for i in 0..<12 { source += "let line\(i) = \(i) // padding line \(i)\n" }
        source += "```\n\nTail.\n"
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.textContentStorage?.textStorage?.setAttributedString(reading.attributed)

        let view = MarkdownReaderView(rendered: RenderedDocument(
            attributed: reading.attributed, blockRanges: reading.blockRanges))
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView
        coordinator.blockRanges = reading.blockRanges

        // "Double-click" on line 8 of the rendered body.
        let storage = try XCTUnwrap(textView.textContentStorage?.textStorage)
        let clickTarget = (storage.string as NSString).range(of: "let line8").location
        XCTAssertNotEqual(clickTarget, NSNotFound)
        let hint = try XCTUnwrap(coordinator.embedCaretHint(atCharIndex: clickTarget))

        // The hint is a UTF-16 offset into the block's SOURCE slice; it must
        // point at "let line8" there, not at the content start.
        let code = try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        let slice = try XCTUnwrap(document.source.substring(in: code.range))
        let expected = (slice as NSString).range(of: "let line8").location
        XCTAssertEqual(hint, expected, "double-click must map into the clicked line")
    }
}
#endif
