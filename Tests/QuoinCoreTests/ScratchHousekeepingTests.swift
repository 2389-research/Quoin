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

    // MARK: - isDiscardableEmptyScratch (the purge/GC emptiness predicate)

    /// An empty or whitespace-only scratch file has nothing worth keeping.
    func testWhitespaceOnlyScratchIsDiscardable() {
        XCTAssertTrue(ScratchHousekeeping.isDiscardableEmptyScratch(contents: ""))
        XCTAssertTrue(ScratchHousekeeping.isDiscardableEmptyScratch(contents: "   \n\t\n  "))
    }

    /// Real content — even content padded with whitespace — must survive purge.
    func testScratchWithContentIsNotDiscardable() {
        XCTAssertFalse(ScratchHousekeeping.isDiscardableEmptyScratch(contents: "hello"))
        XCTAssertFalse(ScratchHousekeeping.isDiscardableEmptyScratch(contents: "\n\n  a note  \n\n"))
    }

    /// The data-safety case: an UNREADABLE file (nil — invalid UTF-8, transient
    /// I/O error) must be KEPT, never purged. A `nil` read must NOT collapse to
    /// "empty" and delete a real document.
    func testUnreadableScratchIsNeverDiscardable() {
        XCTAssertFalse(ScratchHousekeeping.isDiscardableEmptyScratch(contents: nil))
    }
}
