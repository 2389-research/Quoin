#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// The `‹/› edit` affordance (embed-editing brief, Phase 2.1): every embed
/// kind renders a quiet edit chip linked to quoin-edit://, following the
/// `⧉ copy` idiom. Clicking it opens the block's source; on the open block
/// the same URL commits and closes.
final class EditChipTests: XCTestCase {

    private func render(_ source: String) -> (QuoinDocument, RenderedDocument) {
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let result = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        return (document, result)
    }

    private func editRuns(in attributed: NSAttributedString) -> [NSRange] {
        var runs: [NSRange] = []
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let url = value as? URL, QuoinLink.isEditURL(url) {
                runs.append(range)
            }
        }
        return runs
    }

    func testEveryEmbedKindCarriesAnEditChip() {
        let source = """
        ---
        title: Chips
        ---

        # Chips

        ```swift
        let a = 1
        ```

        ```mermaid
        flowchart TD
            A --> B
        ```

        $$x^2 + y^2 = z^2$$

        | H1 | H2 |
        |----|----|
        | a  | b  |

        <div>html</div>
        """
        let (_, result) = render(source)
        let runs = editRuns(in: result.attributed)
        // front matter, swift code, mermaid, math, table, html block.
        XCTAssertEqual(runs.count, 6, "one edit chip per embed: \(runs)")
        // Every chip is labeled with the ‹/› source glyph.
        let text = result.attributed.string as NSString
        for run in runs {
            XCTAssertTrue(text.substring(with: run).contains("‹/›"),
                          "chip text must promise source, got '\(text.substring(with: run))'")
        }
    }

    func testProseCarriesNoEditChip() {
        let (_, result) = render("Just a paragraph with **bold** text.\n\n- a list\n- of items\n")
        XCTAssertTrue(editRuns(in: result.attributed).isEmpty,
                      "no affordance chrome on prose (brief principle 3)")
    }

    func testEditChipClickActivatesTheBlockAtItsBodyStart() throws {
        let (document, result) = render("# T\n\n```swift\nlet a = 1\nlet b = 2\n```\n")
        let block = try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.textContentStorage?.textStorage?.setAttributedString(result.attributed)

        final class Box { var received: (BlockID?, CaretHint?)? }
        let box = Box()
        let view = MarkdownReaderView(
            rendered: RenderedDocument(
                attributed: result.attributed, blockRanges: result.blockRanges),
            onEditIntent: { _, _, _ in },
            onActivateBlock: { id, hint, _ in box.received = (id, hint) }
        )
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView
        coordinator.blockRanges = result.blockRanges

        let chipRange = try XCTUnwrap(editRuns(in: result.attributed).first)
        let url = try XCTUnwrap(QuoinLink.editURL)
        let handled = coordinator.textView(textView, clickedOnLink: url, at: chipRange.location)
        XCTAssertTrue(handled)
        let received = try XCTUnwrap(box.received)
        XCTAssertEqual(received.0, block.id)
        // Chip sits outside the 1:1 body, so the hint rounds to the body
        // start — source offset of the first code character.
        let slice = try XCTUnwrap(document.source.substring(in: block.range))
        let bodyStart = (slice as NSString).range(of: "let a").location
        XCTAssertEqual(received.1, .source(bodyStart))
    }

    func testEditURLOnActiveBlockRequestsDeactivation() throws {
        let (document, _) = render("# T\n\n```swift\nlet a = 1\n```\n")
        let block = try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let editing = renderer.render(document, activeBlockID: block.id, activeCaret: 0, cache: &cache)

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
                activeBlockID: block.id, activeEditableRange: editing.activeEditableRange,
                activeSourceText: editing.activeSourceText),
            onEditIntent: { _, _, _ in },
            onActivateBlock: { id, _, _ in if id == nil { box.deactivated = true } }
        )
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView
        coordinator.blockRanges = editing.blockRanges

        let active = try XCTUnwrap(editing.activeEditableRange)
        let url = try XCTUnwrap(QuoinLink.editURL)
        let handled = coordinator.textView(textView, clickedOnLink: url, at: active.location)
        XCTAssertTrue(handled)
        XCTAssertTrue(box.deactivated, "the edit URL toggles: open block → commit and close")
        XCTAssertNotNil(coordinator.pendingDeactivationCaret,
                        "closing via the chip restores the caret like Escape does")
    }
}
#endif
