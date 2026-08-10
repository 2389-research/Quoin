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

    /// Task 3b: a save failure surfaces through the session's failure handler
    /// into `State.lastSaveError`, and a later successful edit clears it. The
    /// failure is triggered the real way (a dirty file deleted out from under
    /// the session fires the handler via `confirmVanished`), then re-attaching
    /// to a fresh writable path lets the next edit save cleanly.
    func testSaveFailureSurfacesInStateAndClearsOnNextEdit() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("hello".utf8).write(to: file)

        // Build the session ourselves so the test can drive its vanish path,
        // then hand the SAME session to the core (one-session-per-file).
        let session = try DocumentSession.open(fileURL: file)
        let core = EditorCore(adoptingForTest: session)
        await core.start()

        // Dirty edit through the core, then delete the file before autosave.
        _ = try await core.apply(
            edit: SourceEdit(range: ByteRange(offset: 5, length: 0), replacement: " world"),
            baseRevision: nil, actionName: nil)
        try FileManager.default.removeItem(at: file)
        await session.reloadFromDisk()

        // The vanish confirmation (~250ms) fires the save-failure handler,
        // which the core mirrors into State.lastSaveError.
        try await pollUntil(timeout: .seconds(3)) {
            await core.getSnapshot().lastSaveError != nil
        }
        let failed = await core.getSnapshot()
        XCTAssertNotNil(failed.lastSaveError,
                        "a dirty session losing its file must surface a save failure in State")

        // Re-attach to a fresh, writable path; a successful edit clears it.
        let newFile = dir.appendingPathComponent("moved.md")
        await session.relocate(to: newFile)
        _ = try await core.apply(
            edit: SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "x"),
            baseRevision: nil, actionName: nil)
        let cleared = await core.getSnapshot()
        XCTAssertNil(cleared.lastSaveError,
                     "a successful edit supersedes a stale save failure")
    }

    /// Polls `condition` until it is true or `timeout` elapses (async-safe;
    /// no XCTestExpectation, which can't await actor reads cleanly).
    private func pollUntil(timeout: Duration,
                           _ condition: () async -> Bool,
                           file: StaticString = #filePath,
                           line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("condition not met within \(timeout)", file: file, line: line)
    }
}
