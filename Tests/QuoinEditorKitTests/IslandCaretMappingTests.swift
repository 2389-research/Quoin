import XCTest
@testable import QuoinEditorKit

final class IslandCaretMappingTests: XCTestCase {
    // "a😀b": a=1 byte/1 unit, 😀=4 bytes/2 units, b=1 byte/1 unit.
    let source = "a😀b"
    let byteStart = 10

    func testDocumentByteForwardMapping() {
        XCTAssertEqual(IslandCaretMapping.documentByte(localUTF16: 0, islandSource: source, islandByteStart: byteStart), 10) // start
        XCTAssertEqual(IslandCaretMapping.documentByte(localUTF16: 1, islandSource: source, islandByteStart: byteStart), 11) // after "a"
        XCTAssertEqual(IslandCaretMapping.documentByte(localUTF16: 3, islandSource: source, islandByteStart: byteStart), 15) // after "😀"
        XCTAssertEqual(IslandCaretMapping.documentByte(localUTF16: 4, islandSource: source, islandByteStart: byteStart), 16) // end
    }

    func testDocumentByteMidSurrogateReturnsNil() {
        // UTF-16 offset 2 is the low half of the "😀" surrogate pair.
        XCTAssertNil(IslandCaretMapping.documentByte(localUTF16: 2, islandSource: source, islandByteStart: byteStart))
    }

    func testDocumentByteOutOfRangeReturnsNil() {
        XCTAssertNil(IslandCaretMapping.documentByte(localUTF16: -1, islandSource: source, islandByteStart: byteStart))
        XCTAssertNil(IslandCaretMapping.documentByte(localUTF16: 5, islandSource: source, islandByteStart: byteStart))
    }

    func testLocalUTF16InverseMapping() {
        XCTAssertEqual(IslandCaretMapping.localUTF16(documentByte: 10, islandSource: source, islandByteStart: byteStart), 0)
        XCTAssertEqual(IslandCaretMapping.localUTF16(documentByte: 11, islandSource: source, islandByteStart: byteStart), 1)
        XCTAssertEqual(IslandCaretMapping.localUTF16(documentByte: 15, islandSource: source, islandByteStart: byteStart), 3)
        XCTAssertEqual(IslandCaretMapping.localUTF16(documentByte: 16, islandSource: source, islandByteStart: byteStart), 4)
    }

    func testLocalUTF16MidScalarReturnsNil() {
        // Byte 11 is the start of "😀"; byte 12 lands mid-scalar.
        XCTAssertNil(IslandCaretMapping.localUTF16(documentByte: 12, islandSource: source, islandByteStart: byteStart))
    }

    func testLocalUTF16BeforeIslandStartReturnsNil() {
        XCTAssertNil(IslandCaretMapping.localUTF16(documentByte: 9, islandSource: source, islandByteStart: byteStart))
    }

    func testLocalUTF16OutOfRangeReturnsNil() {
        XCTAssertNil(IslandCaretMapping.localUTF16(documentByte: 17, islandSource: source, islandByteStart: byteStart))
    }

    func testRoundTripAllBoundaries() {
        let map = UTF8IndexMap(source)
        for u16 in 0...map.utf16Count {
            guard let byte = IslandCaretMapping.documentByte(localUTF16: u16, islandSource: source, islandByteStart: byteStart) else {
                continue // surrogate low-half, expected to skip
            }
            XCTAssertEqual(IslandCaretMapping.localUTF16(documentByte: byte, islandSource: source, islandByteStart: byteStart), u16)
        }
    }
}
