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

    func testZeroLengthRoundTrip() {
        let b = ByteRange(3..<3)
        XCTAssertEqual(b.offset, 3)
        XCTAssertEqual(b.length, 0)
        let r = Range<Int>(ByteRange(offset: 3, length: 0))
        XCTAssertEqual(r, 3..<3)
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

    func testRecordAndMintAtInterBlockGapReturnNil() {
        // "# Heading\n\nA paragraph." — block 0 (heading) ends where its own
        // content ends; block 1 (paragraph) starts after the "\n\n" separator.
        // A genuine gap requires that separator to be more than zero bytes
        // wide; if it ever collapses to zero this test would be vacuous, so
        // assert the gap actually exists before relying on it.
        let doc = MarkdownConverter.parse("# Heading\n\nA paragraph.")
        var model = BlockListModel(document: doc)
        let gapOffset = doc.blocks[0].range.offset + doc.blocks[0].range.length
        let nextBlockStart = doc.blocks[1].range.offset
        XCTAssertLessThan(gapOffset, nextBlockStart, "fixture must have a real inter-block gap for this test to be meaningful")
        // The gap offset belongs to neither block's content: nil-by-design.
        XCTAssertNil(model.record(at: gapOffset))
        XCTAssertNil(model.mintIsland(at: gapOffset, baseRevision: 7))
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
