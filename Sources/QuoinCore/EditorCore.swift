import Foundation

/// The platform-free editor engine for ONE document. Owns the
/// `DocumentSession`, serializes edits/lifecycle behind the actor, and
/// publishes a `Sendable` `State` snapshot that mirrors the session. No
/// SwiftUI/AppKit/QuoinRender imports — it builds and tests on Linux. A
/// later `@MainActor @Observable` ReaderModel becomes a thin adapter that
/// mirrors this `State` and does the rendering.
///
/// Stage 0 (this file) is the scaffold: session ownership, state
/// observation, and conflict bridging. Lifecycle/edit/ops methods (apply,
/// save, undo/redo, toggle…) arrive in later stages.
public actor EditorCore {

    /// An immutable mirror of the session's observable surface, safe to hand
    /// to a `@MainActor` view model. `version` is monotonic so a mirror can
    /// tell a fresh publish from a duplicate and never miss one.
    public struct State: Sendable {
        public var document: QuoinDocument
        public var contentRevision: Int
        public var undoState: DocumentSession.UndoState
        public var fileURL: URL?
        public var hasUnsavedChanges: Bool
        public var hasUnresolvedConflict: Bool
        /// The on-disk source offered by a pending conflict, else nil. Sourced
        /// from the session's conflict handler, not a session property.
        public var conflictDiskSource: String?
        /// The user-facing message from the most recent save failure, else nil.
        /// Sourced from the session's save-failure handler (a silent autosave
        /// failure is data loss on a timer). A later successful edit clears it.
        public var lastSaveError: String?
        public var isDetached: Bool
        /// Monotonic; bumps on every published `State` so mirrors never miss
        /// one.
        public var version: Int
    }

    private let session: DocumentSession
    private var version = 0
    private var conflictDiskSource: String?
    private var lastSaveError: String?
    private var continuations: [UUID: AsyncStream<State>.Continuation] = [:]
    /// The cached, current mirror. Seeded in `init` from the passed source so
    /// `getSnapshot()` is correct BEFORE `start()`/any publish, then recomputed
    /// from the session on every `publish()`.
    private var currentState: State
    /// Pumps the session's revisioned snapshot stream into `publish()`.
    private var pump: Task<Void, Never>?

    public init(source: String, fileURL: URL? = nil, encoding: String.Encoding = .utf8) {
        let session = DocumentSession(source: source, fileURL: fileURL, encoding: encoding)
        self.session = session
        // Seed the cached mirror from the REAL source so getSnapshot() reflects
        // it before start() ever runs. A freshly-opened session is clean: not
        // dirty, no conflict, attached, revision 0, empty undo/redo.
        self.currentState = State(
            document: MarkdownConverter.parse(source),
            contentRevision: 0,
            undoState: DocumentSession.UndoState(undoActionName: nil, redoActionName: nil),
            fileURL: fileURL,
            hasUnsavedChanges: false,
            hasUnresolvedConflict: false,
            conflictDiskSource: nil,
            lastSaveError: nil,
            isDetached: false,
            version: 0)
    }

    /// Adopts an already-constructed `DocumentSession` so the core drives the
    /// SAME session an owner already built — the ONE-session-per-file guarantee
    /// (ledger #12). During the strangler-fig migration the shell's ReaderModel
    /// still holds a `session` reference AND wraps it in a core; both must be
    /// the identical instance, so the shell builds the session (open/detached/
    /// blank) and hands it here rather than letting the core open a second one.
    /// The seeded mirror is a fresh, clean open; a `publish()` after `start()`
    /// replaces it with the session's real surface, and because the shell awaits
    /// `start()` before reading `stateStream()`, that real state is what the
    /// first yielded mirror carries.
    public init(adopting session: DocumentSession) {
        self.session = session
        self.currentState = State(
            document: MarkdownConverter.parse(""),
            contentRevision: 0,
            undoState: DocumentSession.UndoState(undoActionName: nil, redoActionName: nil),
            fileURL: nil,
            hasUnsavedChanges: false,
            hasUnresolvedConflict: false,
            conflictDiskSource: nil,
            lastSaveError: nil,
            isDetached: false,
            version: 0)
    }

    /// Adopts an already-constructed `DocumentSession` (test-only seam so a
    /// session wired to a specific fixture file can be driven through the core
    /// without re-decoding).
    init(adoptingForTest session: DocumentSession) {
        self.init(adopting: session)
    }

    /// Cancel the snapshot pump if the core is dropped without `stop()` being
    /// called (Task-1 review: the pump `Task` otherwise leaks). A nonisolated
    /// deinit may read an actor-isolated stored property because no other
    /// reference can exist at deinit time. `stop()` remains the primary
    /// cancellation path; this is the backstop.
    deinit { pump?.cancel() }

    /// Convenience for opening from disk (mirrors `DocumentSession.open`);
    /// returns nil when the file is unreadable.
    public static func open(fileURL: URL) -> EditorCore? {
        guard (try? DocumentSession.open(fileURL: fileURL)) != nil else { return nil }
        // Re-open through the value initializer so the seeded mirror matches the
        // decoded source/encoding. (The session's decode already succeeded.)
        guard let data = try? FileCoordination.read(fileURL),
              let decoded = DocumentSession.decode(data) else { return nil }
        return EditorCore(source: decoded.source, fileURL: fileURL, encoding: decoded.encoding)
    }

    /// Begin bridging conflict/save-failure and the session snapshot stream
    /// into `State`, and publish an initial mirror. Idempotent.
    public func start() async {
        guard pump == nil else { return }
        await session.setConflictHandler { [weak self] disk in
            Task { await self?.setConflict(disk) }
        }
        // A silent save failure in an app with no Save button is data loss on
        // a timer: bridge the session's failure message into State so the
        // mirror can raise a sticky banner. Mirrors the conflict handler above.
        await session.setSaveFailureHandler { [weak self] message in
            Task { await self?.setSaveFailure(message) }
        }
        await session.startWatching()
        let stream = await session.revisionedSnapshots()
        pump = Task { [weak self] in
            for await _ in stream {
                await self?.publish()
            }
        }
        await publish()
    }

    /// The current cached mirror. Correct before and after `start()`.
    public func getSnapshot() -> State { currentState }

    /// A stream of `State` snapshots, starting with the current one.
    public func stateStream() -> AsyncStream<State> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(currentState)   // initial mirror
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    // MARK: - Lifecycle

    /// Tear the session down, saving first. Cancels the snapshot pump so a
    /// started-then-dropped core never leaks the `Task` (Task-1 review). After
    /// this the core is inert; `teardown` is awaitable, satisfying the Plan-1
    /// discard/flush mutual-exclusion invariant.
    public func stop(save: Bool) async {
        pump?.cancel()
        pump = nil
        await session.teardown(save: save)
    }

    /// Drop the document without ever writing it — `teardown(save: false)`.
    /// Never resurrects a file the user deleted out from under us.
    public func discard() async { await stop(save: false) }

    /// Force a synchronous save now, then republish so mirrors see the cleared
    /// dirty flag. Save failures surface through the session's failure handler.
    public func flush() async {
        try? await session.saveNow()
        await publish()
    }

    /// Whitespace-only emptiness, pipeline-inclusive: because callers await
    /// `apply`, and every mutation funnels through the `DocumentSession` FIFO,
    /// a read here reflects all applied edits (this is what the "Untitled
    /// document doesn't accumulate" GC relies on).
    public func currentlyEmpty() async -> Bool {
        (await session.document).source
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Edit pipeline

    /// The keystroke hot path. Defaults `publishSnapshot: false`, which means
    /// "don't publish ANYWHERE": neither the session nor the core emits a
    /// `State` — the caller renders synchronously from the RETURNED
    /// `QuoinDocument`. This is the pre-strangler keystroke behavior: the
    /// hottest path stays echo-free, so there is no per-keystroke `State` to
    /// ingest and no MainActor scheduling race to arbitrate. Programmatic ops
    /// pass `publishSnapshot: true` and DO publish so observers' mirrors
    /// advance. Rethrows `SessionError.staleEditBase` on base mismatch.
    @discardableResult
    public func apply(edit: SourceEdit, baseRevision: Int?, actionName: UndoActionName?,
                      publishSnapshot: Bool = false) async throws -> QuoinDocument {
        // Clear rule: a new edit supersedes a stale save failure. If THIS
        // edit's autosave also fails, the session's handler re-populates it on
        // the next publish. This matches the old sticky banner (a later
        // successful save/edit clears it) while keeping the state simple.
        lastSaveError = nil
        let doc = try await session.applyEdit(
            edit, baseRevision: baseRevision,
            publishSnapshot: publishSnapshot, actionName: actionName)
        // Respect the flag: `publishSnapshot: false` must not publish here
        // either, or the keystroke path re-acquires the echo this contract
        // exists to avoid.
        if publishSnapshot {
            await publish()
        }
        return doc
    }

    @discardableResult
    public func undo() async -> QuoinDocument? {
        let doc = try? await session.undo()
        await publish()
        return doc
    }

    @discardableResult
    public func redo() async -> QuoinDocument? {
        let doc = try? await session.redo()
        await publish()
        return doc
    }

    // MARK: - Conflict resolution

    /// Keep the in-memory version, discarding the disk change. Clears the
    /// cached conflict source (Task-1 review: it was set on conflict but never
    /// cleared → stale after resolution) and republishes.
    public func resolveConflictKeepingMine() async throws {
        try await session.resolveConflictKeepingMine()
        conflictDiskSource = nil
        await publish()
    }

    /// Take the on-disk version. Clears the cached conflict source and
    /// republishes.
    public func resolveConflictTakingDisk(_ disk: String) async {
        await session.resolveConflictTakingDisk(disk)
        conflictDiskSource = nil
        await publish()
    }

    // MARK: - Programmatic operations

    /// Format ▸ Tidy Blank Lines. Returns the new document (nil when nothing
    /// changed) and rethrows so the shell can restore the caret / recover from
    /// a failed edit exactly as it does for every other resolution.
    @discardableResult
    public func tidyBlankLines() async throws -> QuoinDocument? {
        let doc = try await session.applyTidyBlankLines()
        await publish()
        return doc
    }

    /// Toggle a task checkbox by its marker range.
    public func toggleTask(markerRange: ByteRange) async throws {
        try await session.toggleTask(markerRange: markerRange)
        await publish()
    }

    /// Accept/reject one suggestion mark. Returns nil when the range no longer
    /// parses as a whole mark (the caller re-renders with fresh ranges).
    @discardableResult
    public func applyResolution(
        markRange: ByteRange, action: SuggestionResolver.Action,
        expectedSlice: String? = nil
    ) async throws -> QuoinDocument? {
        let doc = try await session.applyResolution(
            markRange: markRange, action: action, expectedSlice: expectedSlice)
        await publish()
        return doc
    }

    /// Accept All / Reject All — one atomic edit, one undo.
    @discardableResult
    public func resolveAllSuggestions(action: SuggestionResolver.Action) async throws -> QuoinDocument? {
        let doc = try await session.applyBulkResolution(action: action)
        await publish()
        return doc
    }

    // MARK: - Front matter (Properties panel)

    /// Set or create one front-matter field (string value).
    @discardableResult
    public func setFrontMatterField(key: String, value: String) async throws -> QuoinDocument? {
        let doc = try await session.applyFrontMatterEdit(key: key, value: value)
        await publish()
        return doc
    }

    /// Set one front-matter field to a typed raw value (bool/number/date/flow).
    @discardableResult
    public func setTypedFrontMatterField(key: String, rawValue: String) async throws -> QuoinDocument? {
        let doc = try await session.applyTypedFrontMatterEdit(key: key, rawValue: rawValue)
        await publish()
        return doc
    }

    /// Remove one front-matter field.
    @discardableResult
    public func removeFrontMatterField(key: String) async throws -> QuoinDocument? {
        let doc = try await session.removeFrontMatterField(key: key)
        await publish()
        return doc
    }

    // MARK: - Test seams

    /// `@testable`-only: adopt new source wholesale through the session's
    /// external-apply path (bumps `contentRevision`, clears undo/redo), then
    /// republish. Used to simulate an out-of-band revision bump.
    func reloadForTest(source: String) async {
        await session.apply(source: source)
        await publish()
    }

    // MARK: - Private

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func setConflict(_ disk: String?) async {
        conflictDiskSource = disk
        await publish()
    }

    private func setSaveFailure(_ message: String) async {
        lastSaveError = message
        await publish()
    }

    /// Recompute `currentState` from the session, bump `version`, and yield to
    /// every registered continuation. All cross-actor reads are awaited here.
    private func publish() async {
        version += 1
        currentState = State(
            document: await session.document,
            contentRevision: await session.contentRevision,
            undoState: await session.undoState,
            fileURL: await session.fileURL,
            hasUnsavedChanges: await session.hasUnsavedChanges,
            hasUnresolvedConflict: await session.hasUnresolvedConflict,
            conflictDiskSource: conflictDiskSource,
            lastSaveError: lastSaveError,
            isDetached: await session.isDetached,
            version: version)
        for continuation in continuations.values {
            continuation.yield(currentState)
        }
    }
}
