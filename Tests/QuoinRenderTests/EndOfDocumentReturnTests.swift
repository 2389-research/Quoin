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

    // MARK: mid-document Return — the general case

    typealias C = MarkdownReaderView.Coordinator

    func testReturnAtEndOfMidDocumentParagraphInsertsAParagraphBreak() {
        // Caret at the end of "A" in "A\n\nB"; the slice is "A" (canonical gap).
        XCTAssertEqual(
            C.paragraphBreakInsertion(sourceText: "A", relCaret: 1, atDocumentEnd: false),
            "\n\n")
    }

    func testReturnOnAnAbsorbedBlankLineAddsOneMoreLine() {
        // A Return already happened: the slice is "A\n", caret on the blank line.
        XCTAssertEqual(
            C.paragraphBreakInsertion(sourceText: "A\n", relCaret: 2, atDocumentEnd: false),
            "\n")
    }

    func testReturnMidParagraphSplitsIt() {
        // Caret between "He" and "llo" — a paragraph break splits into two blocks.
        XCTAssertEqual(
            C.paragraphBreakInsertion(sourceText: "Hello", relCaret: 2, atDocumentEnd: false),
            "\n\n")
    }

    func testEndOfDocumentBehaviorIsUnchanged() {
        XCTAssertEqual(
            C.paragraphBreakInsertion(sourceText: "Hello", relCaret: 5, atDocumentEnd: true),
            "\n\n")
        XCTAssertEqual(
            C.paragraphBreakInsertion(sourceText: "Hello\n", relCaret: 6, atDocumentEnd: true),
            "\n")
    }

    // MARK: ⇧Return — the explicit line break

    func testShiftReturnInsertsACommonMarkHardBreak() {
        XCTAssertEqual(
            C.hardBreakInsertion(sourceText: "Hello", relCaret: 5), "\\\n",
            "a backslash hard break is VISIBLE in source; trailing spaces are not")
    }

    func testShiftReturnDoesNotDoubleTheBackslash() {
        XCTAssertNil(C.hardBreakInsertion(sourceText: "Hello\\", relCaret: 6))
    }
}
#endif
