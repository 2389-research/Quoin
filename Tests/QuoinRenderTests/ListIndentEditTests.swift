#if canImport(AppKit)
import XCTest
import QuoinCore
@testable import QuoinRender

/// Tab/⇧Tab list indent-outdent (task #60): the pure edit computation
/// behind the coordinator's doCommandBy hook. One UTF-16 line span, one
/// replacement, caret preserved in the text.
final class ListIndentEditTests: XCTestCase {

    private typealias Coordinator = MarkdownReaderView.Coordinator

    // MARK: - Marker widths (one nesting step = the content column)

    func testMarkerWidths() {
        XCTAssertEqual(Coordinator.listMarkerWidth(of: "- item"), 2)
        XCTAssertEqual(Coordinator.listMarkerWidth(of: "  * item"), 2)
        XCTAssertEqual(Coordinator.listMarkerWidth(of: "+ item"), 2)
        XCTAssertEqual(Coordinator.listMarkerWidth(of: "1. item"), 3)
        XCTAssertEqual(Coordinator.listMarkerWidth(of: "12) item"), 4)
        XCTAssertEqual(Coordinator.listMarkerWidth(of: "- [ ] task"), 2)
        XCTAssertNil(Coordinator.listMarkerWidth(of: "plain prose"))
        XCTAssertNil(Coordinator.listMarkerWidth(of: "-not a list"))
        XCTAssertNil(Coordinator.listMarkerWidth(of: "1x. not ordered"))
        XCTAssertNil(Coordinator.listMarkerWidth(of: ""))
    }

    // MARK: - Single line

    func testIndentCaretLineKeepsCaretInText() throws {
        let source = "- one\n- two\n- three\n"
        // Caret after "tw" on line 2 (offset 6+4 = 10).
        let edit = try XCTUnwrap(Coordinator.listIndentEdit(
            sourceText: source, selection: NSRange(location: 10, length: 0), outdent: false))
        XCTAssertEqual(edit.utf16Range, 6..<12, "one line span")
        XCTAssertEqual(edit.replacement, "  - two\n")
        XCTAssertEqual(edit.caretUTF16, 6, "caret stays after 'tw'")
        XCTAssertFalse(edit.isNoop)
    }

    func testOrderedLineIndentsByItsMarkerWidth() throws {
        let source = "1. one\n2. two\n"
        let edit = try XCTUnwrap(Coordinator.listIndentEdit(
            sourceText: source, selection: NSRange(location: 8, length: 0), outdent: false))
        XCTAssertEqual(edit.replacement, "   2. two\n", "ordered step = marker + space = 3")
    }

    func testOutdentRemovesOneStep() throws {
        let source = "- one\n    - deep\n"
        let edit = try XCTUnwrap(Coordinator.listIndentEdit(
            sourceText: source, selection: NSRange(location: 12, length: 0), outdent: true))
        XCTAssertEqual(edit.replacement, "  - deep\n")
        XCTAssertEqual(edit.caretUTF16, 4, "caret keeps its place in the text")
    }

    func testOutdentAtTopLevelIsANoop() throws {
        let source = "- one\n- two\n"
        let edit = try XCTUnwrap(Coordinator.listIndentEdit(
            sourceText: source, selection: NSRange(location: 2, length: 0), outdent: true))
        XCTAssertTrue(edit.isNoop, "nothing to remove — swallow the key, ship no edit")
        XCTAssertNil(edit.byteEdit(inText: source))
    }

    // MARK: - Multi-line selection

    func testSelectionIndentsEveryTouchedLine() throws {
        let source = "- one\n- two\n- three\n"
        // Selection spans lines 1–2.
        let edit = try XCTUnwrap(Coordinator.listIndentEdit(
            sourceText: source, selection: NSRange(location: 2, length: 8), outdent: false))
        XCTAssertEqual(edit.utf16Range, 0..<12)
        XCTAssertEqual(edit.replacement, "  - one\n  - two\n")
    }

    func testMixedSelectionFallsThrough() {
        let source = "- one\nplain continuation\n"
        XCTAssertNil(Coordinator.listIndentEdit(
            sourceText: source, selection: NSRange(location: 2, length: 10), outdent: false),
            "a non-list line in the span means Tab is not an indent")
    }

    func testProseLineFallsThrough() {
        XCTAssertNil(Coordinator.listIndentEdit(
            sourceText: "Just a paragraph.\n", selection: NSRange(location: 3, length: 0),
            outdent: false))
    }

    // MARK: - Round-trip through bytes

    func testByteEditAppliesCleanly() throws {
        let source = "- one\n  - two\n"
        let edit = try XCTUnwrap(Coordinator.listIndentEdit(
            sourceText: source, selection: NSRange(location: 10, length: 0), outdent: false))
        let (byteRange, replacement, caretDelta) = try XCTUnwrap(edit.byteEdit(inText: source))
        var bytes = Array(source.utf8)
        bytes.replaceSubrange(
            byteRange.offset..<(byteRange.offset + byteRange.length),
            with: Array(replacement.utf8))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "- one\n    - two\n")
        XCTAssertEqual(caretDelta, 6, "caret byte offset within the replacement")
    }

    func testLastLineWithoutTrailingNewline() throws {
        let source = "- one\n- two"
        let edit = try XCTUnwrap(Coordinator.listIndentEdit(
            sourceText: source, selection: NSRange(location: 8, length: 0), outdent: false))
        XCTAssertEqual(edit.replacement, "  - two")
        XCTAssertEqual(edit.utf16Range, 6..<11)
    }
}
#endif
