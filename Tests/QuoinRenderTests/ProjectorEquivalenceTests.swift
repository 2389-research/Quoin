#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// THE projection-equivalence property (editor-modes plan, 3.6): for every
/// renderer fixture × scripted interaction, the PATCH paths (activation flip,
/// per-keystroke active-block edit) applied to live storage must produce a
/// projection byte- and attribute-identical to a fresh FULL render of the
/// same state. Any separator, offset, styling, or base-length disagreement
/// between the paths — the T1/T2/T6 drift classes — fails here, forever.
///
/// Comparison recipe (from ActivationFlipPatchTests): both sides share one
/// warm fragment cache (cached fragments are the same instances, so
/// attachment identity matches) and both go through NSTextStorage so
/// attribute fixing normalizes identically. A nil update is NOT a failure —
/// it is the bail-to-full-render escape hatch, which is correct by
/// definition; the test counts real equivalence checks and asserts a floor
/// so silent universal bailing can't fake a pass.
final class ProjectorEquivalenceTests: XCTestCase {

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // QuoinRenderTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Fixtures/renderer")
    }

    private func patchableBlocks(in document: QuoinDocument) -> [Block] {
        document.blocks.filter { block in
            switch block.kind {
            case .tableOfContents, .list, .blockQuote, .callout:
                return false
            default:
                return true
            }
        }
    }

    /// Splices `newSlice` over `block`'s byte range in `source`.
    private func replacingSlice(in source: String, block: Block, with newSlice: String) -> String {
        var bytes = Array(source.utf8)
        let start = block.range.offset
        let end = start + block.range.length
        bytes.replaceSubrange(start..<end, with: Array(newSlice.utf8))
        return String(decoding: bytes, as: UTF8.self)
    }

    /// NSTextStorage normalization + attachment neutralization: attachments
    /// compare by object identity, and fragments held out of the cache
    /// (pending content) are re-instantiated by a fresh render — identical
    /// pixels, different instances. The projection property under test is
    /// bytes + every OTHER attribute; attachments are compared by presence.
    private func normalized(_ attributed: NSAttributedString) -> NSTextStorage {
        let storage = NSTextStorage()
        storage.setAttributedString(attributed)
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            if value != nil {
                storage.addAttribute(.attachment, value: Self.sentinelAttachment, range: range)
            }
        }
        return storage
    }
    private static let sentinelAttachment = NSTextAttachment()

    private func assertStorageEqual(
        _ patched: NSAttributedString, _ reference: NSAttributedString,
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(normalized(patched).isEqual(to: normalized(reference)),
                      message, file: file, line: line)
    }

    func testPatchPathsMatchFullRenderAcrossTheCorpus() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: fixturesDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "corpus missing — fixtures dir moved?")

        var flipChecks = 0
        var keystrokeChecks = 0

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let document = MarkdownConverter.parse(source)
            let renderer = AttributedRenderer()
            var cache: [BlockID: NSAttributedString] = [:]
            var held: AttributedRenderer.HeldPreview?
            let name = file.lastPathComponent

            let reading = renderer.render(
                document, activeBlockID: nil, activeCaret: nil,
                cache: &cache, heldPreview: &held)
            let base = RenderedDocument(
                attributed: reading.attributed, blockRanges: reading.blockRanges)

            // FLIPS are valid for every kind (only KEYSTROKE patches are
            // gated to patchable kinds) — lists/quotes/callouts were
            // silently uncovered until the click-collapse report exposed
            // the gap (task #60).
            let flippable = document.blocks.prefix(6)
            let patchable = Set(patchableBlocks(in: document).map(\.id))
            for block in flippable {
                guard let slice = document.source.substring(in: block.range),
                      !slice.isEmpty else { continue }
                let caret = min(3, slice.utf16.count)

                // FLIP: reading → active must equal a fresh active render.
                held = nil
                guard let flip = renderer.activationFlipUpdate(
                    document: document, current: base, from: nil, to: block.id,
                    caret: caret, heldPreview: &held
                ) else { continue } // bail-to-full is correct by definition
                let flippedStorage = NSMutableAttributedString(attributedString: reading.attributed)
                for patch in flip.storagePatches {
                    flippedStorage.replaceCharacters(in: patch.oldRange, with: patch.replacement)
                }
                var referenceHeld: AttributedRenderer.HeldPreview?
                let activeReference = renderer.render(
                    document, activeBlockID: block.id, activeCaret: caret,
                    cache: &cache, heldPreview: &referenceHeld)
                assertStorageEqual(
                    flippedStorage, activeReference.attributed,
                    "\(name): flip patch ≠ full active render for \(block.kind)")
                XCTAssertEqual(flip.blockRanges, activeReference.blockRanges,
                               "\(name): flip block ranges drifted")
                XCTAssertEqual(flip.activeEditableRange, activeReference.activeEditableRange,
                               "\(name): flip editable range drifted")
                flipChecks += 1

                // KEYSTROKE: three scripted edits from the active state
                // (patchable kinds only — others always bail to full render).
                guard patchable.contains(block.id) else { continue }
                let insertAt = slice.index(slice.startIndex, offsetBy: min(3, slice.count))
                var edits: [String] = [
                    slice.replacingCharacters(in: insertAt..<insertAt, with: "x"),
                    slice + "\n",   // the clamp-flip case: patch must bail OR match
                ]
                if slice.count > 4 {
                    let deleteAt = slice.index(slice.startIndex, offsetBy: 3)
                    edits.append(slice.replacingCharacters(in: deleteAt..<slice.index(after: deleteAt), with: ""))
                }
                let activeRendered = RenderedDocument(
                    attributed: activeReference.attributed,
                    blockRanges: activeReference.blockRanges,
                    activeBlockID: block.id,
                    activeEditableRange: activeReference.activeEditableRange,
                    activeSourceText: slice)
                for newSlice in edits {
                    let newSource = replacingSlice(in: source, block: block, with: newSlice)
                    let newDocument = MarkdownConverter.parse(newSource)
                    guard newDocument.blocks.count == document.blocks.count,
                          let index = document.blocks.firstIndex(where: { $0.id == block.id }),
                          index < newDocument.blocks.count else { continue }
                    let newActive = newDocument.blocks[index]
                    var editHeld = referenceHeld
                    guard let update = renderer.activeBlockEditUpdate(
                        oldDocument: document,
                        oldRendered: activeRendered,
                        oldActiveBlockID: block.id,
                        newDocument: newDocument,
                        newActiveBlockID: newActive.id,
                        caret: caret,
                        heldPreview: &editHeld
                    ) else { continue } // bail = full render = correct
                    let patchedStorage = NSMutableAttributedString(
                        attributedString: activeReference.attributed)
                    patchedStorage.replaceCharacters(
                        in: update.storagePatch.oldRange, with: update.storagePatch.replacement)
                    var freshCache = cache
                    // The reference render starts from the SAME held-preview
                    // state the patch path did — production's full-render
                    // fallback shares the model's held state, and flap-stick
                    // (a kind flap keeping the held panel) is intentional.
                    var freshHeld = referenceHeld
                    let editReference = renderer.render(
                        newDocument, activeBlockID: newActive.id, activeCaret: caret,
                        cache: &freshCache, heldPreview: &freshHeld)
                    assertStorageEqual(
                        patchedStorage, editReference.attributed,
                        "\(name): keystroke patch ≠ full render for \(block.kind) editing \(newSlice.prefix(24))…")
                    XCTAssertEqual(update.blockRanges, editReference.blockRanges,
                                   "\(name): keystroke block ranges drifted for \(block.kind)")
                    XCTAssertEqual(update.activeEditableRange, editReference.activeEditableRange,
                                   "\(name): keystroke editable range drifted for \(block.kind)")
                    keystrokeChecks += 1
                }
            }
        }

        // The floor: silent universal bailing must not fake a pass.
        XCTAssertGreaterThanOrEqual(flipChecks, 15, "flip equivalence barely exercised")
        XCTAssertGreaterThanOrEqual(keystrokeChecks, 20, "keystroke equivalence barely exercised")
        print("PROJECTOR-EQUIVALENCE flips=\(flipChecks) keystrokes=\(keystrokeChecks)")
    }
}
#endif
