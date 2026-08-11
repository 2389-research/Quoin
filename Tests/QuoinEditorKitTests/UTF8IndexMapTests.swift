import XCTest
@testable import QuoinEditorKit

final class UTF8IndexMapTests: XCTestCase {
    func testAsciiRoundTrip() {
        let m = UTF8IndexMap("# Hi")
        XCTAssertEqual(m.utf8Count, 4); XCTAssertEqual(m.utf16Count, 4)
        XCTAssertEqual(m.utf16(fromUTF8: 2), 2)
        XCTAssertEqual(m.utf8(fromUTF16: 2), 2)
        XCTAssertEqual(m.utf16(fromUTF8: 4), 4)   // end
        XCTAssertNil(m.utf16(fromUTF8: 5))        // out of range
    }
    func testMultibyteAndAstral() {
        // "é" = 2 UTF-8 bytes, 1 UTF-16 unit; "😀" = 4 UTF-8 bytes, 2 UTF-16 units.
        let m = UTF8IndexMap("é😀")
        XCTAssertEqual(m.utf8Count, 6); XCTAssertEqual(m.utf16Count, 3)
        XCTAssertEqual(m.utf16(fromUTF8: 2), 1)   // after "é"
        XCTAssertEqual(m.utf16(fromUTF8: 6), 3)   // end
        XCTAssertNil(m.utf16(fromUTF8: 1))        // mid-"é" → not representable
        XCTAssertEqual(m.utf8(fromUTF16: 1), 2)
        XCTAssertNil(m.utf8(fromUTF16: 2))        // mid-astral (low surrogate) → nil
    }
}
