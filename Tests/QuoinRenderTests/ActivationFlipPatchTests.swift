#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// The block-local activation-flip contract: activating or closing a block
/// must patch ONLY that block's fragment into live storage — never re-render
/// the document (which costs ~half a second at novel length even with a
/// warm fragment cache) — and the patched storage must be indistinguishable
/// from what a full re-render would have produced.
final class ActivationFlipPatchTests: XCTestCase {

    private func makeDocument() -> QuoinDocument {
        var source = "# Flip patches\n\n"
        for i in 0..<10 {
            source += "Paragraph \(i) with a few words of steady prose to hold the line, hour \(i).\n\n"
        }
        source += """
        ```mermaid
        flowchart TD
            A[Weigh anchor] --> B{Wind fair?}
        ```

        """
        source += "- item one\n- [ ] task two\n\n"
        for i in 10..<20 {
            source += "Paragraph \(i) with a few words of steady prose to hold the line, hour \(i).\n\n"
        }
        return MarkdownConverter.parse(source)
    }

    private func mermaidID(in document: QuoinDocument) -> BlockID? {
        document.blocks.first {
            if case .diagram = $0.kind { return true }
            return false
        }?.id
    }

    /// Applies an update's patches to storage the way updateNSView does.
    private func apply(_ update: AttributedRenderer.ActivationFlipUpdate, to storage: NSTextStorage) {
        for patch in update.storagePatches {
            _ = MarkdownReaderView.Coordinator.applyStoragePatch(in: storage, patch: patch)
        }
    }

    private func rendered(_ base: RenderedDocument, applying update: AttributedRenderer.ActivationFlipUpdate,
                          activeID: BlockID?) -> RenderedDocument {
        RenderedDocument(
            attributed: base.attributed,
            blockRanges: update.blockRanges,
            activeBlockID: activeID,
            activeEditableRange: update.activeEditableRange,
            activeSourceText: update.activeSourceText
        )
    }

