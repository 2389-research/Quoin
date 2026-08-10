#if canImport(AppKit)
import XCTest
import QuoinCore
@testable import QuoinRender

/// Mapping a document caret offset back onto (active block, caret-in-slice)
/// after an edit. The caret must be bounded by the block's EDITABLE SLICE —
/// which for the last prose block extends through trailing whitespace — NOT by
/// the raw block range. Bounding by the raw range clamps a caret aimed at an
/// absorbed blank line back to the block's content end, so Return at the end of
/// a heading/paragraph never advances ("type a line, hit Enter, nothing
/// happens" — the live bug the pure insertion tests could not see).
final class CaretMappingTests: XCTestCase {

    /// THE regression: a heading followed by a blank line (one Return already
    /// applied). The caret at offset 20 must land on the blank line (slice
    /// offset 20), not clamp to 18 (end of "# How to do things").
    func testCaretLandsOnAbsorbedBlankLineAfterHeading() {
        let doc = MarkdownConverter.parse("# How to do things\n\n")
        let mapping = AttributedRenderer.caretMapping(inDocument: doc, atUTF8Offset: 20)
        XCTAssertEqual(mapping?.blockID, doc.blocks[0].id)
        XCTAssertEqual(mapping?.caretUTF16InSlice, 20,
                       "caret must reach the blank line, not clamp to the heading's content end (18)")
    }

    /// Same for a paragraph (the July end-of-document case, now live-covered).
    func testCaretLandsOnAbsorbedBlankLineAfterParagraph() {
        let doc = MarkdownConverter.parse("Hello\n\n")
        let mapping = AttributedRenderer.caretMapping(inDocument: doc, atUTF8Offset: 7)
        XCTAssertEqual(mapping?.blockID, doc.blocks[0].id)
        XCTAssertEqual(mapping?.caretUTF16InSlice, 7)
    }

    /// A caret in the middle of content is unchanged (no absorption in play).
    func testCaretInContentIsUnclamped() {
        let doc = MarkdownConverter.parse("Hello world")
        let mapping = AttributedRenderer.caretMapping(inDocument: doc, atUTF8Offset: 3)
        XCTAssertEqual(mapping?.blockID, doc.blocks[0].id)
        XCTAssertEqual(mapping?.caretUTF16InSlice, 3)
    }

    /// A non-prose last block (code) does NOT extend, so a caret past its
    /// content still clamps to its end — unchanged behavior.
    func testCodeBlockCaretClampsToItsRange() {
        let doc = MarkdownConverter.parse("```\nx\n```\n")
        let code = doc.blocks[0]
        let end = code.range.offset + code.range.length
        let mapping = AttributedRenderer.caretMapping(inDocument: doc, atUTF8Offset: end + 1)
        XCTAssertEqual(mapping?.blockID, code.id)
        // Clamped to the code block's own length (no trailing-whitespace absorption).
        let slice = doc.source.substring(in: code.range)!
        XCTAssertEqual(mapping?.caretUTF16InSlice, (slice as NSString).length)
    }

    /// An empty document yields no mapping rather than crashing.
    func testEmptyDocumentYieldsNil() {
        let doc = MarkdownConverter.parse("")
        XCTAssertNil(AttributedRenderer.caretMapping(inDocument: doc, atUTF8Offset: 0))
    }
}
#endif
