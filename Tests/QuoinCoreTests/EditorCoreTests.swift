import XCTest
@testable import QuoinCore

final class EditorCoreTests: XCTestCase {

    func testInitialSnapshotReflectsSource() async {
        let core = EditorCore(source: "# Hi\n\nbody", fileURL: nil)
        let s = await core.getSnapshot()
        XCTAssertEqual(s.document.source, "# Hi\n\nbody")
        XCTAssertFalse(s.hasUnsavedChanges)
        XCTAssertFalse(s.hasUnresolvedConflict)
        XCTAssertNil(s.fileURL)
    }

    func testStateStreamEmitsInitialState() async {
        let core = EditorCore(source: "a", fileURL: nil)
        await core.start()
        var iterator = await core.stateStream().makeAsyncIterator()
        // The stream yields the current state first (initial mirror).
        let first = await iterator.next()
        XCTAssertEqual(first?.document.source, "a")
    }
}
