import XCTest
@testable import QuoinCore

/// The pure "append text to the end of a document" seam behind the App Intents
/// "Append Text to Note" action. Only the trailing-newline / line-boundary
/// rules live here; the live append (open a session, apply, save) is the app
/// shell over `DocumentSession.appendText`, which is exercised separately.
final class DocumentAppendTests: XCTestCase {

    private func applied(_ text: String, to source: String) -> String? {
        guard let edit = DocumentAppend.appendEdit(appending: text, to: source) else { return nil }
        return try? edit.apply(to: source).result
    }

    func testAppendToEmptySource() {
        XCTAssertEqual(applied("hello", to: ""), "hello\n")
    }

    func testAppendJoinsOnNewLineWhenNoTrailingNewline() {
        XCTAssertEqual(applied("hello", to: "abc"), "abc\nhello\n")
    }

    func testAppendAfterExistingTrailingNewline() {
        XCTAssertEqual(applied("hello", to: "abc\n"), "abc\nhello\n")
    }

    func testExistingBlankTailIsPreserved() {
        // We only touch the tail by INSERTING — an existing double newline is
        // left intact (byte-lossless), the new line lands after it.
        XCTAssertEqual(applied("x", to: "abc\n\n"), "abc\n\nx\n")
    }

    func testCallersTrailingNewlinesAreCollapsedToOne() {
        XCTAssertEqual(applied("hello\n", to: "abc\n"), "abc\nhello\n")
        XCTAssertEqual(applied("hello\n\n\n", to: "abc\n"), "abc\nhello\n")
    }

    func testInteriorNewlinesArePreserved() {
        XCTAssertEqual(applied("line1\nline2", to: "abc\n"), "abc\nline1\nline2\n")
    }

    func testCRLFIsNormalized() {
        XCTAssertEqual(applied("line1\r\nline2\r\n", to: "abc\n"), "abc\nline1\nline2\n")
    }

    func testEmptyOrWhitespaceOnlyAppendReturnsNil() {
        XCTAssertNil(DocumentAppend.appendEdit(appending: "", to: "abc"))
        XCTAssertNil(DocumentAppend.appendEdit(appending: "\n\n", to: "abc"))
        XCTAssertNil(DocumentAppend.appendEdit(appending: "\r\n", to: "abc"))
    }

    func testLeadingWhitespaceIsContentAndKept() {
        // Only trailing newlines are the caller's; leading indentation is text.
        XCTAssertEqual(applied("  indented", to: "abc\n"), "abc\n  indented\n")
    }

    func testEditIsAPureTailInsertion() {
        // The edit never rewrites the prefix: its range is zero-length at the
        // end of the source, so the untouched region is byte-identical.
        let source = "# Title\n\nbody text"
        let edit = DocumentAppend.appendEdit(appending: "more", to: source)
        XCTAssertEqual(edit?.range, ByteRange(offset: source.utf8.count, length: 0))
    }

    func testAppendIsUnicodeSafe() {
        // Byte offset must land past multibyte content, not mid-scalar.
        let source = "café ☕️"
        XCTAssertEqual(applied("done", to: source), "café ☕️\ndone\n")
    }
}
