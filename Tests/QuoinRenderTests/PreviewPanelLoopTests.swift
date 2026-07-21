#if canImport(AppKit)
import XCTest
import AppKit
import MermaidRender
import QuoinCore
@testable import QuoinRender

/// The live panel loop (ledger #6b follow-up): coordinator + panel view
/// driven through an open → break → fix editing session with the exact
/// projection/geometry choreography updateNSView performs. The panel's
/// IMAGE must track the projection at every step — the field report was
/// "a fixed node never re-renders again".
@MainActor
final class PreviewPanelLoopTests: XCTestCase {

    private func makeStack() -> (scroll: NSScrollView, textView: QuoinTextView) {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 0), textContainer: container)
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        scroll.documentView = textView
        return (scroll, textView)
    }

    private func panelImageView(in textView: NSTextView) -> NSImageView? {
        for sub in textView.subviews where String(describing: type(of: sub)).contains("PreviewPanelView") {
            return sub.subviews.compactMap { $0 as? NSImageView }.first
        }
        return nil
    }

    func testPanelTracksBreakThenFix() throws {
        let base = "# Doc\n\n```mermaid\nflowchart TD\n    A[Start] --> B[End]\n```\n\nTail.\n"
        let document = MarkdownConverter.parse(base)
        let block = try XCTUnwrap(document.blocks.first {
            if case .diagram = $0.kind { return true }
            return false
        })
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        // Held-preview retention is the caller's state (editor-modes 1.1) —
        // the test threads it across projections exactly as the model does.
        var held: AttributedRenderer.HeldPreview?

        func projection(_ doc: QuoinDocument, active: BlockID?) -> RenderedDocument {
            let next = renderer.render(
                doc, activeBlockID: active, activeCaret: 0, cache: &cache,
                heldPreview: &held)
            return RenderedDocument(
                attributed: next.attributed, blockRanges: next.blockRanges,
                activeBlockID: next.activeBlockID,
                activeEditableRange: next.activeEditableRange,
                activeSourceText: next.activeSourceText,
                previewPanel: active != nil ? AttributedRenderer.previewPanel(for: held) : nil)
        }

        let (_, textView) = makeStack()
        let storage = try XCTUnwrap(textView.textContentStorage?.textStorage)

        // 1. OPEN: active projection lands, frame geometry reported.
        let opened = projection(document, active: block.id)
        storage.setAttributedString(opened.attributed)
        var view = MarkdownReaderView(rendered: opened, onEditIntent: { _, _, _ in },
                                      onActivateBlock: { _, _, _ in })
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView
        coordinator.blockRanges = opened.blockRanges
        let frameBox = CGRect(x: 0, y: 40, width: 700, height: 200)
        coordinator.updatePreviewPanel(editingFrame: frameBox)
        let healthyImage = try XCTUnwrap(panelImageView(in: textView)?.image,
                                         "open must present the panel")

        // 2. BREAK the header (parse fails → held image, paused).
        let broken = base.replacingOccurrences(of: "flowchart TD", with: "@@@flowchart TD")
        let brokenDocument = MarkdownConverter.parse(broken)
        let brokenBlock = try XCTUnwrap(brokenDocument.blocks.first {
            if case .diagram = $0.kind { return true }
            return false
        })
        guard case .diagram(let payload, _) = brokenBlock.kind,
              MermaidRenderer.attachmentString(source: payload, theme: Theme().diagramTheme) == nil else {
            throw XCTSkip("fixture unexpectedly parses")
        }
        let pausedProjection = projection(brokenDocument, active: brokenBlock.id)
        _ = MarkdownReaderView.Coordinator.spliceChanges(in: storage, to: pausedProjection.attributed)
        view = MarkdownReaderView(rendered: pausedProjection, onEditIntent: { _, _, _ in },
                                  onActivateBlock: { _, _, _ in })
        coordinator.parent = view
        coordinator.blockRanges = pausedProjection.blockRanges
        coordinator.updatePreviewPanel(editingFrame: frameBox)
        XCTAssertTrue(panelImageView(in: textView)?.image === healthyImage,
                      "broken source holds the last good image")
        XCTAssertNotNil(pausedProjection.previewPanel?.statusMessage)

        // 3. FIX it back — the panel must show a FRESH image, healthy.
        let fixedProjection = projection(document, active: block.id)
        _ = MarkdownReaderView.Coordinator.spliceChanges(in: storage, to: fixedProjection.attributed)
        view = MarkdownReaderView(rendered: fixedProjection, onEditIntent: { _, _, _ in },
                                  onActivateBlock: { _, _, _ in })
        coordinator.parent = view
        coordinator.blockRanges = fixedProjection.blockRanges
        coordinator.updatePreviewPanel(editingFrame: frameBox)

        XCTAssertNil(fixedProjection.previewPanel?.statusMessage,
                     "fixed source is healthy — no paused note")
        // Good news is instant: the fixing render lands with the very
        // keystroke, no debounce, no waiting on any timer. (A held stale
        // image here is exactly the 'fixed chart never re-renders'
        // failure shape.)
        let fixedImage = try XCTUnwrap(panelImageView(in: textView)?.image)
        XCTAssertTrue(fixedImage === fixedProjection.previewPanel?.image,
                      "the panel view shows the projection's CURRENT image — " +
                      "'the fixed node never re-renders' was the field report")
    }
}
#endif
