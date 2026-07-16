#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Repro harness for the reported click-collapse (task #60): clicking
/// between items of a multi-indent list progressively collapsed indent
/// levels. Pins the two invariants the report violates: reveal cycles are
/// projection-stable, and reveal indentation is caret-independent.
@MainActor
final class ListClickCollapseRepro: XCTestCase {
    func testListRevealCyclesAreStable() throws {
        var source = "# Doc\n\n"
        source += "- level one\n  - level two indented\n    - level three deeper\n      - level four deepest\n  - back to two\n- one again\n\nTail.\n"
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let list = try XCTUnwrap(document.blocks.first {
            if case .list = $0.kind { return true }
            return false
        })

        let reading0 = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)

        // Cycle: activate (varying caret) → deactivate. Projections stable.
        var lastReading = reading0.attributed
        for caret in [0, 10, 30, 55, 80] {
            _ = renderer.render(document, activeBlockID: list.id, activeCaret: caret, cache: &cache)
            let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
            XCTAssertTrue(reading.attributed.isEqual(to: lastReading),
                          "reading projection must be identical after reveal cycle at caret \(caret)")
            lastReading = reading.attributed
        }
        XCTAssertEqual(document.source, source)

        // Repeated reveals at different carets must agree on indentation.
        let slice = try XCTUnwrap(document.source.substring(in: list.range))
        let r1 = renderer.renderEditableSourceFragment(slice, caretOffset: 5, block: list, document: document)
        let r2 = renderer.renderEditableSourceFragment(slice, caretOffset: 60, block: list, document: document)
        XCTAssertEqual(r1.attributed.length, r2.attributed.length)
        var mismatches: [Int] = []
        let ns = r1.attributed.string as NSString
        var i = 0
        while i < r1.attributed.length {
            let s1 = r1.attributed.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle
            let s2 = r2.attributed.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle
            if s1?.headIndent != s2?.headIndent || s1?.firstLineHeadIndent != s2?.firstLineHeadIndent {
                mismatches.append(i)
            }
            i = NSMaxRange(ns.lineRange(for: NSRange(location: i, length: 0)))
        }
        XCTAssertTrue(mismatches.isEmpty,
                      "reveal indentation must not depend on the caret; mismatched lines at \(mismatches)")
    }
}

extension ListClickCollapseRepro {
    /// The app's ACTUAL click path: activation flips applied as storage
    /// patches. The equivalence corpus never exercised lists (they're not
    /// keystroke-patchable, so patchableBlocks excluded them from flips
    /// too) — repeated open/close cycles must leave storage byte- and
    /// attribute-identical to the original reading projection.
    func testListFlipStorageCyclesDoNotDrift() throws {
        var source = "# Doc\n\n"
        source += "- level one\n  - level two indented\n    - level three deeper\n      - level four deepest\n  - back to two\n- one again\n\nTail.\n"
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let list = try XCTUnwrap(document.blocks.first {
            if case .list = $0.kind { return true }
            return false
        })

        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let storage = NSTextStorage()
        storage.setAttributedString(reading.attributed)
        let original = NSTextStorage()
        original.setAttributedString(reading.attributed)

        var current = RenderedDocument(attributed: reading.attributed, blockRanges: reading.blockRanges)
        for cycle in 0..<3 {
            let open = try XCTUnwrap(renderer.activationFlipUpdate(
                document: document, current: current, from: nil, to: list.id, caret: 10 + cycle * 20),
                "open flip \(cycle)")
            for patch in open.storagePatches {
                storage.replaceCharacters(in: patch.oldRange, with: patch.replacement)
            }
            let opened = RenderedDocument(
                attributed: storage.copy() as! NSAttributedString,
                blockRanges: open.blockRanges,
                activeBlockID: list.id,
                activeEditableRange: open.activeEditableRange,
                activeSourceText: open.activeSourceText)
            let close = try XCTUnwrap(renderer.activationFlipUpdate(
                document: document, current: opened, from: list.id, to: nil, caret: nil),
                "close flip \(cycle)")
            for patch in close.storagePatches {
                storage.replaceCharacters(in: patch.oldRange, with: patch.replacement)
            }
            current = RenderedDocument(
                attributed: storage.copy() as! NSAttributedString,
                blockRanges: close.blockRanges)

            XCTAssertEqual(storage.string, original.string,
                           "cycle \(cycle): storage TEXT drifted")
            XCTAssertTrue(storage.isEqual(to: original),
                          "cycle \(cycle): storage ATTRIBUTES drifted (the click-collapse)")
        }
    }
}
#endif