    /// Activating a chart patches storage into EXACTLY what a full active
    /// render produces — string and attributes.
    func testActivationPatchMatchesFullRender() throws {
        let document = makeDocument()
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let id = try XCTUnwrap(mermaidID(in: document))

        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let base = RenderedDocument(attributed: reading.attributed, blockRanges: reading.blockRanges)

        let update = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: base, from: nil, to: id, caret: 5))
        XCTAssertFalse(update.storagePatches.isEmpty, "flip must be patch-based")

        let storage = NSTextStorage()
        storage.setAttributedString(reading.attributed)
        apply(update, to: storage)

        // Reference: the full render with the same warm cache (cached
        // fragments are the same instances, so attachment identity matches).
        // Both sides go through NSTextStorage so attribute fixing (fonts,
        // attachments) normalizes identically before comparison.
        let reference = renderer.render(document, activeBlockID: id, activeCaret: 5, cache: &cache)
        let referenceStorage = NSTextStorage()
        referenceStorage.setAttributedString(reference.attributed)
        XCTAssertTrue(storage.isEqual(to: referenceStorage),
                      "patched storage must equal a full active render")
        XCTAssertEqual(update.blockRanges, reference.blockRanges)
        XCTAssertEqual(update.activeEditableRange, reference.activeEditableRange)
        XCTAssertEqual(update.activeSourceText, reference.activeSourceText)
    }

    /// Closing the chart again patches storage back to the original reading
    /// projection (string + ranges; the re-rendered diagram attachment is a
    /// fresh instance, so attribute identity isn't comparable).
    func testDeactivationPatchRestoresReadingProjection() throws {
        let document = makeDocument()
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let id = try XCTUnwrap(mermaidID(in: document))

        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let base = RenderedDocument(attributed: reading.attributed, blockRanges: reading.blockRanges)
        let open = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: base, from: nil, to: id, caret: 5))

        let storage = NSTextStorage()
        storage.setAttributedString(reading.attributed)
        apply(open, to: storage)

        let active = rendered(base, applying: open, activeID: id)
        let close = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: active, from: id, to: nil, caret: nil))
        apply(close, to: storage)

        XCTAssertEqual(storage.string, reading.attributed.string,
                       "flip back must restore the reading text exactly")
        XCTAssertEqual(close.blockRanges, reading.blockRanges)
        XCTAssertNil(close.activeEditableRange)
        XCTAssertNotNil(close.cacheableReadFragment, "read fragment should be cacheable")
    }

    /// Switching directly between two active blocks patches both (close old,
    /// open new) and matches the full render.
    func testSwitchActivePatchesBothBlocks() throws {
        let document = makeDocument()
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let chart = try XCTUnwrap(mermaidID(in: document))
        let paragraph = try XCTUnwrap(document.blocks.first {
            if case .paragraph = $0.kind { return true }
            return false
        }?.id)

        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let base = RenderedDocument(attributed: reading.attributed, blockRanges: reading.blockRanges)
        let open = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: base, from: nil, to: paragraph, caret: 2))

        let storage = NSTextStorage()
        storage.setAttributedString(reading.attributed)
        apply(open, to: storage)

        let active = rendered(base, applying: open, activeID: paragraph)
        let switchUpdate = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: active, from: paragraph, to: chart, caret: 3))
        XCTAssertEqual(switchUpdate.storagePatches.count, 2, "switch = close old + open new")
        apply(switchUpdate, to: storage)

        let reference = renderer.render(document, activeBlockID: chart, activeCaret: 3, cache: &cache)
        XCTAssertEqual(storage.string, reference.attributed.string)
        XCTAssertEqual(switchUpdate.blockRanges, reference.blockRanges)
    }

    /// The flip must stay block-local in cost: at novel scale the update is
    /// tens of times cheaper than the ~500 ms full render it replaces.
    func testFlipUpdateIsBlockLocalInCost() throws {
        var source = "# Big\n\n"
        var i = 0
        while source.utf8.count < 1_200_000 {
            i += 1
            source += "Paragraph \(i): steady prose to fill a novel-length manuscript, hour \(i).\n\n"
            if i % 4 == 2 { source += "```mermaid\nflowchart TD\n  A\(i) --> B\(i)\n```\n\n" }
        }
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let id = try XCTUnwrap(mermaidID(in: document))
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let base = RenderedDocument(attributed: reading.attributed, blockRanges: reading.blockRanges)

        var update: AttributedRenderer.ActivationFlipUpdate?
        var best = TimeInterval.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = Date()
            update = renderer.activationFlipUpdate(
                document: document, current: base, from: nil, to: id, caret: 3)
            best = min(best, Date().timeIntervalSince(start))
        }
        XCTAssertNotNil(update)
        XCTAssertLessThan(best, 0.050,
                          "flip update took \(best * 1000) ms — should be block-local")
    }
}

/// The incremental decoration-run maintenance must produce EXACTLY the runs
/// a full rescan would find — the full rescan (~170 ms at novel length per
/// keystroke) is what it replaces.
final class DecorationRunMaintenanceTests: XCTestCase {

    func testIncrementalRunsMatchFullRescanAfterPatch() throws {
        var source = "# Decorations\n\n"
        for i in 0..<12 {
            source += "Paragraph \(i) of prose.\n\n"
            if i % 3 == 1 { source += "```swift\nlet x\(i) = \(i)\n```\n\n" }
            if i % 4 == 2 { source += "> quoted line \(i)\n\n" }
        }
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
        let storage = try XCTUnwrap(textView.textContentStorage?.textStorage)
        storage.setAttributedString(reading.attributed)
        textView.invalidateDecorations()
        textView.refreshRunsIfNeeded()
        XCTAssertFalse(textView.decorationRuns.isEmpty, "fixture must have decorated blocks")

        // Patch a code block's fragment (an activation flip) and maintain
        // the runs incrementally.
        let code = try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        let base = RenderedDocument(attributed: reading.attributed, blockRanges: reading.blockRanges)
        let update = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: base, from: nil, to: code.id, caret: 2))
        for patch in update.storagePatches {
            _ = MarkdownReaderView.Coordinator.applyStoragePatch(in: storage, patch: patch)
            textView.noteStorageEdit(oldRange: patch.oldRange, newLength: patch.replacement.length)
        }
        let incremental = textView.decorationRuns.map(\.range)

        // Reference: a from-scratch rescan of the same storage.
        textView.invalidateDecorations()
        textView.refreshRunsIfNeeded()
        let fullRescan = textView.decorationRuns.map(\.range)

        XCTAssertEqual(incremental, fullRescan,
                       "incremental decoration runs diverged from a full rescan")
    }
}
#endif
