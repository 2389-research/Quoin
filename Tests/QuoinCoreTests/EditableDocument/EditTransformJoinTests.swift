import XCTest
@testable import QuoinCore

final class EditTransformJoinTests: XCTestCase {

    private func blockIDs(_ d: EditableDocument) -> [NodeID] {
        d.segments.compactMap { if case .block(let b) = $0 { return b.id } else { return nil } }
    }
    private func texts(_ d: EditableDocument) -> [String] {
        d.segments.compactMap { if case .block(let b) = $0 { return b.text } else { return nil } }
    }

    /// Backspace at the start of the second block merges it into the first, at
    /// the join. THE bug this whole re-arch fixes: it can never delete a
    /// predecessor character, because it operates on whole blocks.
    func testJoinMergesIntoPredecessorAtTheJoin() {
        var d = EditableDocument.build(parsing: "# How to do things\n\nclint")
        let second = blockIDs(d)[1]
        let caret = d.joinWithPrevious(second)
        XCTAssertEqual(texts(d), ["# How to do thingsclint"])
        XCTAssertEqual(caret?.offsetUTF16, ("# How to do things" as NSString).length,
                       "caret at the join — after 'things', before 'clint'")
        XCTAssertEqual(d.serialized(), "# How to do thingsclint")
    }

    /// Joining an EMPTY second block (the empty paragraph a Return made) simply
    /// removes it and the blank line, caret at the predecessor's end. One
    /// Backspace undoes one Return.
    func testJoinEmptyParagraphUndoesTheReturn() {
        var d = EditableDocument.build(parsing: "Hello")
        // Build a real empty trailing paragraph by splitting at the end first.
        let first = blockIDs(d)[0]
        let caret0 = d.splitBlock(at: EditPosition(block: first, offsetUTF16: 5))
        XCTAssertEqual(texts(d), ["Hello", ""])
        // Now Backspace at the start of the empty paragraph.
        let caret = d.joinWithPrevious(caret0.block)
        XCTAssertEqual(texts(d), ["Hello"])
        XCTAssertEqual(caret?.offsetUTF16, 5)
        XCTAssertEqual(d.serialized(), "Hello")
    }

    /// The FIRST block has no predecessor: join is a no-op returning nil.
    func testJoinFirstBlockIsNil() {
        var d = EditableDocument.build(parsing: "a\n\nb")
        XCTAssertNil(d.joinWithPrevious(blockIDs(d)[0]))
    }
}
