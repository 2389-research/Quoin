#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// The projection-coalescing contract. Storage patches are diffs against a
/// specific storage state; SwiftUI coalesces rapid publishes, so the view
/// can skip an intermediate patch revision entirely. Applying the next batch
/// to that stale storage silently corrupted the projection — the caret
/// mapping drifted by the skipped delta, and Enter (pressed at the block
/// end) fell outside the recorded editable range and was swallowed. The
/// shipped symptom: "sometimes I can hit enter and sometimes not; eventually
/// it gets into a state where I can't."
final class ProjectionCoalescingTests: XCTestCase {

    private func makeDocument() -> QuoinDocument {
        var source = "# Coalescing\n\n"
        for i in 0..<8 {
            source += "Paragraph \(i) with steady prose to hold the line, hour \(i).\n\n"
        }
        source += "```swift\nlet anchor = 1\n```\n\n"
        source += "Closing paragraph of steady prose to end the fixture.\n"
        return MarkdownConverter.parse(source)
    }

    /// A skipped patch revision with a LENGTH-CHANGING delta (a code-block
    /// flip: attachment ↔ multi-line source) must NOT apply its successor's
    /// patches; the fallback splice resyncs storage to the authoritative
    /// attributed string exactly.
    func testSkippedLengthChangingRevisionResyncs() throws {
        let document = makeDocument()
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let code = try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        }?.id)
        let para = try XCTUnwrap(document.blocks.first {
            if case .paragraph = $0.kind { return true }
            return false
        }?.id)

        // The model's authoritative string, mirroring EVERY publish.
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let live = NSMutableAttributedString(attributedString: reading.attributed)

        // The view's storage got revision 0 only.
        let storage = NSTextStorage()
        storage.setAttributedString(reading.attributed)

        // Revision 1 (SKIPPED by the view): open the code block — its
        // editable source is much longer than its rendered fragment.
        let base0 = RenderedDocument(attributed: live, blockRanges: reading.blockRanges)
        let open = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: base0, from: nil, to: code, caret: 2))
        for patch in open.storagePatches {
            live.replaceCharacters(in: patch.oldRange, with: patch.replacement)
        }
        XCTAssertNotEqual(live.length, storage.length,
                          "test premise: the skipped revision must change the length")

        // Revision 2 (what the view actually sees): switch to a paragraph —
        // patches computed against post-revision-1 state.
        let state1 = RenderedDocument(
            attributed: live, blockRanges: open.blockRanges,
            activeBlockID: code, activeEditableRange: open.activeEditableRange,
            activeSourceText: open.activeSourceText)
        let switchUpdate = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: state1, from: code, to: para, caret: 2))
        let base2 = live.length
        for patch in switchUpdate.storagePatches {
            live.replaceCharacters(in: patch.oldRange, with: patch.replacement)
        }
        let rev2 = RenderedDocument(
            attributed: live, blockRanges: switchUpdate.blockRanges,
            activeBlockID: para, activeEditableRange: switchUpdate.activeEditableRange,
            activeSourceText: switchUpdate.activeSourceText,
            storagePatches: switchUpdate.storagePatches,
            revision: 2, patchBaseLength: base2)

        // The view applies revision 2 to storage that never saw revision 1.
        let application = MarkdownReaderView.Coordinator.applyProjection(rev2, to: storage)
        if case .patched = application {
            XCTFail("stale patches must not apply to a storage that skipped a length-changing revision")
        }
        XCTAssertEqual(storage.string, live.string,
                       "resync must land the authoritative projection exactly")
    }

    /// A skipped SAME-LENGTH revision self-heals: patches replace whole
    /// fragments, and any revision that changes the active block also
    /// carries the patch that rewrites the previously-active fragment — so
    /// whichever path the view takes, storage must end equal to the
    /// authoritative string.
    func testSkippedSameLengthRevisionSelfHeals() throws {
        let document = makeDocument()
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let firstPara = try XCTUnwrap(document.blocks.first {
            if case .paragraph = $0.kind { return true }
            return false
        }?.id)
        let lastPara = try XCTUnwrap(document.blocks.last {
            if case .paragraph = $0.kind { return true }
            return false
        }?.id)

        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let live = NSMutableAttributedString(attributedString: reading.attributed)
        let storage = NSTextStorage()
        storage.setAttributedString(reading.attributed)

        // Revision 1 (SKIPPED): activate a plain paragraph — read and
        // editable fragments share the same string, so the length is
        // unchanged and the base-length guard cannot see the skip.
        let base0 = RenderedDocument(attributed: live, blockRanges: reading.blockRanges)
        let open = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: base0, from: nil, to: firstPara, caret: 2))
        for patch in open.storagePatches {
            live.replaceCharacters(in: patch.oldRange, with: patch.replacement)
        }

        // Revision 2: switch to another paragraph. Its patch batch includes
        // the close-of-firstPara patch, which rewrites the entire fragment
        // the skipped revision touched — healing the stale storage.
        let state1 = RenderedDocument(
            attributed: live, blockRanges: open.blockRanges,
            activeBlockID: firstPara, activeEditableRange: open.activeEditableRange,
            activeSourceText: open.activeSourceText)
        let switchUpdate = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: state1, from: firstPara, to: lastPara, caret: 2))
        let base2 = live.length
        for patch in switchUpdate.storagePatches {
            live.replaceCharacters(in: patch.oldRange, with: patch.replacement)
        }
        let rev2 = RenderedDocument(
            attributed: live, blockRanges: switchUpdate.blockRanges,
            activeBlockID: lastPara, activeEditableRange: switchUpdate.activeEditableRange,
            activeSourceText: switchUpdate.activeSourceText,
            storagePatches: switchUpdate.storagePatches,
            revision: 2, patchBaseLength: base2)

        _ = MarkdownReaderView.Coordinator.applyProjection(rev2, to: storage)
        XCTAssertEqual(storage.string, live.string,
                       "storage must end equal to the authoritative projection")
    }

    /// The straight path still patches (no false positives from the guard).
    func testCurrentBasePatchesApply() throws {
        let document = makeDocument()
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let para = try XCTUnwrap(document.blocks.first {
            if case .paragraph = $0.kind { return true }
            return false
        }?.id)

        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let live = NSMutableAttributedString(attributedString: reading.attributed)
        let storage = NSTextStorage()
        storage.setAttributedString(reading.attributed)

        let base = RenderedDocument(attributed: live, blockRanges: reading.blockRanges)
        let open = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: base, from: nil, to: para, caret: 2))
        let baseLength = live.length
        for patch in open.storagePatches {
            live.replaceCharacters(in: patch.oldRange, with: patch.replacement)
        }
        let rev = RenderedDocument(
            attributed: live, blockRanges: open.blockRanges,
            activeBlockID: para, activeEditableRange: open.activeEditableRange,
            activeSourceText: open.activeSourceText,
            storagePatches: open.storagePatches,
            revision: 1, patchBaseLength: baseLength)

        let application = MarkdownReaderView.Coordinator.applyProjection(rev, to: storage)
        guard case .patched = application else {
            return XCTFail("in-sync patches must take the bounded path")
        }
        XCTAssertEqual(storage.string, live.string)
    }
}
#endif
