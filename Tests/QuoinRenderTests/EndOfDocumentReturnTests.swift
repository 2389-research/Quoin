#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Return at the end of the document creates a new paragraph (#1 field report:
/// "type a line, hit Enter, nothing happens"). Markdown has no empty-paragraph
/// representation, so two pieces cooperate: the last prose block's editable
/// slice extends through the trailing whitespace to EOF (giving the caret an
/// empty line to occupy), and Return there inserts a paragraph break rather
/// than a soft-break \n (which renders as a space). These pin both pure pieces.
final class EndOfDocumentReturnTests: XCTestCase {

    private func doc(_ source: String) -> QuoinDocument { MarkdownConverter.parse(source) }

    // MARK: editableSlice — the last prose block absorbs trailing whitespace

    func testLastParagraphSliceExtendsToEOF() {
        let d = doc("Hello\n\n")   // one paragraph, two trailing newlines
        let last = d.blocks.count - 1
        let slice = AttributedRenderer.editableSlice(for: d.blocks[last], at: last, in: d)
        XCTAssertEqual(slice, "Hello\n\n", "the caret needs the trailing blank line to land on")
    }

    func testLastParagraphNoTrailingIsUnchanged() {
        let d = doc("Hello")
        let last = d.blocks.count - 1
        XCTAssertEqual(AttributedRenderer.editableSlice(for: d.blocks[last], at: last, in: d), "Hello")
    }

    func testNonLastBlockKeepsExactRange() {
        let d = doc("# H\n\nPara\n")   // heading is NOT last
        let slice = AttributedRenderer.editableSlice(for: d.blocks[0], at: 0, in: d)
        XCTAssertEqual(slice, "# H", "a mid-document block must not swallow the separator")
    }

    func testLastCodeBlockKeepsExactRange() {
        // Code/table/diagram keep their exact range even when last.
        let d = doc("```\nx\n```\n")
        let last = d.blocks.count - 1
        let slice = AttributedRenderer.editableSlice(for: d.blocks[last], at: last, in: d)
        XCTAssertEqual(slice, d.source.substring(in: d.blocks[last].range),
                       "only prose extends; a code block's fence range is exact")
    }

    // MARK: the Return-insertion decision

    func testFromContentInsertsParagraphBreak() {
        // Caret at end of "Hello" (no trailing newline) → \n\n.
        XCTAssertEqual(
            MarkdownReaderView.Coordinator.endOfDocumentParagraphInsertion(
                sourceText: "Hello", relCaret: 5, atDocumentEnd: true), "\n\n")
    }

    func testOnTrailingEmptyLineStepsDownOneLine() {
        // Caret at end of "Hello\n\n" (already a blank line) → one more \n.
        XCTAssertEqual(
            MarkdownReaderView.Coordinator.endOfDocumentParagraphInsertion(
                sourceText: "Hello\n\n", relCaret: 7, atDocumentEnd: true), "\n")
    }

    func testFileEndingInSingleNewlineInsertsOneLine() {
        XCTAssertEqual(
            MarkdownReaderView.Coordinator.endOfDocumentParagraphInsertion(
                sourceText: "Hello\n", relCaret: 6, atDocumentEnd: true), "\n")
    }

    func testNotAtDocumentEndDoesNothing() {
        XCTAssertNil(
            MarkdownReaderView.Coordinator.endOfDocumentParagraphInsertion(
                sourceText: "Hello", relCaret: 5, atDocumentEnd: false))
    }

    func testCaretNotAtSliceEndDoesNothing() {
        // Caret in the middle → falls through to a plain newline.
        XCTAssertNil(
            MarkdownReaderView.Coordinator.endOfDocumentParagraphInsertion(
                sourceText: "Hello", relCaret: 2, atDocumentEnd: true))
    }
}
#endif
