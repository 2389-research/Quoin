#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Ledger #5: an indented (non-fenced) code block's revealed source is
/// VERBATIM — no markdown styling, no live links hijacking clicks, code
/// font throughout. The styler's fence-based code detection can't see
/// indented code; the block KIND is the truth.
final class IndentedCodeRevealTests: XCTestCase {

    private let source = """
    # Doc

        This is an indented code block.
        Markdown inside it is not parsed: **not bold**, [not link](https://x).

    Tail paragraph.
    """

    func testIndentedCodeRevealsVerbatim() throws {
        let document = MarkdownConverter.parse(source)
        let block = try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        }, "fixture must parse as an indented code block")
        let slice = try XCTUnwrap(document.source.substring(in: block.range))
        let renderer = AttributedRenderer()
        let revealed = renderer.renderEditableSourceFragment(
            slice, caretOffset: 0, block: block, document: document)
        let attributed = revealed.attributed
        let ns = attributed.string as NSString

        // No live link anywhere in the reveal.
        var links = 0
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if value != nil { links += 1 }
        }
        XCTAssertEqual(links, 0, "verbatim code must never grow clickable links")

        // "**not bold**" is not bold, and shows in the code font.
        let boldRange = ns.range(of: "not bold")
        XCTAssertNotEqual(boldRange.location, NSNotFound)
        let font = try XCTUnwrap(attributed.attribute(
            .font, at: boldRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.bold),
                       "markdown must not style inside verbatim code")
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace)
                        || font.fontName.lowercased().contains("mono"),
                      "verbatim code shows in the code font, got \(font.fontName)")

        // Still character-for-character 1:1.
        XCTAssertEqual(ns.substring(with: revealed.editableRange), slice)
    }

    func testFencedCodeRevealIsUnchangedByTheFlag() throws {
        // Fenced code keeps its existing reveal (fence detection works
        // there); the verbatim flag must not fire.
        let fenced = "# Doc\n\n```swift\nlet a = 1\n```\n"
        let document = MarkdownConverter.parse(fenced)
        let block = try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        let slice = try XCTUnwrap(document.source.substring(in: block.range))
        let revealed = AttributedRenderer().renderEditableSourceFragment(
            slice, caretOffset: 0, block: block, document: document)
        XCTAssertEqual((revealed.attributed.string as NSString)
            .substring(with: revealed.editableRange), slice)
    }
}
#endif
