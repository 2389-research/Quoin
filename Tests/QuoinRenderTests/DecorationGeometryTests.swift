#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Phase 2 of the editor-modes plan: ONE measure pass per draw produces the
/// geometry every chrome consumer reads. These tests pin the derivations —
/// border, ✓ chip, tooltip hit-target, and the accessibility element must
/// all come from the same measured box, so they can never disagree (the
/// independently-computed-geometry class of overlap bugs).
@MainActor
final class DecorationGeometryTests: XCTestCase {

    private func makeStack(source: String, activeBlockID: BlockID?, fullLayout: Bool = true) throws
    -> (textView: QuoinTextView, window: NSWindow, document: QuoinDocument) {
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let rendered = renderer.render(
            document, activeBlockID: activeBlockID, activeCaret: activeBlockID != nil ? 0 : nil,
            cache: &cache)

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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        textView.textContentStorage?.textStorage?.setAttributedString(rendered.attributed)
        if fullLayout {
            textView.textLayoutManager?.ensureLayout(
                for: try XCTUnwrap(textView.textContentStorage?.documentRange))
        } else {
            // Production's sequence: the pre-draw settle lays out the
            // VIEWPORT only (viewWillDraw → layoutViewport).
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
        textView.sizeToFit()
        return (textView, window, document)
    }

    private let fixture = "# Title\n\n```swift\nlet x = 1\nlet y = 2\n```\n\nTail paragraph.\n"

    func testChromeDerivesFromTheMeasuredBox() throws {
        let document = MarkdownConverter.parse(fixture)
        let code = try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        let (textView, window, _) = try makeStack(source: fixture, activeBlockID: code.id)
        defer { window.orderOut(nil) }

        textView.measureVisibleRuns()

        // Exactly one editingFrame run for the open block.
        let frameRuns = textView.measuredRuns.filter {
            if case .editingFrame = $0.decoration.kind { return true }
            return false
        }
        XCTAssertEqual(frameRuns.count, 1, "one open block → one editing frame")
        let frameRun = try XCTUnwrap(frameRuns.first)

        // Border, chip, and hit-target all from ONE box.
        let chrome = try XCTUnwrap(textView.editingChrome)
        XCTAssertEqual(chrome.borderRect, frameRun.box.insetBy(dx: -4, dy: -4))
        XCTAssertEqual(textView.doneChipRect, chrome.chipRect,
                       "the chip's hit-target IS the chrome's chip rect")
        // The chip sits inside the border's top-right.
        XCTAssertLessThanOrEqual(chrome.chipRect.maxX, chrome.borderRect.maxX)
        XCTAssertEqual(chrome.chipRect.minY, chrome.borderRect.minY + 5, accuracy: 0.5)
        // Full-width chrome spans the container from its own inset.
        XCTAssertEqual(frameRun.box.width,
                       600 - frameRun.decoration.leadingInset, accuracy: 1)
    }

    func testNoOpenBlockMeansNoChrome() throws {
        let (textView, window, _) = try makeStack(source: fixture, activeBlockID: nil)
        defer { window.orderOut(nil) }

        textView.measureVisibleRuns()

        XCTAssertNil(textView.editingChrome)
        XCTAssertNil(textView.doneChipRect)
        // The code canvas is still measured (it decorates the CLOSED block).
        XCTAssertTrue(textView.measuredRuns.contains {
            if case .codeCanvas = $0.decoration.kind { return true }
            return false
        })
    }

    func testDoneChipIsAPressableAccessibilityElement() throws {
        let document = MarkdownConverter.parse(fixture)
        let code = try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        let (textView, window, _) = try makeStack(source: fixture, activeBlockID: code.id)
        defer { window.orderOut(nil) }
        var pressed = false
        textView.onDoneChipClick = { pressed = true }

        textView.measureVisibleRuns()

        let buttons = (textView.accessibilityChildren() ?? []).compactMap { child -> NSAccessibilityElement? in
            guard let element = child as? NSAccessibilityElement,
                  element.accessibilityLabel() == "Done editing" else { return nil }
            return element
        }
        XCTAssertEqual(buttons.count, 1, "the ✓ done chip must be discoverable by VoiceOver")
        let button = try XCTUnwrap(buttons.first)
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertTrue(button.accessibilityPerformPress(), "the element must be pressable")
        XCTAssertTrue(pressed, "pressing routes to the same close path as a physical click")

        // Closed document exposes no such element.
        let (closedView, closedWindow, _) = try makeStack(source: fixture, activeBlockID: nil)
        defer { closedWindow.orderOut(nil) }
        closedView.measureVisibleRuns()
        let closedButtons = (closedView.accessibilityChildren() ?? []).filter {
            ($0 as? NSAccessibilityElement)?.accessibilityLabel() == "Done editing"
        }
        XCTAssertTrue(closedButtons.isEmpty)
    }

    /// The measure pass is viewport-scoped: decoration runs far outside the
    /// viewport(±slack) are not measured (TextKit 2's laziness preserved),
    /// while the run LIST still knows the document's decorations.
    func testMeasurePassIsViewportScoped() throws {
        var source = "# Top\n\n```swift\nlet near = 1\n```\n\n"
        for i in 0..<400 {
            source += "Paragraph \(i) with enough filler words to be a plausible line of prose in a long document.\n\n"
        }
        source += "```swift\nlet far = 2\n```\n\nTail.\n"
        let (textView, window, _) = try makeStack(
            source: source, activeBlockID: nil, fullLayout: false)
        defer { window.orderOut(nil) }

        textView.measureVisibleRuns()

        let canvases = textView.measuredRuns.filter {
            if case .codeCanvas = $0.decoration.kind { return true }
            return false
        }
        XCTAssertEqual(canvases.count, 1,
                       "only the near canvas is in the viewport; the far one must not be measured")
    }
}
#endif
