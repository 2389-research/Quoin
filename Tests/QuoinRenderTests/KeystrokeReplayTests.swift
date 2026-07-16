#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// The swallowed-keystroke contract (embed-editing brief, Phase 1.1):
/// typing on a rendered block must activate it AND deliver the keystroke —
/// `shouldChangeTextIn` forwards the replacement string alongside the
/// activation so the model can insert it at the mapped caret. Before this,
/// the flip looked like feedback but the character was silently dropped —
/// the editor's worst mode error.
final class KeystrokeReplayTests: XCTestCase {

    private struct Activation {
        let id: BlockID?
        let hint: CaretHint?
        let insertion: String?
    }

    /// A rendered projection in a real text view, with the activation
    /// callback captured.
    private func makeHarness(
        source: String
    ) throws -> (coordinator: MarkdownReaderView.Coordinator,
                 textView: QuoinTextView,
                 document: QuoinDocument,
                 activations: () -> [Activation]) {
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

        final class Box { var activations: [Activation] = [] }
        let box = Box()
        let view = MarkdownReaderView(
            rendered: RenderedDocument(
                attributed: reading.attributed, blockRanges: reading.blockRanges),
            onEditIntent: { _, _, _ in },
            onActivateBlock: { id, hint, insertion in
                box.activations.append(Activation(id: id, hint: hint, insertion: insertion))
            }
        )
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView
        coordinator.blockRanges = reading.blockRanges
        return (coordinator, textView, document, { box.activations })
    }

    private func codeBlock(in document: QuoinDocument) throws -> Block {
        try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
    }

    func testTypingOnRenderedCodeBlockActivatesWithSourceHintAndInsertion() throws {
        var source = "# Code\n\n```swift\n"
        for i in 0..<8 { source += "let line\(i) = \(i)\n" }
        source += "```\n\nTail.\n"
        let (coordinator, textView, document, activations) = try makeHarness(source: source)

        // Type "x" with the caret parked on rendered "line5".
        let storage = try XCTUnwrap(textView.textContentStorage?.textStorage)
        let target = (storage.string as NSString).range(of: "let line5").location
        XCTAssertNotEqual(target, NSNotFound)
        _ = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: target, length: 0),
            replacementString: "x"
        )

        let activation = try XCTUnwrap(activations().last)
        let block = try codeBlock(in: document)
        XCTAssertEqual(activation.id, block.id, "the code block must activate")
        XCTAssertEqual(activation.insertion, "x", "the keystroke must be forwarded, not dropped")

        // The hint must be a SOURCE-space offset pointing exactly at
        // "let line5" in the slice — the double-mapping bug fed source
        // offsets back through the rendered→source mapper and landed the
        // caret early by the header run's width.
        let slice = try XCTUnwrap(document.source.substring(in: block.range))
        let expected = (slice as NSString).range(of: "let line5").location
        XCTAssertEqual(activation.hint, .source(expected),
                       "embed hints are source-space and exact")
    }

    func testTypingOnRenderedProseForwardsRenderedHintAndInsertion() throws {
        let source = "First paragraph here.\n\nSecond **bold** paragraph.\n"
        let (coordinator, textView, document, activations) = try makeHarness(source: source)

        let storage = try XCTUnwrap(textView.textContentStorage?.textStorage)
        let target = (storage.string as NSString).range(of: "bold").location
        XCTAssertNotEqual(target, NSNotFound)
        _ = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: target, length: 0),
            replacementString: "y"
        )

        let activation = try XCTUnwrap(activations().last)
        let second = try XCTUnwrap(document.blocks.last)
        XCTAssertEqual(activation.id, second.id)
        XCTAssertEqual(activation.insertion, "y")
        guard case .rendered = activation.hint else {
            return XCTFail("prose hints stay rendered-space, got \(String(describing: activation.hint))")
        }
    }

    func testDeleteOnRenderedBlockActivatesWithoutInsertion() throws {
        let source = "One paragraph.\n\nAnother paragraph.\n"
        let (coordinator, textView, _, activations) = try makeHarness(source: source)

        // Backspace maps to a length-1 replacement with an empty string —
        // its extent has no defined image in the hidden source, so it
        // activates only.
        _ = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 3, length: 1),
            replacementString: ""
        )
        let activation = try XCTUnwrap(activations().last)
        XCTAssertNotNil(activation.id)
        XCTAssertNil(activation.insertion, "deletes must not replay as insertions")
    }

    func testNewlineReplayIsForwarded() throws {
        let source = "One paragraph.\n\nAnother paragraph.\n"
        let (coordinator, textView, _, activations) = try makeHarness(source: source)
        _ = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: 3, length: 0),
            replacementString: "\n"
        )
        XCTAssertEqual(try XCTUnwrap(activations().last).insertion, "\n")
    }

    /// The model-side replay recipe, tested through the same public APIs
    /// `ReaderModel.replayPendingInsertion` composes: caret (UTF-16, source
    /// space) → UTF-8 byte offset → `SourceEdit` insertion → caret after
    /// the insertion. Guards the arithmetic without needing the app target.
    func testReplayRecipeInsertsAtMappedCaret() throws {
        let slice = "```swift\nlet café = 1\n```"
        let caretUTF16 = (slice as NSString).range(of: " = 1").location // after "café"
        let caretBytes = try XCTUnwrap(EditMapping.utf8Offset(inText: slice, utf16Offset: caretUTF16))
        let edit = SourceEdit(range: ByteRange(offset: caretBytes, length: 0), replacement: "x")
        let (result, _) = try edit.apply(to: slice)
        XCTAssertEqual(result, "```swift\nlet caféx = 1\n```")
        // Caret lands after the insertion: same rule applyEdit uses.
        let after = caretBytes + "x".utf8.count
        XCTAssertEqual(EditMapping.utf16Offset(inText: result, utf8Offset: after), caretUTF16 + 1)
    }
}
#endif
