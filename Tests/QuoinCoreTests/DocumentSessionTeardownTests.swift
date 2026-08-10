import XCTest
@testable import QuoinCore

/// Teardown must be awaitable and must NOT write when discarding — the fix for
/// the resurrection family (a fire-and-forget final save re-creating a
/// just-deleted file). After teardown(save:false) the file the session backed
/// must not be (re)written; after teardown(save:true) dirty content is flushed.
final class DocumentSessionTeardownTests: XCTestCase {

    private func tempFileURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quoin-teardown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Untitled.md")
        try Data("".utf8).write(to: url)
        return url
    }

    func testDiscardingTeardownDoesNotWriteAfterFileIsRemoved() async throws {
        let url = try tempFileURL()
        let session = DocumentSession(source: "", fileURL: url)
        _ = try await session.appendText("typed text")   // now dirty + non-empty
        try FileManager.default.removeItem(at: url)
        await session.teardown(save: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "a discarding teardown must not resurrect the removed file")
    }

    func testSavingTeardownFlushesDirtyContent() async throws {
        let url = try tempFileURL()
        let session = DocumentSession(source: "", fileURL: url)
        _ = try await session.appendText("keep me")
        await session.teardown(save: true)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(onDisk, "keep me\n", "appendText normalizes a trailing newline")
    }
}
