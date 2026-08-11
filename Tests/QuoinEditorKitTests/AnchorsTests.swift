import XCTest
import QuoinCore
@testable import QuoinEditorKit

final class AnchorsTests: XCTestCase {
    func testCaretByteAnchor() {
        let a = ByteAnchor.byte(5, affinity: .after, revision: 3, goalColumn: nil)
        let sel = SelectionAnchorRange(start: a, end: a)
        XCTAssertTrue(sel.isCaret)
        if case .byte(let n) = a.kind { XCTAssertEqual(n, 5) } else { XCTFail() }
        XCTAssertEqual(a.revision, 3)
    }
    func testBoundaryEquatableAcrossEqualNeighbors() {
        let l = BlockID(contentHash: 1, occurrence: 0)
        let r = BlockID(contentHash: 2, occurrence: 0)
        let b1 = BoundaryID(left: l, right: r, kind: .interBlock)
        let b2 = BoundaryID(left: l, right: r, kind: .interBlock)
        XCTAssertEqual(b1, b2)
        XCTAssertNotEqual(b1, BoundaryID(left: l, right: nil, kind: .blockEnd))
    }
    func testRangeSelectionNotCaret() {
        let s = ByteAnchor.byte(2, affinity: .after, revision: 0, goalColumn: nil)
        let e = ByteAnchor.byte(7, affinity: .after, revision: 0, goalColumn: nil)
        XCTAssertFalse(SelectionAnchorRange(start: s, end: e).isCaret)
    }
}
