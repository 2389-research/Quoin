import XCTest
@testable import QuoinCore

/// Click-to-caret mapping: a click lands at an offset in the RENDERED text,
/// but the caret must be placed in the SOURCE, which hides characters the
/// projection dropped. The raw offset drifted by every hidden character
/// before the caret — clicking after "…a hard line break." landed two
/// characters early (the hard break's two trailing spaces).
final class CaretMappingTests: XCTestCase {

    private func map(_ rendered: String, _ source: String, at offset: Int) -> Int {
        EditMapping.sourceOffset(
            forRenderedOffset: offset, renderedText: rendered, sourceText: source)
    }

    func testPlainTextIsIdentity() {
        let text = "Plain words, nothing hidden."
        XCTAssertEqual(map(text, text, at: 0), 0)
        XCTAssertEqual(map(text, text, at: 12), 12)
        XCTAssertEqual(map(text, text, at: text.utf16.count), text.utf16.count)
    }

    func testHardBreakTrailingSpaces() {
        // The shipped off-by-two: source carries the hard break's two
        // spaces, the rendered text doesn't.
        let source = "This line ends with two spaces.  \nThis line should appear after a hard line break."
        let rendered = "This line ends with two spaces.\nThis line should appear after a hard line break."
        // Click at the very end of the rendered text → caret at source end.
        XCTAssertEqual(map(rendered, source, at: rendered.utf16.count), source.utf16.count)
        // Click just before the final period.
        let renderedBeforeDot = rendered.utf16.count - 1
        XCTAssertEqual(map(rendered, source, at: renderedBeforeDot), source.utf16.count - 1)
    }

    func testBackslashHardBreak() {
        let source = "This line ends with a backslash.\\\nSecond line."
        let rendered = "This line ends with a backslash.\nSecond line."
        XCTAssertEqual(map(rendered, source, at: rendered.utf16.count), source.utf16.count)
    }

    func testBoldDelimitersAreSkipped() {
        let source = "some **bold** words"
        let rendered = "some bold words"
        // Click right after "bold" (rendered offset 9) → source offset 11
        // (past "some **bold").
        XCTAssertEqual(map(rendered, source, at: 9), 11)
        XCTAssertEqual(map(rendered, source, at: rendered.utf16.count), source.utf16.count)
    }

    func testHeadingPrefixIsSkipped() {
        let source = "### 4.1 Inline Links"
        let rendered = "4.1 Inline Links"
        XCTAssertEqual(map(rendered, source, at: 0), 4)
        XCTAssertEqual(map(rendered, source, at: 3), 7) // after "4.1"
    }

    func testEntitiesAlign() {
        let source = "HTML entities: &amp; and &lt; here"
        let rendered = "HTML entities: & and < here"
        // Entities consume structurally (N source chars ↔ 1 rendered), so
        // the mapping is exact even across several of them.
        let renderedHere = (rendered as NSString).range(of: "here").location
        let sourceHere = (source as NSString).range(of: "here").location
        XCTAssertEqual(map(rendered, source, at: renderedHere), sourceHere)
    }

    func testSoftBreakSpaceNewlineEquivalence() {
        let source = "line one\nline two"
        let rendered = "line one line two"
        let renderedTwo = (rendered as NSString).range(of: "two").location
        let sourceTwo = (source as NSString).range(of: "two").location
        XCTAssertEqual(map(rendered, source, at: renderedTwo), sourceTwo)
    }

    func testAttachmentCharacterIsSkipped() {
        let source = "![alt](img.png) caption"
        let rendered = "\u{FFFC} caption"
        let renderedCaption = (rendered as NSString).range(of: "caption").location
        let sourceCaption = (source as NSString).range(of: "caption").location
        XCTAssertEqual(map(rendered, source, at: renderedCaption), sourceCaption)
    }

    /// The field report, verbatim: "I click right after the 🧪 [in the
    /// first item of the hand-written TOC list] and my cursor is always
    /// placed between the n and g of formatting on item #3." The rendered
    /// bullet's second space met the source's `[` and the unconstrained
    /// lookahead ate a word of label text, deterministically derailing the
    /// caret ~174 characters — and the viewport pin then scrolled the wrong
    /// line into place (+100pt on every click).
    func testBulletedAnchorListClickLandsInTheClickedItem() {
        let source = """
        - [Markdown Renderer Stress Test 🧪](#markdown-renderer-stress-test-)
          - [1. Headings](#1-headings)
          - [2. Paragraphs, Line Breaks, and Entities](#2-paragraphs-line-breaks-and-entities)
          - [3. Inline Formatting](#3-inline-formatting)
        """
        let rendered = """
        •  Markdown Renderer Stress Test 🧪
        •  1. Headings
        •  2. Paragraphs, Line Breaks, and Entities
        •  3. Inline Formatting
        """
        // Click right after the 🧪.
        let renderedAfterFlask = (rendered as NSString).range(of: "🧪").location + 2
        let sourceAfterFlask = (source as NSString).range(of: "🧪").location + 2
        let mapped = map(rendered, source, at: renderedAfterFlask)
        XCTAssertEqual(mapped, sourceAfterFlask,
                       "caret must land right after the 🧪 in item 1, not in item 3")
        // And a click on item 3's text stays in item 3.
        let renderedInline = (rendered as NSString).range(of: "Inline Formatting").location
        let sourceInline = (source as NSString).range(of: "Inline Formatting").location
        XCTAssertEqual(map(rendered, source, at: renderedInline), sourceInline)
    }

    func testClampsOutOfRange() {
        let text = "short"
        XCTAssertEqual(map(text, text, at: 99), text.utf16.count)
        XCTAssertEqual(map(text, text, at: -5), 0)
    }
}
