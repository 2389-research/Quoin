#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// The fold-straddling reveal: a link-heavy list mostly below the viewport,
/// clicked on a visible item. The revealed source wraps (URLs are long), the
/// splice's geometry starts as TextKit 2 ESTIMATES, and pinning against
/// those estimates let the list dive hundreds of points once real layout
/// settled. The pin must hold after settling — that's what the user sees.
final class LinkListFoldAnchorTests: XCTestCase {

    func testClickedListItemHoldsAfterGeometrySettles() throws {
        var source = "# Links\n\n"
        for i in 0..<24 { source += "Paragraph \(i) of filler prose to push the list toward the fold.\n\n" }
        source += (0..<10).map {
            "- [Reference item number \($0) with a name](https://example.com/some/very/long/path/segment/that/wraps/item-\($0)?tracking=verylongparameter)"
        }.joined(separator: "\n") + "\n\n"
        source += "Tail paragraph.\n"
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let list = try XCTUnwrap(document.blocks.first {
            if case .list = $0.kind { return true }
            return false
        })
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
        // Deliberately NO full layout: estimates stay live, like the real app.
        textView.frame.size.height = 3000

        let view = MarkdownReaderView(rendered: RenderedDocument(
            attributed: reading.attributed, blockRanges: reading.blockRanges))
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView

        // The list's first item near the viewport bottom (list below the fold).
        let listRange = try XCTUnwrap(reading.blockRanges[list.id])
        let item0 = (reading.attributed.string as NSString)
            .range(of: "Reference item number 0", options: [], range: listRange).location
        XCTAssertNotEqual(item0, NSNotFound)
        coordinator.scrollBlockTop(listRange, toScreenY: 330, in: textView, settle: false)
        let target = try XCTUnwrap(coordinator.lineScreenY(at: item0, in: textView))

        // Flip via activation patches; pin with the production path
        // (block-eager layout + settle pass).
        let base = RenderedDocument(attributed: reading.attributed, blockRanges: reading.blockRanges)
        let update = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: base, from: nil, to: list.id, caret: 2))
        for patch in update.storagePatches {
            _ = MarkdownReaderView.Coordinator.applyStoragePatch(in: storage, patch: patch)
        }
        let newListRange = try XCTUnwrap(update.blockRanges[list.id])
        let newItem0 = (storage.string as NSString)
            .range(of: "Reference item number 0", options: [], range: newListRange).location
        XCTAssertNotEqual(newItem0, NSNotFound)
        coordinator.pinCaretLine(at: newItem0, toScreenY: target, in: textView,
                                 ensuringLayoutOf: newListRange)

        // Force full geometry resolution (the worst-case settle), then let
        // the pin's settle pass fire.
        textView.textLayoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContentStorage?.documentRange))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        let settled = try XCTUnwrap(coordinator.lineScreenY(at: newItem0, in: textView))
        XCTAssertEqual(settled, target, accuracy: 2,
                       "clicked item drifted after geometry settled (target \(target), settled \(settled))")
    }
}
#endif
