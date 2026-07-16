import XCTest
@testable import QuoinCore

/// #21: a run of single-character, contiguous, same-direction, non-whitespace
/// edits collapses into ONE undo group, so ⌘Z undoes a word (or backspaced
/// run), not a letter. Whitespace, a caret jump, or a non-typing edit breaks it.
final class UndoCoalescingTests: XCTestCase {

    private func type(_ text: String, into s: DocumentSession, at start: Int = 0) async throws {
        for (i, ch) in text.enumerated() {
            _ = try await s.applyEdit(
                SourceEdit(range: ByteRange(offset: start + i, length: 0), replacement: String(ch)))
        }
    }

    func testTypingAWordIsOneUndo() async throws {
        let s = DocumentSession(source: "")
        try await type("hello", into: s)
        let undone = try await s.undo()
        XCTAssertEqual(undone?.source, "", "one undo removes the whole word")
        let canUndo = await s.canUndo
        XCTAssertFalse(canUndo)
    }

    func testWhitespaceBreaksTheGroup() async throws {
        let s = DocumentSession(source: "")
        try await type("ab cd", into: s)
        let u1 = try await s.undo(); XCTAssertEqual(u1?.source, "ab ")
        let u2 = try await s.undo(); XCTAssertEqual(u2?.source, "ab")
        let u3 = try await s.undo(); XCTAssertEqual(u3?.source, "")
    }

    func testBackspaceRunIsOneUndo() async throws {
        let s = DocumentSession(source: "abc")
        for offset in [2, 1, 0] {   // backspace c, b, a
            _ = try await s.applyEdit(SourceEdit(range: ByteRange(offset: offset, length: 1), replacement: ""))
        }
        let undone = try await s.undo()
        XCTAssertEqual(undone?.source, "abc", "one undo restores the whole backspaced run")
        let canUndo = await s.canUndo
        XCTAssertFalse(canUndo)
    }

    func testCaretJumpBreaksTheGroup() async throws {
        let s = DocumentSession(source: "xy")
        _ = try await s.applyEdit(SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "a")) // axy
        _ = try await s.applyEdit(SourceEdit(range: ByteRange(offset: 3, length: 0), replacement: "b")) // axyb
        let u1 = try await s.undo(); XCTAssertEqual(u1?.source, "axy", "removes only 'b'")
        let u2 = try await s.undo(); XCTAssertEqual(u2?.source, "xy", "then 'a'")
    }

    func testMultiCharEditIsItsOwnUndo() async throws {
        let s = DocumentSession(source: "")
        try await type("hi", into: s)                                   // one group
        _ = try await s.applyEdit(SourceEdit(range: ByteRange(offset: 2, length: 0), replacement: " world")) // paste
        try await type("!", into: s, at: 8)                             // new group after the paste
        let u1 = try await s.undo(); XCTAssertEqual(u1?.source, "hi world", "the typed '!' undoes alone")
        let u2 = try await s.undo(); XCTAssertEqual(u2?.source, "hi", "the paste undoes as one")
        let u3 = try await s.undo(); XCTAssertEqual(u3?.source, "", "the typed word undoes as one")
    }
}
