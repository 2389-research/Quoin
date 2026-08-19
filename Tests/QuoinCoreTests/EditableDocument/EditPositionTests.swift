import XCTest
@testable import QuoinCore

final class EditPositionTests: XCTestCase {

    private func firstBlockID(_ d: EditableDocument) -> NodeID {
        for s in d.segments { if case .block(let b) = s { return b.id } }
        fatalError("no block")
    }

    func testValidPositionInsideBlock() {
        let d = EditableDocument.build(parsing: "Hello\n\nWorld")
        let id = firstBlockID(d)
        XCTAssertTrue(d.isValid(EditPosition(block: id, offsetUTF16: 0)))
        XCTAssertTrue(d.isValid(EditPosition(block: id, offsetUTF16: 5)))   // end of "Hello"
    }

    func testOffsetPastBlockEndIsInvalid() {
        let d = EditableDocument.build(parsing: "Hello\n\nWorld")
        let id = firstBlockID(d)
        XCTAssertFalse(d.isValid(EditPosition(block: id, offsetUTF16: 6)))
    }

    func testUnknownBlockIsInvalid() {
        let d = EditableDocument.build(parsing: "Hello")
        XCTAssertFalse(d.isValid(EditPosition(block: .fresh(), offsetUTF16: 0)))
    }

    func testBlockLookup() {
        let d = EditableDocument.build(parsing: "a\n\nb")
        let id = firstBlockID(d)
        XCTAssertEqual(d.block(id)?.text, "a")
        XCTAssertEqual(d.blockIndex(of: id), 0)
    }
}
