import XCTest
import QuoinCore
@testable import QuoinEditorKit

final class IslandMintTests: XCTestCase {
    // MARK: - ByteRange <-> Range<Int> bridge

    func testByteRangeFromRangeRoundTrip() {
        let r = 1..<5
        let b = ByteRange(r)
        XCTAssertEqual(b.offset, 1)
        XCTAssertEqual(b.length, 4)
        let r2 = Range<Int>(b)
        XCTAssertEqual(r2, r)
    }

    func testRangeFromByteRange() {
        let b = ByteRange(offset: 3, length: 7)
        let r = Range<Int>(b)
        XCTAssertEqual(r, 3..<10)
    }

    // MARK: - mintIsland(at:baseRevision:) carries baseRevision

    func testMintAtInteriorOffsetCarriesBaseRevision() {
        let doc = MarkdownConverter.parse("# Heading\n\nA paragraph.")
        var model = BlockListModel(document: doc)
        let island = model.mintIsland(at: 2, baseRevision: 42)
        XCTAssertNotNil(island)
        XCTAssertEqual(island?.originBlockID, doc.blocks[0].id)
        XCTAssertEqual(island?.baseRevision, 42)
    }

    func testMintAtBlockBoundaryResolvesToContainingBlock() {
        let doc = MarkdownConverter.parse("# Heading\n\nA paragraph.")
        var model = BlockListModel(document: doc)
        // The boundary between block 0 and block 1 is block1's lower bound;
        // it must resolve to block 1 (the block whose range CONTAINS it).
        let boundary = doc.blocks[1].range.offset
        let island = model.mintIsland(at: boundary, baseRevision: 7)
        XCTAssertNotNil(island)
        XCTAssertEqual(island?.originBlockID, doc.blocks[1].id)
        XCTAssertEqual(island?.baseRevision, 7)
    }

    func testMintAtDocumentEndResolvesToLastBlock() {
        let doc = MarkdownConverter.parse("# Heading\n\nA paragraph.")
        var model = BlockListModel(document: doc)
        let lastBlock = doc.blocks.last!
        let end = lastBlock.range.offset + lastBlock.range.length
        let island = model.mintIsland(at: end, baseRevision: 99)
        XCTAssertNotNil(island)
        XCTAssertEqual(island?.originBlockID, lastBlock.id)
        XCTAssertEqual(island?.baseRevision, 99)
    }

    func testRecordAtDocumentEndResolvesToLastBlock() {
        let doc = MarkdownConverter.parse("# Heading\n\nA paragraph.")
        let model = BlockListModel(document: doc)
        let lastBlock = doc.blocks.last!
        let end = lastBlock.range.offset + lastBlock.range.length
        let rec = model.record(at: end)
        XCTAssertEqual(rec?.blockID, lastBlock.id)
    }

    // MARK: - Distinct identity per mint

    func testTwoMintsGetDistinctIslandUnitID() {
        let doc = MarkdownConverter.parse("# Heading\n\nA paragraph.")
        var model = BlockListModel(document: doc)
        let i1 = model.mintIsland(at: 2, baseRevision: 1)
        let i2 = model.mintIsland(at: 2, baseRevision: 1)
        XCTAssertNotNil(i1); XCTAssertNotNil(i2)
        XCTAssertNotEqual(i1!.id, i2!.id)
    }
}
