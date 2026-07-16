#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Scratch: how many flip/keystroke equivalence checks does the corpus
/// actually perform on 11-suggestions.md, and which blocks bail?
final class ZZScratchCorpusTests: XCTestCase {
    func testFixture11Coverage() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/renderer/11-suggestions.md")
        let source = try String(contentsOf: url, encoding: .utf8)
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        var held: AttributedRenderer.HeldPreview?
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil,
                                      cache: &cache, heldPreview: &held)
        let base = RenderedDocument(attributed: reading.attributed, blockRanges: reading.blockRanges)

        let patchable = document.blocks.filter { block in
            switch block.kind {
            case .tableOfContents, .list, .blockQuote, .callout: return false
            default: return true
            }
        }
        print("CORPUS11 total blocks:", document.blocks.count, "patchable:", patchable.count,
              "prefix4 kinds:", patchable.prefix(4).map { String(describing: $0.kind).prefix(20) })

        var flips = 0, keys = 0
        for block in patchable {
            guard let slice = document.source.substring(in: block.range), !slice.isEmpty else { continue }
            let caret = min(3, slice.utf16.count)
            held = nil
            guard let flip = renderer.activationFlipUpdate(
                document: document, current: base, from: nil, to: block.id,
                caret: caret, heldPreview: &held) else {
                print("CORPUS11 flip BAIL for", String(describing: block.kind).prefix(30))
                continue
            }
            _ = flip
            flips += 1
            var refHeld: AttributedRenderer.HeldPreview?
            let activeRef = renderer.render(document, activeBlockID: block.id, activeCaret: caret,
                                            cache: &cache, heldPreview: &refHeld)
            let activeRendered = RenderedDocument(
                attributed: activeRef.attributed, blockRanges: activeRef.blockRanges,
                activeBlockID: block.id, activeEditableRange: activeRef.activeEditableRange,
                activeSourceText: slice)
            let insertAt = slice.index(slice.startIndex, offsetBy: min(3, slice.count))
            let newSlice = slice.replacingCharacters(in: insertAt..<insertAt, with: "x")
            var bytes = Array(source.utf8)
            bytes.replaceSubrange(block.range.offset..<(block.range.offset + block.range.length),
                                  with: Array(newSlice.utf8))
            let newSource = String(decoding: bytes, as: UTF8.self)
            let newDocument = MarkdownConverter.parse(newSource)
            guard newDocument.blocks.count == document.blocks.count,
                  let index = document.blocks.firstIndex(where: { $0.id == block.id }),
                  index < newDocument.blocks.count else {
                print("CORPUS11 keystroke SKIP (block count) for", String(describing: block.kind).prefix(30))
                continue
            }
            var editHeld = refHeld
            guard renderer.activeBlockEditUpdate(
                oldDocument: document, oldRendered: activeRendered, oldActiveBlockID: block.id,
                newDocument: newDocument, newActiveBlockID: newDocument.blocks[index].id,
                caret: caret, heldPreview: &editHeld) != nil else {
                print("CORPUS11 keystroke BAIL for", String(describing: block.kind).prefix(30))
                continue
            }
            keys += 1
        }
        print("CORPUS11 flips:", flips, "keystrokes:", keys)
    }
}
#endif
