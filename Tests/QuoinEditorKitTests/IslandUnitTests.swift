import XCTest
import QuoinCore
@testable import QuoinEditorKit

final class IslandUnitTests: XCTestCase {
    func testRecordsFromDocument() {
        let doc = MarkdownConverter.parse("# Heading\n\nA paragraph.")
        let model = BlockListModel(document: doc)
        XCTAssertEqual(model.records.count, doc.blocks.count)
        // The record at an offset inside the heading is the heading block.
        let rec = model.record(at: 2)
        XCTAssertEqual(rec?.blockID, doc.blocks[0].id)
    }
    func testMintIslandGetsFreshIdAndBlockRange() {
        let doc = MarkdownConverter.parse("# Heading\n\nA paragraph.")
        var model = BlockListModel(document: doc)
        let i1 = model.mintIsland(at: 2)
        let i2 = model.mintIsland(at: 2)   // same offset, but a NEW island identity each mint
        XCTAssertNotNil(i1); XCTAssertNotNil(i2)
        XCTAssertNotEqual(i1!.id, i2!.id, "each activation mints a fresh IslandUnitID")
        XCTAssertEqual(i1!.originBlockID, doc.blocks[0].id)
        XCTAssertEqual(i1!.byteRange, doc.blocks[0].range.offset ..< (doc.blocks[0].range.offset + doc.blocks[0].range.length))
    }
    func testOutOfRangeOffset() {
        let doc = MarkdownConverter.parse("# Heading")
        var model = BlockListModel(document: doc)
        XCTAssertNil(model.record(at: 9_999))
        XCTAssertNil(model.mintIsland(at: 9_999))
    }
}
