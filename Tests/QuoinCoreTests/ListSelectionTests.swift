import XCTest
@testable import QuoinCore

/// Arrow-key highlight movement for Quick Open + the library search list
/// (#11). Down/Up wrap; Home/End jump; empty and single-item lists have
/// defined, non-crashing answers. The SwiftUI views delegate every keypress
/// to these, so this is where the wrap/clamp contract is pinned.
final class ListSelectionTests: XCTestCase {

    // MARK: - Down (next), with wrap

    func testNextAdvancesByOne() {
        XCTAssertEqual(ListSelection.next(0, count: 5), 1)
        XCTAssertEqual(ListSelection.next(3, count: 5), 4)
    }

    func testNextWrapsPastTheEndToTheFirst() {
        XCTAssertEqual(ListSelection.next(4, count: 5), 0)
    }

    // MARK: - Up (previous), with wrap

    func testPreviousStepsBackByOne() {
        XCTAssertEqual(ListSelection.previous(4, count: 5), 3)
        XCTAssertEqual(ListSelection.previous(1, count: 5), 0)
    }

    func testPreviousWrapsPastTheStartToTheLast() {
        XCTAssertEqual(ListSelection.previous(0, count: 5), 4)
    }

    // MARK: - Home / End

    func testFirstIsAlwaysZero() {
        XCTAssertEqual(ListSelection.first(count: 5), 0)
        XCTAssertEqual(ListSelection.first(count: 1), 0)
    }

    func testLastIsTheFinalIndex() {
        XCTAssertEqual(ListSelection.last(count: 5), 4)
        XCTAssertEqual(ListSelection.last(count: 1), 0)
    }

    // MARK: - Single-item list

    func testSingleItemDownAndUpStayPut() {
        XCTAssertEqual(ListSelection.next(0, count: 1), 0)
        XCTAssertEqual(ListSelection.previous(0, count: 1), 0)
    }

    // MARK: - Empty list (defined, harmless default of 0)

    func testEmptyListNeverCrashesAndReturnsZero() {
        XCTAssertEqual(ListSelection.next(0, count: 0), 0)
        XCTAssertEqual(ListSelection.previous(0, count: 0), 0)
        XCTAssertEqual(ListSelection.first(count: 0), 0)
        XCTAssertEqual(ListSelection.last(count: 0), 0)
        XCTAssertEqual(ListSelection.clamped(3, count: 0), 0)
    }

    // MARK: - Out-of-range current index is tolerated (stale highlight)

    func testNextToleratesAStaleHighlightAboveRange() {
        // A shrinking result list can leave `current` past the end for one
        // frame; movement must fold it back in, not index out of bounds.
        XCTAssertEqual(ListSelection.next(99, count: 5), 0)
        XCTAssertEqual(ListSelection.previous(99, count: 5), 3)
    }

    func testNextToleratesANegativeCurrent() {
        XCTAssertEqual(ListSelection.next(-3, count: 5), 1)
        XCTAssertEqual(ListSelection.previous(-3, count: 5), 4)
    }

    // MARK: - Clamp (results changed under the highlight)

    func testClampedFoldsIntoRange() {
        XCTAssertEqual(ListSelection.clamped(7, count: 5), 4)
        XCTAssertEqual(ListSelection.clamped(-1, count: 5), 0)
        XCTAssertEqual(ListSelection.clamped(2, count: 5), 2)
    }
}
