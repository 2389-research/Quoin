#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Ledger #4/#8: activating one block must not disturb ANY OTHER block's
/// projection — chrome, attributes, or text. The live reports (callout
/// boxes shrinking to their title line with stray reveal tint on
/// neighbors; a stale ✓ done frame after closing a chart) both smell like
/// activation patches desynchronizing storage from the authoritative
/// projection. These tests pin patched-storage ≡ fresh-full-render
/// equivalence through full open → close cycles, per block kind, and the
/// view-layer decoration-run maintenance across those patches.
final class ActivationNeighborIntegrityTests: XCTestCase {

    private let calloutFixture = """
    # Callouts

    > [!NOTE]
    > GitHub-style alert block one.

    > [!TIP]
    > Use this section to test admonition styling.

    > [!IMPORTANT]
    > Important alert syntax body.

    > [!WARNING]
    > Warning alert syntax body.

    Tail paragraph.
    """

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

    private func apply(_ update: AttributedRenderer.ActivationFlipUpdate, to storage: NSTextStorage) {
        for patch in update.storagePatches {
            _ = MarkdownReaderView.Coordinator.applyStoragePatch(in: storage, patch: patch)
        }
    }

    /// Every callout in the fixture: open it via the flip patch, compare
    /// against a fresh full active render; close it, compare against the
    /// reading render. Any neighbor whose attributes drift fails the
    /// storage equality.
    func testCalloutOpenCloseCyclesLeaveNeighborsIntact() throws {
        let document = MarkdownConverter.parse(calloutFixture)
        let callouts = document.blocks.filter {
            if case .callout = $0.kind { return true }
            return false
        }
        XCTAssertGreaterThanOrEqual(callouts.count, 3, "fixture must parse as callouts")

        for target in callouts {
            let renderer = AttributedRenderer()
            var cache: [BlockID: NSAttributedString] = [:]
            let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
            let base = RenderedDocument(attributed: reading.attributed, blockRanges: reading.blockRanges)
            let storage = NSTextStorage()
            storage.setAttributedString(reading.attributed)

            guard let open = renderer.activationFlipUpdate(
                document: document, current: base, from: nil, to: target.id, caret: 3) else {
                XCTFail("callout activation must be patchable (\(target.id))")
                continue
            }
            apply(open, to: storage)

            // Patched storage ≡ a fresh full render with the same active
            // block (same renderer: the preview/caret state matches).
            var referenceCache: [BlockID: NSAttributedString] = cache
            let referenceActive = renderer.render(
                document, activeBlockID: target.id, activeCaret: 3, cache: &referenceCache)
            let referenceStorage = NSTextStorage()
            referenceStorage.setAttributedString(referenceActive.attributed)
            XCTAssertTrue(storage.isEqual(to: referenceStorage),
                          "opening callout \(target.id) corrupted the projection")
            XCTAssertEqual(open.blockRanges, referenceActive.blockRanges,
                           "block ranges must match the full render's")

            // Close it again: storage returns to the reading projection.
            let active = rendered(base, applying: open, activeID: target.id)
            guard let close = renderer.activationFlipUpdate(
                document: document, current: active, from: target.id, to: nil, caret: nil) else {
                XCTFail("callout deactivation must be patchable (\(target.id))")
                continue
            }
            apply(close, to: storage)
            XCTAssertEqual(storage.string, reading.attributed.string,
                           "closing callout \(target.id) must restore the reading text")
            // Attribute-level: no stray reveal tint or lost chrome on ANY
            // block (fresh read fragments may differ by instance for
            // attachments, but callout fixtures are attachment-free).
            let restoredReference = NSTextStorage()
            restoredReference.setAttributedString(reading.attributed)
            XCTAssertTrue(storage.isEqual(to: restoredReference),
                          "closing callout \(target.id) left stray attributes behind")
        }
    }

