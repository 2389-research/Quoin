#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// The flip-back caret contract (embed-editing brief, Phase 1.2): closing a
/// revealed block (Escape/⌘↩/Done) lands the caret at the RENDERED image of
/// its source position, rounded backward to visible content — never
/// unspecified (the pre-fix behavior: whatever the splice left selected),
/// never forward across the block separator into the next block.
final class ReverseCaretMappingTests: XCTestCase {

    private func makeCodeDocument() -> QuoinDocument {
        var source = "# Code\n\n```swift\n"
        for i in 0..<8 { source += "let line\(i) = \(i)\n" }
        source += "```\n\nTail paragraph.\n"
        return MarkdownConverter.parse(source)
    }

    private func codeBlock(in document: QuoinDocument) throws -> Block {
        try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
    }

    func testSourceCaretMapsToItsRenderedImage() throws {
        let document = makeCodeDocument()
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let block = try codeBlock(in: document)
        let slice = try XCTUnwrap(document.source.substring(in: block.range))
        let range = try XCTUnwrap(reading.blockRanges[block.id])

        let storage = NSTextStorage(attributedString: reading.attributed)
        let view = MarkdownReaderView(rendered: RenderedDocument(
            attributed: reading.attributed, blockRanges: reading.blockRanges))
        let coordinator = MarkdownReaderView.Coordinator(parent: view)

        // Caret sits at "line5" in the source; its rendered image is
        // "line5" in the read fragment (shifted by the header row) — the
        // embed body tag maps it exactly, the same 1:1 arithmetic
        // embedCaretHint uses on the way in.
        let sourceOffset = (slice as NSString).range(of: "let line5").location
        let location = coordinator.flipBackCaretLocation(
            blockRange: range, storage: storage,
            sourceOffset: sourceOffset, sourceText: slice
        )
        let renderedText = (reading.attributed.string as NSString).substring(with: range)
        let expected = range.location + (renderedText as NSString).range(of: "let line5").location
        XCTAssertEqual(location, expected,
                       "flip-back caret must land on the same line it left")
    }

    func testFenceLineCaretRoundsIntoTheBody() throws {
        // A caret on the opening fence (```swift) has no rendered image —
        // it rounds to the body start, never off into the header chrome or
        // a negative offset.
        let document = makeCodeDocument()
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let block = try codeBlock(in: document)
        let slice = try XCTUnwrap(document.source.substring(in: block.range))
        let range = try XCTUnwrap(reading.blockRanges[block.id])
        let storage = NSTextStorage(attributedString: reading.attributed)
        let view = MarkdownReaderView(rendered: RenderedDocument(
            attributed: reading.attributed, blockRanges: reading.blockRanges))
        let coordinator = MarkdownReaderView.Coordinator(parent: view)

        let location = coordinator.flipBackCaretLocation(
            blockRange: range, storage: storage, sourceOffset: 2, sourceText: slice)
        let renderedText = (reading.attributed.string as NSString).substring(with: range)
        let bodyStart = range.location + (renderedText as NSString).range(of: "let line0").location
        XCTAssertEqual(location, bodyStart)
    }

    func testEndOfSourceClampsToVisibleContent() throws {
        let document = makeCodeDocument()
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let block = try codeBlock(in: document)
        let slice = try XCTUnwrap(document.source.substring(in: block.range))
        let range = try XCTUnwrap(reading.blockRanges[block.id])
        let renderedText = (reading.attributed.string as NSString).substring(with: range)

        // Caret at the very end of the source (after the closing fence):
        // rounds BACKWARD to the last rendered content character — never
        // past the trailing separator into "Tail paragraph."
        let location = MarkdownReaderView.Coordinator.deactivationCaretLocation(
            blockRange: range, renderedText: renderedText,
            sourceOffset: slice.utf16.count, sourceText: slice
        )
        var contentEnd = (renderedText as NSString).length
        let ns = renderedText as NSString
        while contentEnd > 0, ns.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
        XCTAssertLessThanOrEqual(location, range.location + contentEnd)
        XCTAssertGreaterThan(location, range.location,
                             "end-of-source must not collapse to the block start")
    }

    func testProseCaretSurvivesRoundTrip() throws {
        // rendered→source (activation) then source→rendered (flip-back)
        // returns to the character the user was on.
        let source = "some **bold** words"
        let rendered = "some bold words"
        let renderedAfterBold = (rendered as NSString).range(of: " words").location
        let sourceCaret = EditMapping.sourceOffset(
            forRenderedOffset: renderedAfterBold, renderedText: rendered, sourceText: source)
        let back = MarkdownReaderView.Coordinator.deactivationCaretLocation(
            blockRange: NSRange(location: 0, length: rendered.utf16.count),
            renderedText: rendered, sourceOffset: sourceCaret, sourceText: source
        )
        XCTAssertEqual(back, renderedAfterBold, "round-trip must be stable")
    }

    func testEscapeCapturesDeactivationCaret() throws {
        let document = makeCodeDocument()
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let block = try codeBlock(in: document)
        let editing = renderer.render(document, activeBlockID: block.id, activeCaret: 12, cache: &cache)
        let active = try XCTUnwrap(editing.activeEditableRange)

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.textContentStorage?.textStorage?.setAttributedString(editing.attributed)

        final class Box { var deactivated = false }
        let box = Box()
        let view = MarkdownReaderView(
            rendered: RenderedDocument(
                attributed: editing.attributed, blockRanges: editing.blockRanges,
                activeBlockID: block.id, activeEditableRange: active,
                activeSourceText: editing.activeSourceText),
            onEditIntent: { _, _, _ in },
            onActivateBlock: { id, _, _ in if id == nil { box.deactivated = true } }
        )
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView
        coordinator.blockRanges = editing.blockRanges

        // Caret on the revealed source's 4th line, then Escape.
        let caretInSource = 40
        textView.setSelectedRange(NSRange(location: active.location + caretInSource, length: 0))
        let handled = coordinator.textView(
            textView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))

        XCTAssertTrue(handled)
        XCTAssertTrue(box.deactivated)
        let pending = try XCTUnwrap(coordinator.pendingDeactivationCaret)
        XCTAssertEqual(pending.id, block.id)
        XCTAssertEqual(pending.sourceOffset, caretInSource,
                       "the captured caret is relative to the block's source")
        XCTAssertEqual(pending.sourceText, editing.activeSourceText)
    }
}
#endif
