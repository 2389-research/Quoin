#if canImport(Darwin)
import Foundation
import XCTest
@testable import QuoinCore

/// #32 — formal `NSFilePresenter` adoption. These tests pin the properties the
/// design depends on: the presenter registers/deregisters over the watching
/// lifetime, an external write is picked up through the coordinated channel,
/// and — critically — our OWN coordinated save is NOT misread as an external
/// change (self-write recognition survives presenter adoption).
final class FilePresenterTests: XCTestCase {

    /// Every registered `NSFilePresenter` in this process, by presented URL.
    private func registeredPresenterURLs() -> [String] {
        NSFileCoordinator.filePresenters.compactMap {
            $0.presentedItemURL?.resolvingSymlinksInPath().path
        }
    }

    private func makeTempFile(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-presenter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("doc.md")
        try Data(contents.utf8).write(to: file)
        return file
    }

    /// `startWatching` registers a presenter for the file; `stopWatching`
    /// removes it. No dangling registration is left behind.
    func testPresenterRegistersAndDeregistersOverWatchingLifetime() async throws {
        let file = try makeTempFile("# Hello")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let resolved = file.resolvingSymlinksInPath().path

        let session = try DocumentSession.open(fileURL: file)
        XCTAssertFalse(registeredPresenterURLs().contains(resolved),
                       "no presenter should be registered before startWatching")

        await session.startWatching()
        XCTAssertTrue(registeredPresenterURLs().contains(resolved),
                      "startWatching must register an NSFilePresenter for the file")

        await session.stopWatching()
        XCTAssertFalse(registeredPresenterURLs().contains(resolved),
                       "stopWatching must deregister the NSFilePresenter")
    }

    /// When the session is dropped without an explicit stopWatching, the
    /// presenter's own deinit backstop must still clean up the registry — no
    /// leak of a presenter (or its coordination callbacks) past the session.
    func testPresenterDeregistersWhenSessionDeallocates() async throws {
        let file = try makeTempFile("# Hello")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let resolved = file.resolvingSymlinksInPath().path

        do {
            let session = try DocumentSession.open(fileURL: file)
            await session.startWatching()
            XCTAssertTrue(registeredPresenterURLs().contains(resolved))
        }
        // The session (and its sole strong ref to the presenter) is gone.
        // Poll: the deinit backstop runs off the last release.
        let deadline = Date().addingTimeInterval(2)
        while registeredPresenterURLs().contains(resolved) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(registeredPresenterURLs().contains(resolved),
                       "a deallocated session must not leave its presenter registered")
    }

    /// The presenter's change callback funnels into the same idempotent reload
    /// as the watcher and adopts a clean external change.
    func testPresenterChangeCallbackAdoptsExternalWrite() async throws {
        let file = try makeTempFile("# Before")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let session = try DocumentSession.open(fileURL: file)
        await session.startWatching()
        defer { Task { await session.stopWatching() } }

        try Data("# After".utf8).write(to: file)
        // Drive the coordinated channel directly (the callback the presenter
        // bridges onto the actor), independent of kqueue timing.
        await session.presenterDidObserveChange()

        let doc = await session.document
        XCTAssertEqual(doc.outline.first?.title, "After")
    }

    /// The core self-write guarantee: our OWN coordinated save must not be
    /// misclassified as an external change by the reload path, even though the
    /// presenter is registered. A misread here would clobber or thrash the
    /// document on every autosave.
    func testOwnSaveIsNotMisreadAsExternalChange() async throws {
        let file = try makeTempFile("original")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let session = try DocumentSession.open(fileURL: file)
        await session.startWatching()
        defer { Task { await session.stopWatching() } }

        // Local edit + explicit save (writes through the coordinated path,
        // recording selfWriteHash).
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "local "))
        try await session.saveNow()
        let afterSave = await session.document.source
        XCTAssertEqual(afterSave, "local original")

        let conflictFired = LockedCounter()
        await session.setConflictHandler { _ in conflictFired.increment() }

        // The echo of our own save arriving through either channel must no-op:
        // matching selfWriteHash, never a conflict, never a re-publish.
        await session.presenterDidObserveChange()

        let afterEcho = await session.document.source
        XCTAssertEqual(afterEcho, "local original",
                       "our own save must not be re-adopted as an external change")
        XCTAssertEqual(conflictFired.value, 0, "our own save must never raise the conflict banner")
        let dirty = await session.hasUnsavedChanges
        XCTAssertFalse(dirty, "session should be clean after saving its own content")
    }

    /// A single external write reaching the session twice (watcher + presenter)
    /// while dirty must surface the conflict banner exactly once for that disk
    /// version — the two channels must not double-fire it.
    func testDuplicateConflictSignalFiresBannerOnce() async throws {
        let file = try makeTempFile("original")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let session = try DocumentSession.open(fileURL: file)

        let fireCount = LockedCounter()
        await session.setConflictHandler { disk in
            XCTAssertEqual(disk, "external change")
            fireCount.increment()
        }

        // Dirty the session, then an external write lands.
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "local "))
        try Data("external change".utf8).write(to: file)

        // Two reload signals for the SAME disk version (watcher AND presenter).
        await session.reloadFromDisk()
        await session.presenterDidObserveChange()

        XCTAssertEqual(fireCount.value, 1,
                       "one disk version must surface the conflict banner exactly once")
        let conflicted = await session.hasUnresolvedConflict
        XCTAssertTrue(conflicted)
    }
}

/// A tiny thread-safe counter for asserting callback fire counts.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}
#endif
