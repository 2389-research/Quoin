// Guarded like its siblings: AttributedRenderer exists only on Apple
// platforms (QuoinRender's engine files are AppKit/UIKit-gated).
#if canImport(AppKit) || canImport(UIKit)
import XCTest
import QuoinCore
@testable import QuoinRender

/// The presentation owner (editor-modes plan, Phase 1): one pure function
/// decides every block's presentation; these tests pin the flavor table and
/// the chrome set so a new block kind must consciously choose its reveal
/// behavior here, not fall through a scattered switch somewhere.
final class BlockPresentationTests: XCTestCase {

    // MARK: - The flavor table

    func testFlavorTable() {
        // Preview: side-panel live artifact kinds.
        XCTAssertEqual(EditingFlavor.of(.diagram(source: "flowchart TD", format: .mermaid)), .preview)
        XCTAssertEqual(EditingFlavor.of(.mathBlock(latex: "x^2")), .preview)
        // Verbatim: raw source, zero markdown styling.
        XCTAssertEqual(EditingFlavor.of(.codeBlock(language: "swift", code: "let x = 1")), .verbatim)
        XCTAssertEqual(EditingFlavor.of(.htmlBlock("<b>hi</b>")), .verbatim)
        // Prose: markdown-styled source, caret-scoped span reveal.
        XCTAssertEqual(EditingFlavor.of(.paragraph(inlines: [])), .prose)
        XCTAssertEqual(EditingFlavor.of(.heading(level: 2, inlines: [], slug: "s")), .prose)
        XCTAssertEqual(EditingFlavor.of(.thematicBreak), .prose)
    }

    func testChromeSetMatchesEmbedEditingKinds() {
        // The embed set + front matter draw the accent frame + ✓ done chip.
        XCTAssertTrue(presentationShowsChrome(.codeBlock(language: nil, code: "x")))
        XCTAssertTrue(presentationShowsChrome(.diagram(source: "flowchart TD", format: .mermaid)))
        XCTAssertTrue(presentationShowsChrome(.mathBlock(latex: "x")))
        XCTAssertTrue(presentationShowsChrome(.htmlBlock("<hr>")))
        // Prose is deliberately chrome-free — the caret IS the mode there.
        XCTAssertFalse(presentationShowsChrome(.paragraph(inlines: [])))
        XCTAssertFalse(presentationShowsChrome(.heading(level: 1, inlines: [], slug: "s")))
        XCTAssertFalse(presentationShowsChrome(.thematicBreak))
    }

    // MARK: - The derivation

    func testPresentationForActiveCodeBlock() throws {
        let document = MarkdownConverter.parse("# Title\n\n```swift\nlet x = 1\n```\n\nTail.\n")
        let code = try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        let map = presentation(for: document, activeBlockID: code.id)
        XCTAssertEqual(map[code.id], .editing(flavor: .verbatim, chrome: true))
        XCTAssertEqual(map.activeFlavor, .verbatim)
        // Every OTHER block is rendered.
        for block in document.blocks where block.id != code.id {
            XCTAssertEqual(map[block.id], .rendered)
        }
    }

    func testPresentationForProseIsChromeFree() throws {
        let document = MarkdownConverter.parse("First paragraph.\n\nSecond paragraph.\n")
        let para = try XCTUnwrap(document.blocks.first)
        let map = presentation(for: document, activeBlockID: para.id)
        XCTAssertEqual(map[para.id], .editing(flavor: .prose, chrome: false))
    }

    func testNoActiveBlockMeansAllRendered() throws {
        let document = MarkdownConverter.parse("Paragraph.\n")
        let map = presentation(for: document, activeBlockID: nil)
        XCTAssertNil(map.active)
        XCTAssertNil(map.activeFlavor)
        for block in document.blocks {
            XCTAssertEqual(map[block.id], .rendered)
        }
    }

    func testVanishedActiveBlockDegradesToAllRendered() throws {
        // An undo can remove the active block outright (spec §1.5): the
        // derivation must not crash or invent an editing state for a block
        // the document no longer contains.
        let before = MarkdownConverter.parse("# Title\n\n```swift\nlet x = 1\n```\n")
        let code = try XCTUnwrap(before.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        let after = MarkdownConverter.parse("# Title\n")
        let map = presentation(for: after, activeBlockID: code.id)
        XCTAssertNil(map.active, "a vanished block cannot be editing")
    }

    // MARK: - Derived revealVerbatimCode agreement

    func testRenderedDocumentVerbatimFlagFollowsTheFlavorTable() throws {
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let document = MarkdownConverter.parse("# Title\n\n```swift\nlet x = 1\n```\n\nBody text.\n")
        let code = try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        let para = try XCTUnwrap(document.blocks.first {
            if case .paragraph = $0.kind { return true }
            return false
        })

        let codeActive = renderer.render(document, activeBlockID: code.id, activeCaret: 0, cache: &cache)
        XCTAssertTrue(codeActive.revealVerbatimCode)
        let paraActive = renderer.render(document, activeBlockID: para.id, activeCaret: 0, cache: &cache)
        XCTAssertFalse(paraActive.revealVerbatimCode)
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        XCTAssertFalse(reading.revealVerbatimCode)
    }
}

#endif
