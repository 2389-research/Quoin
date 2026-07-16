import XCTest
@testable import QuoinCore

final class SourceEditTests: XCTestCase {

    func testInsert() throws {
        let edit = SourceEdit(range: ByteRange(offset: 5, length: 0), replacement: "big ")
        let (result, inverse) = try edit.apply(to: "some text")
        XCTAssertEqual(result, "some big text")
        XCTAssertEqual(inverse, SourceEdit(range: ByteRange(offset: 5, length: 4), replacement: ""))
    }

    func testDelete() throws {
        let edit = SourceEdit(range: ByteRange(offset: 4, length: 4), replacement: "")
        let (result, inverse) = try edit.apply(to: "some big text")
        XCTAssertEqual(result, "some text")
        let (roundTrip, _) = try inverse.apply(to: result)
        XCTAssertEqual(roundTrip, "some big text")
    }

    func testReplaceWithUnicode() throws {
        let source = "café ☕️ time"
        let cafeLength = "café".utf8.count
        let edit = SourceEdit(range: ByteRange(offset: 0, length: cafeLength), replacement: "東京")
        let (result, inverse) = try edit.apply(to: source)
        XCTAssertEqual(result, "東京 ☕️ time")
        let (back, _) = try inverse.apply(to: result)
        XCTAssertEqual(back, source)
    }

    func testEditSplittingScalarRefused() {
        // Offset 1 lands inside the two-byte é in "é".
        XCTAssertThrowsError(
            try SourceEdit(range: ByteRange(offset: 1, length: 1), replacement: "x").apply(to: "é")
        )
    }

    func testOutOfBoundsRefused() {
        XCTAssertThrowsError(
            try SourceEdit(range: ByteRange(offset: 100, length: 1), replacement: "x").apply(to: "short")
        )
    }
}

final class EditMappingTests: XCTestCase {

    func testAsciiRoundTrip() {
        XCTAssertEqual(EditMapping.utf8Offset(inText: "hello", utf16Offset: 3), 3)
        XCTAssertEqual(EditMapping.utf16Offset(inText: "hello", utf8Offset: 3), 3)
    }

    func testMultibyteCharacters() {
        let text = "café x" // é = 2 UTF-8 bytes, 1 UTF-16 unit
        XCTAssertEqual(EditMapping.utf8Offset(inText: text, utf16Offset: 4), 5)
        XCTAssertEqual(EditMapping.utf16Offset(inText: text, utf8Offset: 5), 4)
    }

    func testEmoji() {
        let text = "a🎉b" // 🎉 = 4 UTF-8 bytes, 2 UTF-16 units
        XCTAssertEqual(EditMapping.utf8Offset(inText: text, utf16Offset: 3), 5)
        XCTAssertEqual(EditMapping.utf16Offset(inText: text, utf8Offset: 5), 3)
        // Offsets inside the emoji are not scalar boundaries.
        XCTAssertNil(EditMapping.utf8Offset(inText: text, utf16Offset: 2))
    }

    func testRangeConversion() {
        let text = "aé🎉z"
        // 1..<2 covers é exactly (2 UTF-8 bytes).
        XCTAssertEqual(
            EditMapping.utf8Range(inText: text, utf16Range: 1..<2),
            ByteRange(offset: 1, length: 2)
        )
        // 1..<3 would split the emoji's surrogate pair — refused.
        XCTAssertNil(EditMapping.utf8Range(inText: text, utf16Range: 1..<3))
        // 1..<4 covers é + the whole emoji (2 + 4 UTF-8 bytes).
        XCTAssertEqual(
            EditMapping.utf8Range(inText: text, utf16Range: 1..<4),
            ByteRange(offset: 1, length: 6)
        )
    }

    func testOutOfBounds() {
        XCTAssertNil(EditMapping.utf8Offset(inText: "ab", utf16Offset: 5))
        XCTAssertNil(EditMapping.utf16Offset(inText: "ab", utf8Offset: -1))
    }
}