    /// THE live mechanism behind ledger #4 (reproduced from the field
    /// screenshots): SwiftUI coalesces projection revisions, so the view
    /// can miss the activation patch and fall back to a string splice from
    /// active-state storage to the reading projection. A callout BODY is
    /// string-identical in both — the old splice kept those characters
    /// with their reveal attributes (tint, no box), shrinking the box to
    /// the title line. The splice must sync attributes beyond the string
    /// change.
    func testCoalescedFallbackSpliceSyncsAttributesBeyondTheStringChange() throws {
        let document = MarkdownConverter.parse(calloutFixture)
        let target = try XCTUnwrap(document.blocks.first {
            if case .callout = $0.kind { return true }
            return false
        })
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let editing = renderer.render(document, activeBlockID: target.id, activeCaret: 3, cache: &cache)

        // Storage sits in the ACTIVE state; the reading projection arrives
        // as a fallback splice (the patch revision was coalesced away).
        let storage = NSTextStorage()
        storage.setAttributedString(editing.attributed)
        _ = MarkdownReaderView.Coordinator.spliceChanges(in: storage, to: reading.attributed)

        let reference = NSTextStorage()
        reference.setAttributedString(reading.attributed)
        XCTAssertEqual(storage.string, reference.string)
        XCTAssertTrue(storage.isEqual(to: reference),
                      "fallback splice must restore ATTRIBUTES on string-identical spans " +
                      "(reveal tint stranded on the callout body; box shrunk to its title)")
    }

    /// Ledger #8's live-update failure, same mechanism: a re-rendered
    /// diagram is the same single U+FFFC character — a string splice keeps
    /// the OLD attachment, so the preview never visibly updates. The
    /// attribute sync must carry the new attachment across.
    func testSpliceCarriesReplacedAttachmentsAcross() throws {
        let sourceA = "# C\n\n```mermaid\nflowchart TD\n    A[One] --> B[Two]\n```\n\nTail one.\n"
        let sourceB = "# C\n\n```mermaid\nflowchart TD\n    A[One] --> C[Three]\n```\n\nTail two.\n"
        let renderer = AttributedRenderer()
        let renderedA = renderer.render(MarkdownConverter.parse(sourceA))
        let renderedB = renderer.render(MarkdownConverter.parse(sourceB))

        func attachment(in attributed: NSAttributedString) -> NSTextAttachment? {
            var found: NSTextAttachment?
            attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
                if let a = value as? NSTextAttachment { found = a; stop.pointee = true }
            }
            return found
        }
        let newAttachment = try XCTUnwrap(attachment(in: renderedB.attributed))

        let storage = NSTextStorage()
        storage.setAttributedString(renderedA.attributed)
        _ = MarkdownReaderView.Coordinator.spliceChanges(in: storage, to: renderedB.attributed)
        let carried = try XCTUnwrap(attachment(in: storage))
        XCTAssertTrue(carried === newAttachment,
                      "the splice must adopt the NEW diagram attachment — " +
                      "keeping the old one is the 'preview never updates' bug")
    }

    /// The same cycle for a mermaid chart (ledger #8's shape): open →
    /// close via patches; the storage must return to the reading
    /// projection with the diagram frame + chip intact and NO editingFrame
    /// decoration left anywhere.
    func testChartOpenCloseLeavesNoEditingChrome() throws {
        let source = """
        # Chart

        ```mermaid
        flowchart TD
            A[Start] --> B[End]
        ```

        Tail paragraph.
        """
        let document = MarkdownConverter.parse(source)
        let chart = try XCTUnwrap(document.blocks.first {
            if case .diagram = $0.kind { return true }
            return false
        })
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let base = RenderedDocument(attributed: reading.attributed, blockRanges: reading.blockRanges)
        let storage = NSTextStorage()
        storage.setAttributedString(reading.attributed)

        let open = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: base, from: nil, to: chart.id, caret: 0))
        apply(open, to: storage)
        let active = rendered(base, applying: open, activeID: chart.id)
        let close = try XCTUnwrap(renderer.activationFlipUpdate(
            document: document, current: active, from: chart.id, to: nil, caret: nil))
        apply(close, to: storage)

        XCTAssertEqual(storage.string, reading.attributed.string)
        var editingFrames = 0
        storage.enumerateAttribute(
            QuoinAttribute.blockDecoration,
            in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if let decoration = value as? BlockDecoration,
               case .editingFrame = decoration.kind { editingFrames += 1 }
        }
        XCTAssertEqual(editingFrames, 0, "no ✓ done chrome may survive the close")
    }
}
#endif
