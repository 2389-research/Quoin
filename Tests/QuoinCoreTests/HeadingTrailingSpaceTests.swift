import XCTest
@testable import QuoinCore

/// Reported bug: caret at the END of a heading, press space → the space landed
/// in no-man's-land between the heading and the next block (Markdown strips a
/// heading's trailing whitespace, so the parser left it unowned). The heading
/// block never grew, the caret couldn't advance, and repeated spaces piled up
/// at one offset — growing the gap and corrupting the layout below. The fix:
/// a heading's source range owns the trailing whitespace on its line.
final class HeadingTrailingSpaceTests: XCTestCase {

    private func heading(in doc: QuoinDocument) -> Block? {
        doc.blocks.first { if case .heading = $0.kind { return true }; return false }
    }

    /// A heading with trailing spaces: the block range must include them.
    func testHeadingRangeOwnsTrailingLineWhitespace() throws {
        let doc = MarkdownConverter.parse("## Rules  \n\nBody paragraph.")
        let h = try XCTUnwrap(heading(in: doc))
        let slice = try XCTUnwrap(doc.source.substring(in: h.range))
        XCTAssertEqual(slice, "## Rules  ",
            "heading range must own its trailing spaces so end-of-line editing works")
    }

    /// The exact reported sequence: a space appended at the heading's end must
    /// be OWNED by the heading (grow it by one byte), not orphaned in the gap.
    func testSpaceAppendedAtHeadingEndGrowsTheHeading() throws {
        let src = "## Rules\n\nBody paragraph."
        let doc = MarkdownConverter.parse(src)
        let h = try XCTUnwrap(heading(in: doc))
        let end = h.range.upperBound  // byte just past "## Rules"

        var bytes = Array(src.utf8)
        bytes.insert(UInt8(ascii: " "), at: end)          // "## Rules \n\nBody…"
        let doc2 = MarkdownConverter.parse(String(decoding: bytes, as: UTF8.self))
        let h2 = try XCTUnwrap(heading(in: doc2))

        XCTAssertEqual(h2.range.length, h.range.length + 1,
            "the appended space must be owned by the heading, not orphaned in the gap")
        XCTAssertEqual(doc2.source.substring(in: h2.range), "## Rules ")

        // …and a second space keeps growing the SAME heading (no pile-up).
        bytes.insert(UInt8(ascii: " "), at: end)          // "## Rules  \n\nBody…"
        let doc3 = MarkdownConverter.parse(String(decoding: bytes, as: UTF8.self))
        let h3 = try XCTUnwrap(heading(in: doc3))
        XCTAssertEqual(h3.range.length, h.range.length + 2)
        XCTAssertEqual(doc3.source.substring(in: h3.range), "## Rules  ")
    }

    /// A heading with NO trailing whitespace is unchanged (the extension is a
    /// no-op), and the newline is never swallowed.
    func testHeadingWithoutTrailingWhitespaceIsUnchanged() throws {
        let doc = MarkdownConverter.parse("# Title\n\nBody.")
        let h = try XCTUnwrap(heading(in: doc))
        XCTAssertEqual(doc.source.substring(in: h.range), "# Title",
            "no trailing whitespace → range unchanged, newline not swallowed")
    }
}
