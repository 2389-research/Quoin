#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// The open block's mode chrome (embed-editing brief, Phase 2.2): the
/// revealed source of an EMBED carries an `editingFrame` decoration (accent
/// border + drawn ✓ done chip). Drawn, never a text run — the revealed
/// source must stay 1:1 with the file. Prose reveal stays chrome-free.
final class EditingFrameTests: XCTestCase {

    private func hasEditingFrame(_ attributed: NSAttributedString, in range: NSRange) -> Bool {
        var found = false
        attributed.enumerateAttribute(QuoinAttribute.blockDecoration, in: range) { value, _, stop in
            if let decoration = value as? BlockDecoration,
               case .editingFrame = decoration.kind {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    func testOpenEmbedCarriesTheEditingFrame() throws {
        let document = MarkdownConverter.parse("# T\n\n```swift\nlet a = 1\n```\n\nTail.\n")
        let block = try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let editing = renderer.render(document, activeBlockID: block.id, activeCaret: 0, cache: &cache)
        let active = try XCTUnwrap(editing.activeEditableRange)
        XCTAssertTrue(hasEditingFrame(editing.attributed, in: active),
                      "the open code block must carry the editing frame")
        // And the revealed text is still exactly the source slice — the
        // chrome added no characters.
        let slice = try XCTUnwrap(document.source.substring(in: block.range))
        XCTAssertEqual((editing.attributed.string as NSString).substring(with: active), slice,
                       "1:1 mapping is untouchable")
    }

    func testOpenProseCarriesNoFrame() throws {
        let document = MarkdownConverter.parse("First paragraph.\n\nSecond paragraph.\n")
        let block = try XCTUnwrap(document.blocks.last)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let editing = renderer.render(document, activeBlockID: block.id, activeCaret: 0, cache: &cache)
        let active = try XCTUnwrap(editing.activeEditableRange)
        XCTAssertFalse(hasEditingFrame(editing.attributed, in: active),
                       "prose reveal is the caret-quasimode — no chrome (brief principle 3)")
    }

    func testCaretMoveRestylePreservesTheFrame() throws {
        let document = MarkdownConverter.parse("# T\n\n```swift\nlet a = 1\nlet b = 2\n```\n\nTail.\n")
        let block = try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let editing = renderer.render(document, activeBlockID: block.id, activeCaret: 0, cache: &cache)
        let active = try XCTUnwrap(editing.activeEditableRange)

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let storage = try XCTUnwrap(textView.textContentStorage?.textStorage)
        storage.setAttributedString(editing.attributed)

        let view = MarkdownReaderView(
            rendered: RenderedDocument(
                attributed: editing.attributed, blockRanges: editing.blockRanges,
                activeBlockID: block.id, activeEditableRange: active,
                activeSourceText: editing.activeSourceText),
            onEditIntent: { _, _, _ in },
            onActivateBlock: { _, _, _ in }
        )
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView
        coordinator.blockRanges = editing.blockRanges

        // Move the caret inside the active block → span-level restyle runs.
        textView.setSelectedRange(NSRange(location: active.location + 12, length: 0))
        coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: textView))

        XCTAssertTrue(hasEditingFrame(storage, in: active),
                      "the restyle pass must not strip the editing frame")
    }
}
#endif