/// A tiny thread-safe box for capturing values out of @Sendable handlers.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

final class SessionEditingTests: XCTestCase {

    func testApplyEditPublishesAndTracksUndo() async throws {
        let session = DocumentSession(source: "# Title\n\nHello world.")
        let canUndoBefore = await session.canUndo
        XCTAssertFalse(canUndoBefore)

        // Replace "world" (bytes 15..20).
        let edit = SourceEdit(range: ByteRange(offset: 15, length: 5), replacement: "there")
        let doc = try await session.applyEdit(edit)
        XCTAssertEqual(doc.source, "# Title\n\nHello there.")

        let canUndo = await session.canUndo
        XCTAssertTrue(canUndo)
        let undone = try await session.undo()
        XCTAssertEqual(undone?.source, "# Title\n\nHello world.")
        let redone = try await session.redo()
        XCTAssertEqual(redone?.source, "# Title\n\nHello there.")
    }

    func testApplyEditCanSkipSnapshotPublishForLocalRenderCoalescing() async throws {
        let session = DocumentSession(source: "hello")
        let stream = await session.snapshots()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.source, "hello")

        let edit = SourceEdit(range: ByteRange(offset: 5, length: 0), replacement: " world")
        let edited = try await session.applyEdit(edit, publishSnapshot: false)
        XCTAssertEqual(edited.source, "hello world")
        let authoritative = await session.document
        XCTAssertEqual(authoritative.source, "hello world")

        let unexpectedSnapshot = expectation(description: "suppressed local edit snapshot")
        unexpectedSnapshot.isInverted = true
        let nextSnapshotTask = Task {
            if await iterator.next() != nil {
                unexpectedSnapshot.fulfill()
            }
        }
        await fulfillment(of: [unexpectedSnapshot], timeout: 0.2)
        nextSnapshotTask.cancel()

