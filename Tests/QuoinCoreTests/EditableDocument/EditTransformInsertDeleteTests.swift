import XCTest
@testable import QuoinCore

final class EditTransformInsertDeleteTests: XCTestCase {

    private func firstBlockID(_ d: EditableDocument) -> NodeID {
        for s in d.segments { if case .block(let b) = s { return b.id } }
        fatalError()
    }

    func testInsertTextMutatesBlockAndReturnsCaretAfterInsert() {
        var d = EditableDocument.build(parsing: "Helo\n\nWorld")
        let id = firstBlockID(d)
        let caret = d.insertText("l", at: EditPosition(block: id, offsetUTF16: 3))
        XCTAssertEqual(d.block(id)?.text, "Hell" + "o")  // "Hello"
        XCTAssertEqual(caret, EditPosition(block: id, offsetUTF16: 4))
        XCTAssertEqual(d.serialized(), "Hello\n\nWorld", "untouched region preserved")
    }

    func testInsertMarksOnlyTheEditedBlockDirty() {
        var d = EditableDocument.build(parsing: "a\n\nb")
        let id = firstBlockID(d)
        _ = d.insertText("X", at: EditPosition(block: id, offsetUTF16: 1))
        XCTAssertEqual(d.block(id)?.pristine, false)
        // The OTHER block stays pristine and verbatim.
        let others = d.segments.compactMap { s -> EditableBlock? in
            if case .block(let b) = s, b.id != id { return b } else { return nil }
        }
        XCTAssertTrue(others.allSatisfy(\.pristine))
        XCTAssertEqual(d.serialized(), "aX\n\nb")
    }

    func testDeleteRangeRemovesTextAndReturnsCaretAtStart() {
        var d = EditableDocument.build(parsing: "Hello\n\nWorld")
        let id = firstBlockID(d)
        let caret = d.deleteRange(inBlock: id, 1..<3)   // remove "el"
        XCTAssertEqual(d.block(id)?.text, "Hlo")
        XCTAssertEqual(caret, EditPosition(block: id, offsetUTF16: 1))
        XCTAssertEqual(d.serialized(), "Hlo\n\nWorld")
    }
}
