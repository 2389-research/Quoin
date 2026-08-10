import XCTest
@testable import QuoinCore

/// THE close-time rule, pure and exhaustive. A scratch doc that is empty AND the
/// last reference is discarded WITHOUT saving (so a final save can't resurrect
/// it); anything else is kept. A backing file is deleted ONLY for that same
/// discard case — never while another reference is live, never for a real doc.
final class DocumentLifecycleTests: XCTestCase {
    typealias S = DocumentLifecycle.CloseState

    func testEmptyScratchLastRefIsDiscardedWithoutSaving() {
        XCTAssertEqual(DocumentLifecycle.onClose(S(isScratch: true, isEmpty: true, isLastReference: true)),
                       .discardWithoutSaving)
        XCTAssertTrue(DocumentLifecycle.shouldDeleteBackingFile(S(isScratch: true, isEmpty: true, isLastReference: true)))
    }

    func testScratchWithContentIsKeptAndSaved() {
        XCTAssertEqual(DocumentLifecycle.onClose(S(isScratch: true, isEmpty: false, isLastReference: true)),
                       .keepAndSave)
        XCTAssertFalse(DocumentLifecycle.shouldDeleteBackingFile(S(isScratch: true, isEmpty: false, isLastReference: true)))
    }

    func testEmptyScratchNotLastRefIsNeverDeleted() {
        // Another live reference is still editing it: must not delete or discard.
        let s = S(isScratch: true, isEmpty: true, isLastReference: false)
        XCTAssertEqual(DocumentLifecycle.onClose(s), .keepAndSave)
        XCTAssertFalse(DocumentLifecycle.shouldDeleteBackingFile(s))
    }

    func testRealDocumentIsKeptAndSaved() {
        let s = S(isScratch: false, isEmpty: true, isLastReference: true)
        XCTAssertEqual(DocumentLifecycle.onClose(s), .keepAndSave)
        XCTAssertFalse(DocumentLifecycle.shouldDeleteBackingFile(s), "a real doc file is never deleted on close")
    }
}
