#if canImport(AppKit)
import XCTest
import AppKit
import MermaidRender
import QuoinCore
@testable import QuoinRender

/// The side-by-side live preview (embed-editing brief Phase 4, reshaped by
/// ledger #6b): while a mermaid/math block's source is open, the artifact
/// renders as a floating PANEL beside the source (exposed as
/// `RenderedDocument.previewPanel` / `activePreviewPanel()`), re-rendered
/// live as the source changes. The source fragment carries a matching tail
/// indent and stays character-for-character 1:1 with the file. Unparseable
/// mid-edit source keeps the last good image with a status message IN the
/// panel — the text flow's height never changes with validity.
final class PreviewAnchoredRevealTests: XCTestCase {

    private let source = """
    # Doc

    ```mermaid
    flowchart TD
        A[Start] --> B[End]
    ```

    Tail paragraph.
    """

    private func mermaidBlock(in document: QuoinDocument) throws -> Block {
        try XCTUnwrap(document.blocks.first {
            if case .mermaid = $0.kind { return true }
            return false
        })
    }

    func testOpenDiagramExposesAPanelAndAnIndentedSource() throws {
        let document = MarkdownConverter.parse(source)
        let block = try mermaidBlock(in: document)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let editing = renderer.render(document, activeBlockID: block.id, activeCaret: 0, cache: &cache)
        let active = try XCTUnwrap(editing.activeEditableRange)

        // The artifact never disappears: it rides beside the source.
        let panel = try XCTUnwrap(editing.previewPanel, "open diagram must expose its panel")
        XCTAssertNil(panel.statusMessage, "healthy source shows no status")
        XCTAssertGreaterThan(panel.image.size.width, 0)

        // The source is EXACTLY the slice (1:1), starting at the fragment
        // start (no stacked preview line anymore)…
        let slice = try XCTUnwrap(document.source.substring(in: block.range))
        XCTAssertEqual((editing.attributed.string as NSString).substring(with: active), slice)
        let blockRange = try XCTUnwrap(editing.blockRanges[block.id])
        XCTAssertEqual(active.location, blockRange.location,
                       "the panel lives outside the text flow")

        // …and wraps left of the panel.
        let style = try XCTUnwrap(editing.attributed.attribute(
            .paragraphStyle, at: active.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertLessThanOrEqual(
            style.tailIndent,
            -(AttributedRenderer.previewPanelWidth),
            "the source takes a tail indent to clear the panel")
    }

    func testReadingProjectionExposesNoPanel() throws {
        let rendered = AttributedRenderer().render(MarkdownConverter.parse(source))
        XCTAssertNil(rendered.previewPanel)
    }

    func testBrokenSourceHoldsTheLastGoodImageWithAStatus() throws {
        let document = MarkdownConverter.parse(source)
        let block = try mermaidBlock(in: document)
        let slice = try XCTUnwrap(document.source.substring(in: block.range))
        let renderer = AttributedRenderer()
        // Retention is the CALLER's state now (editor-modes plan 1.1): the
        // test threads its own held preview, exactly as the model does.
        var held: AttributedRenderer.HeldPreview?
        _ = renderer.renderEditableSourceFragment(
            slice, caretOffset: 0, block: block, document: document, heldPreview: &held)
        let healthyImage = try XCTUnwrap(AttributedRenderer.previewPanel(for: held)).image

        // One contiguous edit that breaks the parse, same session: mangle
        // the diagram-type header (the lenient parser skips mere garbage
        // LINES).
        let brokenSlice = slice.replacingOccurrences(of: "flowchart TD", with: "@@@flowchart TD")
        let brokenDocument = MarkdownConverter.parse("# Doc\n\n\(brokenSlice)\n\nTail.\n")
        let brokenBlock = try mermaidBlock(in: brokenDocument)
        guard case .mermaid(let payload) = brokenBlock.kind,
              MermaidRenderer.attachmentString(source: payload, theme: Theme().diagramTheme) == nil else {
            throw XCTSkip("fixture unexpectedly parses; paused path not exercised")
        }
        let revealed = renderer.renderEditableSourceFragment(
            brokenSlice, caretOffset: 0, block: brokenBlock, document: brokenDocument,
            heldPreview: &held)

        let panel = try XCTUnwrap(AttributedRenderer.previewPanel(for: held),
                                  "the last good render stays up — never blank")
        XCTAssertTrue(panel.image === healthyImage, "held image is the last GOOD one")
        XCTAssertNotNil(panel.statusMessage)
        XCTAssertTrue(try XCTUnwrap(panel.statusMessage).contains("paused"))
        // Editable source still 1:1 with the broken slice.
        XCTAssertEqual((revealed.attributed.string as NSString)
            .substring(with: revealed.editableRange), brokenSlice)
    }

    func testOpeningABrokenDiagramFreshShowsNoPanel() throws {
        let brokenSlice = "```mermaid\n<<<broken>>>\n```"
        let brokenDocument = MarkdownConverter.parse("# Doc\n\n\(brokenSlice)\n\nTail.\n")
        let brokenBlock = try mermaidBlock(in: brokenDocument)
        let renderer = AttributedRenderer()
        var held: AttributedRenderer.HeldPreview?
        _ = renderer.renderEditableSourceFragment(
            brokenSlice, caretOffset: 0, block: brokenBlock, document: brokenDocument,
            heldPreview: &held)
        XCTAssertNil(AttributedRenderer.previewPanel(for: held),
                     "no held render → plain source, same as before the feature")
    }

    func testUnchangedSourceReusesTheImageInstance() throws {
        let document = MarkdownConverter.parse(source)
        let block = try mermaidBlock(in: document)
        let slice = try XCTUnwrap(document.source.substring(in: block.range))
        let renderer = AttributedRenderer()

        var held: AttributedRenderer.HeldPreview?
        _ = renderer.renderEditableSourceFragment(
            slice, caretOffset: 0, block: block, document: document, heldPreview: &held)
        let first = try XCTUnwrap(AttributedRenderer.previewPanel(for: held)).image
        _ = renderer.renderEditableSourceFragment(
            slice, caretOffset: 20, block: block, document: document, heldPreview: &held)
        let second = try XCTUnwrap(AttributedRenderer.previewPanel(for: held)).image
        XCTAssertTrue(first === second,
                      "caret moves must not re-render the artifact")
    }

    /// Ledger #6a: mid-edit source like a half-typed `$$x^` stops parsing
    /// as a math block at all — the kind flaps to another kind for a
    /// keystroke. The held panel sticks through the flap (paused), and an
    /// unrelated slice never inherits it.
    func testPanelSticksThroughKindReclassification() throws {
        let mathSource = "# Doc\n\n$$x^2 + y^2 = z^2$$\n\nTail.\n"
        let document = MarkdownConverter.parse(mathSource)
        let block = try XCTUnwrap(document.blocks.first {
            if case .mathBlock = $0.kind { return true }
            return false
        })
        let slice = try XCTUnwrap(document.source.substring(in: block.range))
        let renderer = AttributedRenderer()
        var held: AttributedRenderer.HeldPreview?
        _ = renderer.renderEditableSourceFragment(
            slice, caretOffset: 0, block: block, document: document, heldPreview: &held)
        let primedImage = try XCTUnwrap(AttributedRenderer.previewPanel(for: held)).image

        // Delete the trailing `$` — one real keystroke; the kind flaps.
        let flappedSlice = String(slice.dropLast())
        let flappedDocument = MarkdownConverter.parse("# Doc\n\n\(flappedSlice)\n\nTail.\n")
        let flappedBlock = try XCTUnwrap(flappedDocument.blocks.first { candidate in
            if case .heading = candidate.kind { return false }
            return flappedDocument.source.substring(in: candidate.range)?
                .contains("x^2") == true
        })
        if case .mathBlock = flappedBlock.kind {
            throw XCTSkip("parser kept the unbalanced source a math block; flap not exercised")
        }
        let revealed = renderer.renderEditableSourceFragment(
            flappedSlice, caretOffset: 5, block: flappedBlock, document: flappedDocument,
            heldPreview: &held)

        let panel = try XCTUnwrap(AttributedRenderer.previewPanel(for: held),
                                  "the panel sticks through the flap")
        XCTAssertTrue(panel.image === primedImage)
        XCTAssertNotNil(panel.statusMessage, "the flap reads as paused, not gone")
        // The flapped fragment carries the editing frame (chrome sticks too).
        var hasFrame = false
        revealed.attributed.enumerateAttribute(
            QuoinAttribute.blockDecoration,
            in: NSRange(location: 0, length: revealed.attributed.length)
        ) { value, _, stop in
            if let decoration = value as? BlockDecoration,
               case .editingFrame = decoration.kind { hasFrame = true; stop.pointee = true }
        }
        XCTAssertTrue(hasFrame)

        // Unrelated content never inherits the held panel: the model resets
        // its held state on activation of a different block.
        held = nil
        _ = renderer.renderEditableSourceFragment(
            "A completely different paragraph.", caretOffset: 0, block: nil, document: nil,
            heldPreview: &held)
        XCTAssertNil(AttributedRenderer.previewPanel(for: held))
    }

    func testMathBlockGetsAPanelToo() throws {
        let mathSource = "# Doc\n\n$$x^2 + y^2 = z^2$$\n\nTail.\n"
        let document = MarkdownConverter.parse(mathSource)
        let block = try XCTUnwrap(document.blocks.first {
            if case .mathBlock = $0.kind { return true }
            return false
        })
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let editing = renderer.render(document, activeBlockID: block.id, activeCaret: 0, cache: &cache)
        XCTAssertNotNil(editing.previewPanel)
    }
}
#endif
