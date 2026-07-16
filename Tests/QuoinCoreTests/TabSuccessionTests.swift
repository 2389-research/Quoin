import XCTest
@testable import QuoinCore

final class TabSuccessionTests: XCTestCase {

    // MARK: - Single close (#77)

    func testClosingMiddleTabFocusesTheTabNowInItsSlot() {
        // 5 tabs, close index 2 → 4 remain, the old index-3 tab now sits at 2.
        XCTAssertEqual(TabSuccession.successorIndex(closedIndex: 2, remainingCount: 4), 2)
    }

    func testClosingFirstTabFocusesTheNewFirstTab() {
        XCTAssertEqual(TabSuccession.successorIndex(closedIndex: 0, remainingCount: 3), 0)
    }

    func testClosingRightmostTabFocusesItsLeftNeighbor() {
        // 4 tabs, close index 3 → 3 remain, focus the new rightmost (index 2).
        XCTAssertEqual(TabSuccession.successorIndex(closedIndex: 3, remainingCount: 3), 2)
    }

    func testClosingOnlyTabFocusesNothing() {
        XCTAssertNil(TabSuccession.successorIndex(closedIndex: 0, remainingCount: 0))
    }

    func testNegativeIndexClampsToFirstTab() {
        XCTAssertEqual(TabSuccession.successorIndex(closedIndex: -1, remainingCount: 2), 0)
    }

    // MARK: - Bulk removal (trashed folder closes several tabs at once)

    func testBulkRemovalShiftsActiveSlotByRemovalsToItsLeft() {
        // Tabs 0…5, active 4; removing 1 and 4 leaves [0,2,3,5] — the old
        // index-5 tab now occupies the active tab's slot (index 3).
        let removed: Set<Int> = [1, 4]
        XCTAssertEqual(
            TabSuccession.successorIndex(activeIndex: 4, originalCount: 6) { removed.contains($0) },
            3
        )
    }

    func testBulkRemovalOfRightmostActiveFallsBackToNewRightmost() {
        // Tabs 0…3, active 3; removing 2 and 3 leaves [0,1] — focus index 1.
        let removed: Set<Int> = [2, 3]
        XCTAssertEqual(
            TabSuccession.successorIndex(activeIndex: 3, originalCount: 4) { removed.contains($0) },
            1
        )
    }

    func testBulkRemovalOfEverythingFocusesNothing() {
        XCTAssertNil(
            TabSuccession.successorIndex(activeIndex: 1, originalCount: 3) { _ in true }
        )
    }

    func testBulkRemovalLeftOfActiveKeepsTheSameDocumentFocused() {
        // Removals strictly left of a SURVIVING active tab would be handled by
        // the caller (the active tab still exists); this asserts the slot math
        // still lands on the survivor's new index if the caller asks anyway.
        let removed: Set<Int> = [0]
        XCTAssertEqual(
            TabSuccession.successorIndex(activeIndex: 2, originalCount: 3) { removed.contains($0) },
            1
        )
    }
}
