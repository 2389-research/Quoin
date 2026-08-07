import XCTest
@testable import QuoinCore

/// A blank auto-created untitled document must not reopen forever.
final class ScratchHousekeepingTests: XCTestCase {

    func testASoleEmptyScratchTabIsNotPersisted() {
        XCTAssertFalse(ScratchHousekeeping.shouldPersistSession(
            tabCount: 1, onlyTabIsEmptyScratch: true))
    }

    func testARealDocumentIsPersisted() {
        XCTAssertTrue(ScratchHousekeeping.shouldPersistSession(
            tabCount: 1, onlyTabIsEmptyScratch: false))
    }

    func testAnEmptyScratchAlongsideRealTabsIsPersisted() {
        XCTAssertTrue(ScratchHousekeeping.shouldPersistSession(
            tabCount: 3, onlyTabIsEmptyScratch: false))
    }
}
