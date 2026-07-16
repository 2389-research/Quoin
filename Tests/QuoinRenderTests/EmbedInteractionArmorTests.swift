#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Regression armor for embed-editing invariants nothing in the type system
/// protects (embed-editing brief, Phase 1.4). Each of these guards a
/// contract that was violated (or nearly so) in a shipped build.
final class EmbedInteractionArmorTests: XCTestCase {

    private func makeDocument() -> QuoinDocument {
        MarkdownConverter.parse("""
        # Armor

        ```swift
        let a = 1
        let b = 2
        ```

        Tail paragraph with words.
        """)
    }

    private func codeBlock(in document: QuoinDocument) throws -> Block {
        try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
    }

    private func makeTextView(_ attributed: NSAttributedString) -> QuoinTextView {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.textContentStorage?.textStorage?.setAttributedString(attributed)
        return textView
    }

    /// Double-click on an ALREADY-OPEN embed must fall through to AppKit's
    /// word-select — the `id != activeBlockID` gate. Re-activating would
    /// replace the text mid-gesture and the tracking loop would select
    /// random source (a shipped bug when the gate applied only to closed
    /// blocks).
    func testDoubleClickOnActiveEmbedFallsThroughToWordSelect() throws {
        let document = makeDocument()
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let block = try codeBlock(in: document)
        let editing = renderer.render(document, activeBlockID: block.id, activeCaret: 0, cache: &cache)
        let textView = makeTextView(editing.attributed)

        final class Box { var activations = 0 }
        let box = Box()
        let view = MarkdownReaderView(
            rendered: RenderedDocument(
                attributed: editing.attributed, blockRanges: editing.blockRanges,
                activeBlockID: block.id, activeEditableRange: editing.activeEditableRange,
                activeSourceText: editing.activeSourceText),
            onEditIntent: { _, _, _ in },
            onActivateBlock: { _, _, _ in box.activations += 1 }
        )
        let coordinator = MarkdownReaderView.Coordinator(parent: view)
        coordinator.textView = textView
        coordinator.blockRanges = editing.blockRanges

        let active = try XCTUnwrap(editing.activeEditableRange)
        let inside = active.location + min(6, max(0, active.length - 1))
        XCTAssertFalse(coordinator.activateEmbedBlock(atCharIndex: inside),
                       "double-click on the open block must not consume the gesture")
        XCTAssertEqual(box.activations, 0, "and must not re-activate")
    }

    // MARK: Selection through a projection change

    private typealias C = MarkdownReaderView.Coordinator

    func testSelectionClearOfTheChangeSurvives() {
        let survived = C.collapsedSelection(
            NSRange(location: 10, length: 5),
            changedOldRange: NSRange(location: 100, length: 40),
            newLength: 200
        )
        XCTAssertNil(survived, "a selection clear of the change keeps its range")
    }

    func testSelectionStraddlingAPatchCollapsesToItsStart() {
        let collapsed = C.collapsedSelection(
            NSRange(location: 30, length: 20),
            changedOldRange: NSRange(location: 40, length: 100),
            newLength: 80
        )
        XCTAssertEqual(collapsed, NSRange(location: 30, length: 0))
    }

    func testSelectionCollapsesOnFullReplacement() {
        let changed = C.changedOldRange(for: .spliced(nil), oldLength: 150, newLength: 90)
        XCTAssertEqual(changed, NSRange(location: 0, length: 150))
        let collapsed = C.collapsedSelection(
            NSRange(location: 120, length: 10), changedOldRange: changed, newLength: 90)
        XCTAssertEqual(collapsed, NSRange(location: 90, length: 0),
                       "collapse clamps into the new length")
    }

    func testInsertionInsideSelectionCollapses() {
        let collapsed = C.collapsedSelection(
            NSRange(location: 10, length: 10),
            changedOldRange: NSRange(location: 15, length: 0),
            newLength: 100
        )
        XCTAssertEqual(collapsed, NSRange(location: 10, length: 0))
    }

    func testInsertionAtSelectionBoundaryDoesNotCollapse() {
        XCTAssertNil(C.collapsedSelection(
            NSRange(location: 10, length: 10),
            changedOldRange: NSRange(location: 20, length: 0),
            newLength: 100
        ))
    }

    func testCaretNeverCollapses() {
        XCTAssertNil(C.collapsedSelection(
            NSRange(location: 42, length: 0),
            changedOldRange: NSRange(location: 0, length: 500),
            newLength: 300
        ))
    }

    func testSpliceChangedRangeRecoversOldExtent() {
        // Old text 100 long; splice reported new range (20, 8) in text now
        // 96 long → old extent was (20, 12).
        let changed = C.changedOldRange(
            for: .spliced(NSRange(location: 20, length: 8)), oldLength: 100, newLength: 96)
        XCTAssertEqual(changed, NSRange(location: 20, length: 12))
    }

    func testPatchedChangedRangeIsTheUnionOfOldRanges() {
        let patches = [
            RenderStoragePatch(oldRange: NSRange(location: 50, length: 10),
                               replacement: NSAttributedString(string: "x")),
            RenderStoragePatch(oldRange: NSRange(location: 10, length: 5),
                               replacement: NSAttributedString(string: "yy")),
        ]
        let changed = C.changedOldRange(for: .patched(patches), oldLength: 100, newLength: 88)
        XCTAssertEqual(changed, NSRange(location: 10, length: 50))
    }
}
#endif
