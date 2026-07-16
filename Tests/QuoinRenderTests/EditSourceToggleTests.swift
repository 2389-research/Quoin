#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// ⌘↩ / Format ▸ Edit Source and the right-click items (embed-editing
/// brief, Phase 2.3): one toggle, two directions — open the block under
/// the caret, or commit-and-close the open one with the Escape-identical
/// caret restore.
final class EditSourceToggleTests: XCTestCase {

    private struct Harness {
        let coordinator: MarkdownReaderView.Coordinator
        let textView: QuoinTextView
        let document: QuoinDocument
        let activations: () -> [(BlockID?, CaretHint?)]
    }

    private func makeHarness(source: String, activeBlockID: BlockID? = nil, caret: Int? = nil) -> Harness {
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let result = renderer.render(document, activeBlockID: activeBlockID, activeCaret: caret, cache: &cache)

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.textContentStorage?.textStorage?.setAttributedString(result.attributed)

        final class Box { var activations: [(BlockID?, CaretHint?)] = [] }
        let box = Box()
        let view = MarkdownReaderView(
            rendered: RenderedDocument(
                attributed: result.attributed, blockRanges: result.blockRanges,
                activeBlockID: activeBlockID, activeEditableRange: result.activeEditableRange,
                activeSourceText: result.activeSourceText),
            onEditIntent: { _, _, _ in },
            onActivateBlock: { id, hint, _ in box.activations.append((id, hint)) },
            blockSourceProvider: { id in
                document.blocks.first { $0.id == id }
                    .flatMap { document.source.substring(in: $0.range) }
            }
        )
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView
        coordinator.blockRanges = result.blockRanges
        return Harness(coordinator: coordinator, textView: textView,
                       document: document, activations: { box.activations })
    }

    private let fixture = "# T\n\n```swift\nlet a = 1\nlet b = 2\n```\n\nTail.\n"

    private func codeBlock(in document: QuoinDocument) throws -> Block {
        try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
    }

    func testToggleOpensTheEmbedUnderTheCaret() throws {
        let harness = makeHarness(source: fixture)
        let storage = try XCTUnwrap(harness.textView.textContentStorage?.textStorage)
        let target = (storage.string as NSString).range(of: "let b").location
        harness.textView.setSelectedRange(NSRange(location: target, length: 0))

        harness.coordinator.toggleEditSource(in: harness.textView)

        let block = try codeBlock(in: harness.document)
        let activation = try XCTUnwrap(harness.activations().last)
        XCTAssertEqual(activation.0, block.id)
        // Caret hint is source-space and exact (the 1:1 body tag).
        let slice = try XCTUnwrap(harness.document.source.substring(in: block.range))
        XCTAssertEqual(activation.1, .source((slice as NSString).range(of: "let b").location))
    }

    func testToggleClosesTheOpenBlockWithCaretRestore() throws {
        let document = MarkdownConverter.parse(fixture)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let block = try codeBlock(in: document)
        _ = renderer.render(document, activeBlockID: block.id, activeCaret: 0, cache: &cache)

        let harness = makeHarness(source: fixture, activeBlockID: block.id, caret: 0)
        let active = try XCTUnwrap(harness.coordinator.parent.rendered.activeEditableRange)
        harness.textView.setSelectedRange(NSRange(location: active.location + 10, length: 0))

        harness.coordinator.toggleEditSource(in: harness.textView)

        let activation = try XCTUnwrap(harness.activations().last)
        XCTAssertNil(activation.0, "toggle on the open block deactivates")
        XCTAssertEqual(harness.coordinator.pendingDeactivationCaret?.sourceOffset, 10,
                       "…with the Escape-identical caret capture")
    }

    func testContextMenuOffersEditAndCopySourceOnEmbeds() throws {
        let harness = makeHarness(source: fixture)
        let storage = try XCTUnwrap(harness.textView.textContentStorage?.textStorage)
        let inside = (storage.string as NSString).range(of: "let a").location

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Standard Item", action: nil, keyEquivalent: ""))
        harness.coordinator.populateContextMenu(menu, atCharIndex: inside)

        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles.first, "Edit Source")
        XCTAssertTrue(titles.contains("Copy Markdown Source"))
        XCTAssertTrue(titles.contains("Standard Item"), "standard items stay below ours")

        // Copy Markdown Source carries the block's exact source slice.
        let copyItem = try XCTUnwrap(menu.items.first { $0.title == "Copy Markdown Source" })
        let block = try codeBlock(in: harness.document)
        XCTAssertEqual(copyItem.representedObject as? String,
                       harness.document.source.substring(in: block.range))
    }

    func testContextMenuOnProseOffersCopySourceOnly() throws {
        let harness = makeHarness(source: fixture)
        let storage = try XCTUnwrap(harness.textView.textContentStorage?.textStorage)
        let inside = (storage.string as NSString).range(of: "Tail").location

        let menu = NSMenu()
        harness.coordinator.populateContextMenu(menu, atCharIndex: inside)
        let titles = menu.items.map(\.title)
        XCTAssertFalse(titles.contains("Edit Source"),
                       "prose opens on click — no menu ceremony")
        XCTAssertTrue(titles.contains("Copy Markdown Source"))
    }
}
#endif
