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

    /// Deferred from Task 1: an edit applied through the pipeline advances the
    /// published State (a fresh version + the new source) so mirrors see it.
    func testEditAdvancesStateStream() async throws {
        let core = EditorCore(source: "a", fileURL: nil)
        await core.start()
        let before = await core.getSnapshot()
        _ = try await core.apply(edit: SourceEdit(range: ByteRange(offset: 1, length: 0),
                                                  replacement: "b"), baseRevision: nil,
                                 actionName: nil, publishSnapshot: false)
        let after = await core.getSnapshot()
        XCTAssertEqual(after.document.source, "ab")
        XCTAssertGreaterThan(after.version, before.version,
                             "apply() must publish so State mirrors advance")
    }
}
