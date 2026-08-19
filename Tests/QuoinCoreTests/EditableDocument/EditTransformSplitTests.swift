import XCTest
@testable import QuoinCore

final class EditTransformSplitTests: XCTestCase {

    private func firstBlockID(_ d: EditableDocument) -> NodeID {
        for s in d.segments { if case .block(let b) = s { return b.id } }
        fatalError()
    }
    private func texts(_ d: EditableDocument) -> [String] {
        d.segments.compactMap { if case .block(let b) = $0 { return b.text } else { return nil } }
    }

    /// Return in the MIDDLE of a paragraph splits it into two, caret in the new
    /// second block, joined by a canonical blank line.
    func testSplitMidBlock() {
        var d = EditableDocument.build(parsing: "HelloWorld")
        let id = firstBlockID(d)
        let caret = d.splitBlock(at: EditPosition(block: id, offsetUTF16: 5))
        XCTAssertEqual(texts(d), ["Hello", "World"])
        XCTAssertEqual(caret.offsetUTF16, 0)
        XCTAssertEqual(d.block(caret.block)?.text, "World")
        XCTAssertEqual(d.serialized(), "Hello\n\nWorld")
    }

    /// Return at the END of a block makes a real EMPTY paragraph the caret lives
    /// in — no virtual line, and it serializes to the trailing blank line.
    func testSplitAtEndMakesEmptyParagraph() {
        var d = EditableDocument.build(parsing: "Hello")
        let id = firstBlockID(d)
        let caret = d.splitBlock(at: EditPosition(block: id, offsetUTF16: 5))
        XCTAssertEqual(texts(d), ["Hello", ""])
        XCTAssertEqual(d.block(caret.block)?.text, "")
        XCTAssertEqual(caret.offsetUTF16, 0)
        // An empty trailing paragraph serializes as the blank line after content.
        XCTAssertEqual(d.serialized(), "Hello\n\n")
    }

    /// Both halves are marked dirty (their text changed / they were born).
    func testSplitDirtiesBothHalves() {
        var d = EditableDocument.build(parsing: "abcd")
        let id = firstBlockID(d)
        let caret = d.splitBlock(at: EditPosition(block: id, offsetUTF16: 2))
        XCTAssertEqual(d.block(id)?.pristine, false)
        XCTAssertEqual(d.block(caret.block)?.pristine, false)
    }
}
