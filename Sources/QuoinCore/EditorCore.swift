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
        public var isDetached: Bool
        /// Monotonic; bumps on every published `State` so mirrors never miss
        /// one.
        public var version: Int
    }

    private let session: DocumentSession
    private var version = 0
    private var conflictDiskSource: String?
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
            isDetached: false,
            version: 0)
    }

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
        // Save-failure surfacing is a later concern (it can flow through a
        // dedicated State field once lifecycle methods land). A no-op keeps the
        // handler registered without dropping data on the floor today.
        await session.setSaveFailureHandler { _ in }
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

    // MARK: - Private

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func setConflict(_ disk: String?) async {
        conflictDiskSource = disk
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
            isDetached: await session.isDetached,
            version: version)
        for continuation in continuations.values {
            continuation.yield(currentState)
        }
    }
}
