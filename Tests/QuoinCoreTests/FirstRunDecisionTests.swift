import XCTest
@testable import QuoinCore

/// The auto-untitled document must appear ONLY when nothing else claimed the
/// window. A Finder double-click must never race a blank document beside it.
final class FirstRunDecisionTests: XCTestCase {

    func testTrueFirstLaunchGetsAnUntitledDocument() {
        XCTAssertTrue(FirstRunDecision.shouldCreateUntitled(
            hasOpenTabs: false, hasLibrary: false, hasPendingOpens: false,
            isLaunchRestoration: false, reopenedScratchCount: 0))
    }

    func testAPendingFinderOpenSuppressesIt() {
        XCTAssertFalse(FirstRunDecision.shouldCreateUntitled(
            hasOpenTabs: false, hasLibrary: false, hasPendingOpens: true,
            isLaunchRestoration: false, reopenedScratchCount: 0))
    }

    func testARestoredSessionSuppressesIt() {
        XCTAssertFalse(FirstRunDecision.shouldCreateUntitled(
            hasOpenTabs: true, hasLibrary: false, hasPendingOpens: false,
            isLaunchRestoration: true, reopenedScratchCount: 0))
    }

    func testAReopenedScratchDocumentSuppressesIt() {
        XCTAssertFalse(FirstRunDecision.shouldCreateUntitled(
            hasOpenTabs: false, hasLibrary: false, hasPendingOpens: false,
            isLaunchRestoration: true, reopenedScratchCount: 1))
    }

    func testAConnectedLibraryStillGetsAnUntitledDocument() {
        XCTAssertTrue(FirstRunDecision.shouldCreateUntitled(
            hasOpenTabs: false, hasLibrary: true, hasPendingOpens: false,
            isLaunchRestoration: false, reopenedScratchCount: 0),
            "an empty window should be writable regardless of library state")
    }
}