        let undone = try await session.undo()
        XCTAssertEqual(undone?.source, "hello")
    }

    func testEditAutosavesToDisk() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("hello".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        try await session.applyEdit(SourceEdit(range: ByteRange(offset: 5, length: 0), replacement: " world"))
        // Debounced write; wait past the debounce.
        try await Task.sleep(for: .milliseconds(700))
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(onDisk, "hello world")
    }

    func testFailedSaveKeepsDirtyStateAndCanRetry() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("hello".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        try await session.applyEdit(SourceEdit(range: ByteRange(offset: 5, length: 0), replacement: " world"))

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

        do {
            try await session.saveNow()
            XCTFail("save should fail when the document URL is a directory")
        } catch SessionError.fileWriteFailed(let url, _) {
            XCTAssertEqual(url, file)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let isDirtyAfterFailure = await session.hasUnsavedChanges
        let saveErrorAfterFailure = await session.lastSaveError
        let sourceAfterFailure = await session.document.source
        XCTAssertTrue(isDirtyAfterFailure)
        XCTAssertNotNil(saveErrorAfterFailure)
        XCTAssertEqual(sourceAfterFailure, "hello world")

        try FileManager.default.removeItem(at: file)
        try await session.saveNow()

        let isDirtyAfterRetry = await session.hasUnsavedChanges
        let saveErrorAfterRetry = await session.lastSaveError
        XCTAssertFalse(isDirtyAfterRetry)
        XCTAssertNil(saveErrorAfterRetry)
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(onDisk, "hello world")
    }

    func testExternalReloadClearsUndoRedoStacks() async throws {
        // Ledger (data integrity #3): ⌘Z after an external disk change used
        // to splice stale bytes at old offsets, then autosave the corruption.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("alpha bravo".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 6, length: 5), replacement: "charlie"))
        _ = try await session.undo()
        let canUndoBefore = await session.canUndo
        let canRedoBefore = await session.canRedo
        XCTAssertFalse(canUndoBefore)
        XCTAssertTrue(canRedoBefore)
        // Let the autosave settle so the session is clean when disk moves.
        try await Task.sleep(for: .milliseconds(700))

        let external = "totally different content\nwith new offsets\n"
        try Data(external.utf8).write(to: file)
        await session.reloadFromDisk()

        let reloaded = await session.document.source
        XCTAssertEqual(reloaded, external)
        let canUndo = await session.canUndo
        let canRedo = await session.canRedo
        XCTAssertFalse(canUndo, "undo stack must not survive an external reload")
        XCTAssertFalse(canRedo, "redo stack must not survive an external reload")

        // Attempted undo is a no-op and cannot corrupt the adopted content.
        let undone = try await session.undo()
        XCTAssertNil(undone)
        let afterUndo = await session.document.source
        XCTAssertEqual(afterUndo, external)
    }

    func testConflictResolutionTakingDiskClearsUndoRedoStacks() async throws {
        let session = DocumentSession(source: "one two three")
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 4, length: 3), replacement: "2"))
        let canUndoBefore = await session.canUndo
        XCTAssertTrue(canUndoBefore)

        await session.resolveConflictTakingDisk("disk wins, different bytes")
        let canUndo = await session.canUndo
        XCTAssertFalse(canUndo, "adopting the disk side must clear undo history")
        let undone = try await session.undo()
        XCTAssertNil(undone)
        let source = await session.document.source
        XCTAssertEqual(source, "disk wins, different bytes")
    }

    func testWholesaleApplyClearsUndoRedoStacks() async throws {
        let session = DocumentSession(source: "hello")
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 5, length: 0), replacement: " world"))
        await session.apply(source: "replaced entirely")
        let canUndo = await session.canUndo
        XCTAssertFalse(canUndo)
        let undone = try await session.undo()
        XCTAssertNil(undone)
        let source = await session.document.source
        XCTAssertEqual(source, "replaced entirely")
    }

    func testConflictSuspendsAutosaveUntilResolved() async throws {
        // Ledger (data integrity #5): typing after the merge banner used to
        // re-arm the debounced autosave and clobber the disk version while
        // the user was still deciding.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("shared base".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        // Local edit → dirty (autosave still inside its debounce window).
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 11, length: 0), replacement: " plus local"))
        // External change lands while dirty → conflict.
        let external = "external version"
        try Data(external.utf8).write(to: file)
        await session.reloadFromDisk()
        let conflicted = await session.hasUnresolvedConflict
        XCTAssertTrue(conflicted)

        // Continued typing while the banner is up must not write anything.
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "more "))
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), external,
                       "autosave must be suspended while a conflict is unresolved")

        // Even an explicit flush must refuse.
        do {
            try await session.saveNow()
            XCTFail("saveNow must refuse while the conflict is unresolved")
        } catch SessionError.conflictUnresolved(let url) {
            XCTAssertEqual(url, file)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), external)

        // Resolution (keep mine) writes the local side and re-arms saving.
        try await session.resolveConflictKeepingMine()
        let localAfterResolve = await session.document.source
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), localAfterResolve)
        let stillConflicted = await session.hasUnresolvedConflict
        XCTAssertFalse(stillConflicted)

        // Subsequent edits autosave normally again.
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "again "))
        try await Task.sleep(for: .milliseconds(700))
        let finalSource = await session.document.source
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), finalSource,
                       "autosave must resume after the conflict is resolved")
    }

    func testConflictResolvedByTakingDiskResumesAutosave() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("shared base".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "local "))
        let external = "external version"
        try Data(external.utf8).write(to: file)
        await session.reloadFromDisk()
        let conflicted = await session.hasUnresolvedConflict
        XCTAssertTrue(conflicted)

        await session.resolveConflictTakingDisk(external)
        let source = await session.document.source
        XCTAssertEqual(source, external)

        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "typed "))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "typed " + external,
                       "autosave must resume after taking the disk side")
    }

    // MARK: Edit base-revision stamping (ledger, data integrity #14)

    func testEditWithStaleBaseRevisionIsRejected() async throws {
        let session = DocumentSession(source: "alpha bravo")
        let rev0 = await session.contentRevision
        XCTAssertEqual(rev0, 0)

        // An edit stamped against the current revision applies normally,
        // and ordinary edits do NOT bump the revision (typing bursts stay
        // valid across their own in-flight edits).
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 5), replacement: "first"),
            baseRevision: rev0)
        let revAfterEdit = await session.contentRevision
        XCTAssertEqual(revAfterEdit, rev0)

        // A non-edit adoption (external reload / wholesale apply) bumps it.
        await session.apply(source: "completely different disk content")
        let rev1 = await session.contentRevision
        XCTAssertEqual(rev1, rev0 + 1)

        // An in-flight edit computed against the OLD content is rejected
        // instead of splicing at stale offsets.
        do {
            _ = try await session.applyEdit(
                SourceEdit(range: ByteRange(offset: 6, length: 5), replacement: "junk"),
                baseRevision: rev0)
            XCTFail("stale-base edit must be rejected")
        } catch SessionError.staleEditBase(let expected, let got) {
            XCTAssertEqual(expected, rev1)
            XCTAssertEqual(got, rev0)
        }
        let untouched = await session.document.source
        XCTAssertEqual(untouched, "completely different disk content",
                       "a rejected edit must not change the document")

        // A freshly stamped edit passes.
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 10), replacement: "still"),
            baseRevision: rev1)
        let final = await session.document.source
        XCTAssertEqual(final, "still different disk content")
    }

    func testExternalReloadBumpsContentRevisionAndRejectsInFlightEdit() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("first version".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        let base = await session.contentRevision

        // Clean external reload (the #14 scenario: reload during an
        // in-flight edit) bumps the revision…
        try Data("second version, shifted offsets".utf8).write(to: file)
        await session.reloadFromDisk()
        let bumped = await session.contentRevision
        XCTAssertEqual(bumped, base + 1)

        // …so the edit stamped before the reload is refused.
        do {
            _ = try await session.applyEdit(
                SourceEdit(range: ByteRange(offset: 6, length: 7), replacement: "draft"),
                baseRevision: base)
            XCTFail("edit computed before the reload must be rejected")
        } catch SessionError.staleEditBase { }
        let source = await session.document.source
        XCTAssertEqual(source, "second version, shifted offsets")
    }

    func testRevisionedSnapshotsCarryTheAdoptionRevision() async throws {
        let session = DocumentSession(source: "one")
        let stream = await session.revisionedSnapshots()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.document.source, "one")
        XCTAssertEqual(first?.contentRevision, 0)

        await session.apply(source: "two")
        let second = await iterator.next()
        XCTAssertEqual(second?.document.source, "two")
        XCTAssertEqual(second?.contentRevision, 1)
    }

    // MARK: Undo/redo serialized with the edit pipeline (ledger #7)

    func testEditStampedBeforeUndoIsRejectedAfterUndo() async throws {
        // The #7 interleaving: a keystroke's edit is computed (and stamped)
        // against the current content, then ⌘Z splices BEFORE the edit
        // reaches the session. The stale-stamped edit must be rejected,
        // never applied at pre-undo offsets.
        let session = DocumentSession(source: "alpha bravo")
        let rev0 = await session.contentRevision
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 5), replacement: "first"),
            baseRevision: rev0)

        // A queued keystroke stamps itself against the post-edit content…
        let staleStamp = await session.contentRevision
        XCTAssertEqual(staleStamp, rev0, "ordinary edits do not bump the revision")

        // …but the undo lands first (the lost race).
        let undone = try await session.undo()
        XCTAssertEqual(undone?.source, "alpha bravo")
        let bumped = await session.contentRevision
        XCTAssertEqual(bumped, rev0 + 1, "undo must bump the content revision")

        do {
            _ = try await session.applyEdit(
                SourceEdit(range: ByteRange(offset: 5, length: 0), replacement: "!"),
                baseRevision: staleStamp)
            XCTFail("an edit stamped before the undo must be rejected")
        } catch SessionError.staleEditBase(let expected, let got) {
            XCTAssertEqual(expected, bumped)
            XCTAssertEqual(got, staleStamp)
        }
        let source = await session.document.source
        XCTAssertEqual(source, "alpha bravo", "the rejected edit must not splice")
    }

    func testRedoAlsoBumpsContentRevision() async throws {
        let session = DocumentSession(source: "one two")
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 3), replacement: "ONE"))
        _ = try await session.undo()
        let afterUndo = await session.contentRevision
        let stale = afterUndo
        _ = try await session.redo()
        let afterRedo = await session.contentRevision
        XCTAssertEqual(afterRedo, afterUndo + 1, "redo splices content too")

        do {
            _ = try await session.applyEdit(
                SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "x"),
                baseRevision: stale)
            XCTFail("an edit stamped before the redo must be rejected")
        } catch SessionError.staleEditBase { }

        // A freshly stamped edit passes and the undo stacks stay usable.
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "z"),
            baseRevision: afterRedo)
        let source = await session.document.source
        XCTAssertEqual(source, "zONE two")
        let undoneOnce = try await session.undo()
        XCTAssertEqual(undoneOnce?.source, "ONE two")
    }

    func testUndoRedoKeepHistoryStacksAcrossRevisionBumps() async throws {
        // The revision bump is stale-edit REJECTION only — it must not
        // behave like an external adoption (which clears both stacks).
        let session = DocumentSession(source: "base")
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 4, length: 0), replacement: " one"))
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 8, length: 0), replacement: " two"))
        _ = try await session.undo()
        _ = try await session.undo()
        let source = await session.document.source
        XCTAssertEqual(source, "base")
        let canRedo = await session.canRedo
        XCTAssertTrue(canRedo)
        _ = try await session.redo()
        _ = try await session.redo()
        let restored = await session.document.source
        XCTAssertEqual(restored, "base one two")
    }

    // MARK: External rename/move (ledger, data integrity #6)

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testExternalDeleteDetachesDirtySessionAndBlocksResurrection() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("original".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        let failureMessage = LockedBox<String>()
        await session.setSaveFailureHandler { failureMessage.value = $0 }

        // Dirty edit, then the file vanishes before the autosave lands.
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 8, length: 0), replacement: " plus edits"))
        try FileManager.default.removeItem(at: file)
        await session.reloadFromDisk()

        // Vanish confirm (250ms) must beat the autosave debounce (400ms);
        // wait past both plus margin.
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "autosave must not resurrect the deleted path")
        let detached = await session.isDetached
        XCTAssertTrue(detached)
        XCTAssertNotNil(failureMessage.value,
                        "a dirty session losing its file must surface a save failure")

        // Continued typing stays in memory; still no file.
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "more "))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // Explicit saves refuse rather than fork the document.
        do {
            try await session.saveNow()
            XCTFail("saveNow must refuse while detached")
        } catch SessionError.fileWriteFailed { }

        // Relocating (the app resolving the situation) re-attaches.
        let newFile = dir.appendingPathComponent("moved.md")
        await session.relocate(to: newFile)
        try await session.saveNow()
        let source = await session.document.source
        XCTAssertEqual(try String(contentsOf: newFile, encoding: .utf8), source)
    }

    func testExternalDeleteWhileCleanDetachesQuietly() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("clean content".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        let failureMessage = LockedBox<String>()
        await session.setSaveFailureHandler { failureMessage.value = $0 }

        try FileManager.default.removeItem(at: file)
        await session.reloadFromDisk()
        try await Task.sleep(for: .milliseconds(500))

        let detached = await session.isDetached
        XCTAssertTrue(detached, "a clean session losing its file is marked detached")
        XCTAssertNil(failureMessage.value, "no edits at risk — no failure banner")
        let source = await session.document.source
        XCTAssertEqual(source, "clean content", "content stays available in memory")
    }

    func testDetachedDirtySessionRaisesConflictInsteadOfClobberingARestoredFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("original".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        let conflictSource = LockedBox<String>()
        await session.setConflictHandler { conflictSource.value = $0 }

        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 8, length: 0), replacement: " edited"))
        try FileManager.default.removeItem(at: file)
        await session.reloadFromDisk()
        try await Task.sleep(for: .milliseconds(500))
        let detached = await session.isDetached
        XCTAssertTrue(detached)

        // A FOREIGN file appears at the old path. The next keystroke must
        // re-attach via the conflict machinery, not overwrite it.
        try Data("foreign newcomer".utf8).write(to: file)
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "more "))
        try await Task.sleep(for: .milliseconds(1000))

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "foreign newcomer",
                       "a restored/foreign file must not be clobbered")
        XCTAssertNotNil(conflictSource.value, "the merge banner must be raised")
        let conflicted = await session.hasUnresolvedConflict
        XCTAssertTrue(conflicted)
        let stillDetached = await session.isDetached
        XCTAssertFalse(stillDetached, "the session re-attached; the banner owns resolution")
    }

    func testWatcherFollowsExternalMoveAndSavesToTheNewPath() async throws {
        // The file watcher is DispatchSourceFileSystemObject (canImport(Darwin)
        // in FileWatcher.swift); there is no live watcher off Darwin, so this
        // move-following behavior only exists on Apple platforms.
        #if !canImport(Darwin)
        throw XCTSkip("FileWatcher is Darwin-only (DispatchSourceFileSystemObject); no external-move tracking on Linux.")
        #endif
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldFile = dir.appendingPathComponent("before.md")
        let newFile = dir.appendingPathComponent("after.md")
        try Data("movable content".utf8).write(to: oldFile)

        let session = try DocumentSession.open(fileURL: oldFile)
        await session.startWatching()
        defer { Task { await session.stopWatching() } }
        // Let the watcher arm before moving.
        try await Task.sleep(for: .milliseconds(200))

        try FileManager.default.moveItem(at: oldFile, to: newFile)

        // The watcher follows the live inode via F_GETPATH; poll briefly.
        // F_GETPATH yields symlink-resolved paths (/private/var/…), so
        // compare resolved forms.
        let expectedPath = newFile.resolvingSymlinksInPath().path
        var followed = false
        for _ in 0..<40 {
            if await session.fileURL?.resolvingSymlinksInPath().path == expectedPath {
                followed = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(followed, "session must follow the external move to the new URL")

        // Edits now save to the NEW path; the old one must not come back.
        try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "edited "))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(try String(contentsOf: newFile, encoding: .utf8), "edited movable content")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path),
                       "the old filename must not be resurrected")
    }

    func testUntouchedRegionsAreByteLossless() throws {
        // The acceptance-checklist guarantee: editing one block leaves every
        // other byte of the file identical.
        let source = "# Title\n\nPara one   with  odd spacing\t\n\n- [x] task ☕️\n\nlast"
        let doc = MarkdownConverter.parse(source)
        let target = doc.blocks[1] // "Para one..."
        let edit = SourceEdit(
            range: ByteRange(offset: target.range.offset, length: 4),
            replacement: "Line"
        )
        let (result, _) = try edit.apply(to: source)
        let originalBytes = Array(source.utf8)
        let resultBytes = Array(result.utf8)
        // Prefix before the edit and suffix after it are untouched.
        XCTAssertEqual(Array(resultBytes[0..<target.range.offset]), Array(originalBytes[0..<target.range.offset]))
        XCTAssertEqual(
            Array(resultBytes[(target.range.offset + 4)...]),
            Array(originalBytes[(target.range.offset + 4)...])
        )
    }
}
