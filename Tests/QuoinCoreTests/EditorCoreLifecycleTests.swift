import XCTest
@testable import QuoinCore

/// The Plan-1 lifecycle invariants, now covered against EditorCore directly
/// (previously only hand-tested through the GUI).
final class EditorCoreLifecycleTests: XCTestCase {

    private func tempURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editorcore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Untitled.md")
        try Data("".utf8).write(to: url)
        return url
    }

    func testCurrentlyEmptyIsPipelineInclusive() async throws {
        let core = EditorCore(source: "", fileURL: nil)
        await core.start()
        _ = try await core.apply(edit: SourceEdit(range: ByteRange(offset: 0, length: 0),
                                                  replacement: "x"), baseRevision: nil,
                                 actionName: nil, publishSnapshot: false)
        let empty = await core.currentlyEmpty()
        XCTAssertFalse(empty, "content typed via the pipeline must be seen")
    }

    func testCurrentlyEmptyTrueForWhitespaceOnly() async throws {
        let core = EditorCore(source: "   \n\n  ", fileURL: nil)
        await core.start()
        let empty = await core.currentlyEmpty()
        XCTAssertTrue(empty, "whitespace-only source is empty")
    }

    func testDiscardDoesNotWriteAfterFileRemoved() async throws {
        let url = try tempURL()
        let core = EditorCore(adoptingForTest: DocumentSession(source: "", fileURL: url))
        await core.start()
        _ = try await core.apply(edit: SourceEdit(range: ByteRange(offset: 0, length: 0),
                                                  replacement: "typed"), baseRevision: nil,
                                 actionName: nil, publishSnapshot: false)
        try FileManager.default.removeItem(at: url)
        await core.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "discard must never resurrect the removed file")
    }

    func testStaleEditBaseRejected() async throws {
        let core = EditorCore(source: "abc", fileURL: nil)
        await core.start()
        let base = await core.getSnapshot().contentRevision
        // Force a revision bump out of band, then apply against the old base.
        await core.reloadForTest(source: "abcd")   // bumps contentRevision
        do {
            _ = try await core.apply(edit: SourceEdit(range: ByteRange(offset: 3, length: 0),
                                                      replacement: "z"), baseRevision: base,
                                     actionName: nil, publishSnapshot: false)
            XCTFail("expected staleEditBase")
        } catch SessionError.staleEditBase { /* ok */ }
    }

    func testUndoRedoOrdering() async throws {
        let core = EditorCore(source: "abc\n", fileURL: nil)
        await core.start()
        // publishSnapshot: false (the keystroke contract) does not update the
        // cached snapshot, so assert on the doc RETURNED by apply.
        let afterApply = try await core.apply(
            edit: SourceEdit(range: ByteRange(offset: 3, length: 0), replacement: "d"),
            baseRevision: nil, actionName: .append, publishSnapshot: false)
        XCTAssertEqual(afterApply.source, "abcd\n")
        let undone = await core.undo()
        XCTAssertEqual(undone?.source, "abc\n")
        let redone = await core.redo()
        XCTAssertEqual(redone?.source, "abcd\n")
    }
}
