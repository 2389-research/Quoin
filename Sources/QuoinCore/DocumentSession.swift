import Foundation

public enum SessionError: Error {
    case fileUnreadable(URL)
    case fileWriteFailed(URL, String)
    case taskNotTogglable
    /// A disk conflict is pending (external change landed while dirty);
    /// writing would clobber the version the user hasn't chosen against.
    case conflictUnresolved(URL)
    /// The edit was computed against a content revision the session has
    /// since replaced via a non-edit adoption (external reload); applying
    /// it would splice stale bytes at stale offsets.
    case staleEditBase(expected: Int, got: Int)
}

/// The single authority over one open document's source text.
///
/// Every input — the file watcher, a checkbox tap, and eventually an editor
/// pane — funnels through the same path: apply the mutation to the source,
/// re-parse, and publish a fresh immutable `QuoinDocument` snapshot. The UI
/// only ever consumes snapshots; it never touches the source directly. This
/// is the seam a future edit mode drops into.
public actor DocumentSession {

    public private(set) var document: QuoinDocument
    public private(set) var fileURL: URL?
    /// Set (via `setConflictHandler`) when an external change lands while
    /// local edits are unsaved; the UI shows a non-blocking merge banner
    /// (handoff rule) instead of silently replacing.
    private var onConflict: (@Sendable (String) -> Void)?
    /// Set (via `setSaveFailureHandler`) — a silent save failure in an app
    /// with no Save button is data loss on a timer (launch audit BLOCKER #2).
    private var onSaveFailure: (@Sendable (String) -> Void)?
    public private(set) var lastSaveError: SessionError?
    private var isDirty = false
    public var hasUnsavedChanges: Bool { isDirty }
    /// True from the moment an external change lands while dirty until the
    /// user picks a side. While set, NOTHING writes to disk — continued
    /// typing used to re-arm the debounced autosave and silently clobber
    /// the disk version while the banner asked the user to decide (launch
    /// ledger, data integrity #5).
    public private(set) var hasUnresolvedConflict = false
    /// True once the file has vanished from `fileURL` (moved or deleted
    /// externally and not followable). A detached session never writes:
    /// autosave silently recreating the dead path forked the document
    /// (launch ledger, data integrity #6). `relocate(to:)` re-attaches.
    public private(set) var isDetached = false
    private var vanishCheckTask: Task<Void, Never>?
    /// Dedupes the save-failure banner while typing into a detached session.
    private var didReportDetachedEdit = false
    /// Bumped on every NON-edit content adoption (external reload, conflict
    /// resolution, wholesale apply) AND on every undo/redo splice (ledger
    /// #7). Edits carry the revision they were computed against; a mismatch
    /// at apply time means the content changed underneath and the edit's
    /// offsets are meaningless (launch ledger, data integrity #14).
    /// Ordinary edits do NOT bump it — a typing burst stays valid across
    /// its own in-flight edits.
    public private(set) var contentRevision = 0

    private var watcher: FileWatcher?
    /// The app's registered `NSFilePresenter` for this document (#32), paired
    /// with `watcher` over the same lifetime. Held in a `Sendable` handle
    /// (not a bare stored property) for one reason: `NSFileCoordinator`
    /// retains a registered presenter STRONGLY, so the presenter's own deinit
    /// can't be the deregistration backstop — the session's nonisolated deinit
    /// must call `removeFilePresenter`, and a nonisolated deinit may only touch
    /// `Sendable` stored state. The handle is a no-op holder on Linux (the
    /// presenter class doesn't exist there). See `DocumentFilePresenter` for
    /// the replace-vs-complement rationale.
    private let presenterHandle = FilePresenterHandle()
    private var continuations: [UUID: AsyncStream<QuoinDocument>.Continuation] = [:]
    /// Hash of content we ourselves just wrote, so the resulting file-system
    /// event is recognized as self-inflicted and not re-published.
    private var selfWriteHash: String?
    /// Hash of what we last KNEW to be on disk — the content we opened, last
    /// wrote, or last adopted from an external change. A watcher/presenter
    /// event whose disk bytes match this is NOT an external edit (it's a
    /// spurious vnode notification: a metadata touch, or a freshly-created
    /// file's own creation event arriving after we began watching), so it must
    /// NOT raise a conflict — even when we hold unsaved edits. Our in-memory
    /// content legitimately diverges from disk between a keystroke and the
    /// debounced autosave; comparing the disk against THIS baseline (not against
    /// the diverged in-memory hash) is what keeps a new/just-opened document
    /// from flashing a false "changed on disk" banner on the first keystroke.
    private var lastKnownDiskHash: String
    /// The disk hash last surfaced to the conflict banner. A single external
    /// write can reach the session twice — once via `FileWatcher`, once via
    /// the file presenter — and the banner must not re-fire for the same disk
    /// version. Cleared whenever the conflict is resolved.
    private var conflictOfferedHash: String?
    /// One undoable step: the inverse edit that reverses it, plus the label
    /// the Edit menu shows ("Undo Typing" / "Undo Move Block"). The name
    /// rides with the entry through undo→redo→undo so the menu stays honest
    /// as the step moves between the two stacks.
    private struct HistoryEntry { var edit: SourceEdit; let name: UndoActionName }
    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []
    /// Typing-coalescing state: while a run of single-character, contiguous,
    /// same-direction, non-whitespace edits continues, each one EXTENDS the
    /// top undo entry instead of pushing a new one — so ⌘Z undoes a word, not
    /// a letter. Any other edit, a whitespace, a caret jump (non-contiguous
    /// offset), or any out-of-band document change breaks the run.
    private struct TypingRun { enum Kind { case insert, delete }; let kind: Kind; let nextOffset: Int }
    private var typingRun: TypingRun?
    private var autosaveTask: Task<Void, Never>?
    /// Debounce for keystroke-driven autosave; checkbox toggles still write
    /// immediately.
    private let autosaveDelay: Duration = .milliseconds(400)

    // MARK: - Lifecycle

    /// The encoding the file was read in, so a save writes it back the SAME
    /// way instead of silently converting (e.g. a UTF-16 note stays UTF-16).
    /// Defaults to UTF-8; updated on open and on external reload.
    public private(set) var fileEncoding: String.Encoding = .utf8

    public init(source: String, fileURL: URL? = nil, encoding: String.Encoding = .utf8) {
        self.document = MarkdownConverter.parse(source)
        self.fileURL = fileURL
        self.fileEncoding = encoding
        // The source we open with IS what's on disk — seed the baseline so a
        // spurious watcher event before the first save can't read as a conflict.
        self.lastKnownDiskHash = SHA256Hex.hash(of: source)
    }

    /// Decode file bytes to a source string, detecting the encoding. UTF-8 is
    /// the overwhelming default; a BOM is unambiguous; the legacy single-byte
    /// fallbacks let a `.md` another tool wrote in UTF-16 or Latin-1 OPEN
    /// instead of being rejected as unreadable (which reads as data loss). The
    /// returned encoding lets a save round-trip the file in the same encoding.
    public static func decode(_ data: Data) -> (source: String, encoding: String.Encoding)? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),                       // UTF-8 BOM
           let s = String(data: data.dropFirst(3), encoding: .utf8) { return (s, .utf8) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), // UTF-16 BOM
           let s = String(data: data, encoding: .utf16) { return (s, .utf16) }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        if let s = String(data: data, encoding: .windowsCP1252) { return (s, .windowsCP1252) }
        if let s = String(data: data, encoding: .isoLatin1) { return (s, .isoLatin1) }
        return nil
    }

    /// Opens a file and starts watching it for external changes.
    public static func open(fileURL: URL) throws -> DocumentSession {
        guard let data = try? FileCoordination.read(fileURL),
              let decoded = decode(data)
        else { throw SessionError.fileUnreadable(fileURL) }
        return DocumentSession(source: decoded.source, fileURL: fileURL, encoding: decoded.encoding)
    }

    /// Deregisters the file presenter if the session is torn down without an
    /// explicit `stopWatching`. `NSFileCoordinator` retains the presenter
    /// strongly, so this — not the presenter's own deinit — is the reliable
    /// backstop. Legal from a nonisolated deinit because `presenterHandle` is
    /// a `Sendable let`, and its `removeAndClear()` is thread-safe and
    /// idempotent.
    deinit {
        presenterHandle.removeAndClear()
    }

    /// Begins publishing snapshots for external file changes. Idempotent.
    /// Registers both the kqueue `FileWatcher` (catches uncoordinated writers)
    /// and the `NSFilePresenter` (coordinated participation, #32) over one
    /// lifetime.
    public func startWatching() {
        guard watcher == nil, let fileURL else { return }
        let newWatcher = FileWatcher(
            url: fileURL,
            onChange: { [weak self] in
                guard let self else { return }
                Task { await self.reloadFromDisk() }
            },
            onRelocate: { [weak self] newURL in
                guard let self else { return }
                Task { await self.followExternalMove(to: newURL) }
            }
        )
        watcher = newWatcher
        newWatcher.start()
        registerPresenter()
    }

    public func stopWatching() {
        watcher?.cancel()
        watcher = nil
        unregisterPresenter()
    }

    /// Registers a presenter with `NSFileCoordinator` for the current
    /// `fileURL`. No-op on Linux and when already registered.
    private func registerPresenter() {
        #if canImport(Darwin)
        guard presenterHandle.current == nil, let fileURL else { return }
        let presenter = DocumentFilePresenter(session: self, url: fileURL)
        presenterHandle.set(presenter)
        NSFileCoordinator.addFilePresenter(presenter)
        #endif
    }

    /// Deregisters and drops the presenter. No-op when none is registered.
    private func unregisterPresenter() {
        presenterHandle.removeAndClear()
    }

    // MARK: - File-presenter callbacks (bridged onto the actor)

    /// A coordinated writer changed the file's contents. Funnels into the
    /// same idempotent reload as the watcher; the hash guard collapses the
    /// duplicate into a no-op.
    func presenterDidObserveChange() {
        reloadFromDisk()
    }

    /// The file moved through coordination. Shares the watcher's
    /// move-following path (which also re-points the presenter).
    func presenterDidObserveMove(to url: URL) {
        followExternalMove(to: url)
    }

    /// The file is being deleted through coordination. Route into the same
    /// vanish confirmation the watcher uses; a transient replace re-attaches,
    /// a real delete detaches.
    func presenterDidObserveDeletion() {
        guard let fileURL, !isDetached else { return }
        scheduleVanishCheck(for: fileURL)
    }

    public func setConflictHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onConflict = handler
    }

    /// Called whenever a save (including debounced autosave) fails — a
    /// silent save failure in an app with no Save button is data loss on
    /// a timer (launch audit BLOCKER #2).
    public func setSaveFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onSaveFailure = handler
    }

    /// Follows a file rename (first-H1-renames-file): future saves and
    /// watching target the new URL. Also re-attaches a detached session.
    public func relocate(to url: URL) {
        let wasWatching = watcher != nil || isDetached
        stopWatching()
        vanishCheckTask?.cancel()
        vanishCheckTask = nil
        isDetached = false
        didReportDetachedEdit = false
        fileURL = url
        if wasWatching { startWatching() }
    }

    /// The watcher followed a live inode to its new path (external move):
    /// adopt the new URL so saves keep targeting the user's file instead of
    /// resurrecting the old name. The watcher has already re-armed itself.
    private func followExternalMove(to url: URL) {
        // Idempotent: the watcher (kqueue) and the presenter can each report
        // the same move. Compare symlink-resolved paths (F_GETPATH already
        // returns a resolved path) so a no-op move is dropped and the second
        // reporter doesn't needlessly re-register the presenter.
        guard fileURL?.resolvingSymlinksInPath().path
            != url.resolvingSymlinksInPath().path else { return }
        vanishCheckTask?.cancel()
        vanishCheckTask = nil
        isDetached = false
        didReportDetachedEdit = false
        fileURL = url
        // Re-point the presenter (if any) at the new location so the app
        // stays a registered presenter for the moved file. The watcher
        // re-armed its own descriptor; the presenter must be re-added under
        // the new URL. No-op on Linux (the handle is always empty there).
        if presenterHandle.current != nil {
            unregisterPresenter()
            registerPresenter()
        }
    }

    // MARK: - Snapshots

    /// A stream of document snapshots, starting with the current one.
    public func snapshots() -> AsyncStream<QuoinDocument> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(document)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    /// A published document paired with the session's non-edit adoption
    /// counter, so consumers can stamp the edits they compute against it
    /// (see `applyEdit(_:baseRevision:publishSnapshot:)`). Yielding both
    /// atomically avoids the read-back race a separate query would have.
    public struct RevisionedSnapshot: Sendable {
        public let document: QuoinDocument
        public let contentRevision: Int
    }

    private var revisionedContinuations: [UUID: AsyncStream<RevisionedSnapshot>.Continuation] = [:]

    /// Like `snapshots()`, but each element carries `contentRevision`.
    public func revisionedSnapshots() -> AsyncStream<RevisionedSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            revisionedContinuations[id] = continuation
            continuation.yield(RevisionedSnapshot(document: document, contentRevision: contentRevision))
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeRevisionedContinuation(id) }
            }
        }
    }

    private func removeRevisionedContinuation(_ id: UUID) {
        revisionedContinuations[id] = nil
    }

    private func publish(_ newDocument: QuoinDocument) {
        document = newDocument
        for continuation in continuations.values {
            continuation.yield(newDocument)
        }
        let revisioned = RevisionedSnapshot(document: newDocument, contentRevision: contentRevision)
        for continuation in revisionedContinuations.values {
            continuation.yield(revisioned)
        }
    }

    /// Adopts content that did NOT come through the edit path (external
    /// reload, conflict resolution, wholesale apply, toggle re-anchor on
    /// changed disk content). The undo/redo stacks hold byte-offset edits
    /// computed against the OLD source; replaying one against adopted
    /// content splices stale bytes at stale offsets — and autosave then
    /// persists the corruption (launch ledger, data integrity #3).
    /// Clearing both stacks is the safe rebase.
    private func adoptExternal(_ newDocument: QuoinDocument) {
        undoStack.removeAll()
        redoStack.removeAll()
        typingRun = nil
        contentRevision += 1
        publish(newDocument)
    }

    // MARK: - Mutations

    /// Reloads from disk after an external change. No-ops when the content
    /// is unchanged or was written by this session (checkbox write-back).
    /// When the file has vanished from its path, schedules a confirmation
    /// check (atomic replaces briefly unlink the path) and then detaches.
    public func reloadFromDisk() {
        guard let fileURL else { return }
        guard let data = try? FileCoordination.read(fileURL, filePresenter: presenterHandle.current),
              let decoded = Self.decode(data)
        else {
            scheduleVanishCheck(for: fileURL)
            return
        }
        let source = decoded.source
        fileEncoding = decoded.encoding  // an external re-save may have changed it
        vanishCheckTask?.cancel()
        vanishCheckTask = nil
        if isDetached {
            // The path is readable again (file restored): re-attach.
            isDetached = false
            didReportDetachedEdit = false
        }

        let hash = SHA256Hex.hash(of: source)
        if hash == document.sourceHash { return }
        if hash == selfWriteHash {
            selfWriteHash = nil
            lastKnownDiskHash = hash
            return
        }
        // The disk still holds exactly what we last knew was there — this event
        // is spurious (a metadata touch, or the file's own creation event
        // arriving after we began watching), NOT an external edit. Do nothing,
        // even while dirty: unsaved in-memory edits legitimately diverge from
        // disk until autosave, and that divergence is not a conflict. (This is
        // the guard that stops a brand-new document from flashing the merge
        // banner on the first keystroke.)
        if hash == lastKnownDiskHash { return }
        // Clean → reload silently. Dirty → surface a merge banner instead
        // of clobbering unsaved local edits. The pending autosave is
        // cancelled so it can't overwrite the disk version while the user
        // decides.
        if isDirty {
            // One external write can reach here twice (watcher + presenter).
            // If the banner is already up for this exact disk version, don't
            // re-fire it. A genuinely NEWER disk version (different hash) does
            // re-fire so the banner reflects the latest bytes.
            if hasUnresolvedConflict, conflictOfferedHash == hash { return }
            hasUnresolvedConflict = true
            conflictOfferedHash = hash
            autosaveTask?.cancel()
            onConflict?(source)
            return
        }
        lastKnownDiskHash = hash
        adoptExternal(MarkdownConverter.parse(source))
    }

    /// The file couldn't be read at its path. That's either an atomic
    /// replace mid-flight (the path comes back within milliseconds) or a
    /// real external move/delete. Confirm after a short delay before
    /// declaring the session detached.
    private func scheduleVanishCheck(for url: URL) {
        guard !isDetached, vanishCheckTask == nil else { return }
        vanishCheckTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self.confirmVanished(expecting: url)
        }
    }

    private func confirmVanished(expecting url: URL) {
        vanishCheckTask = nil
        guard fileURL == url, !isDetached else { return }
        if let data = try? FileCoordination.read(url, filePresenter: presenterHandle.current), Self.decode(data) != nil {
            // Transient (mid-replace): route through the normal reload so
            // the hash/conflict logic applies.
            reloadFromDisk()
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            // Exists but unreadable (encoding/permissions) — not a vanish.
            return
        }
        // The file is gone from its path. This session must never write the
        // dead path back into existence (ledger #6): cancel the pending
        // autosave and block future ones. The watcher keeps retrying the
        // path, so a restored file re-attaches automatically; an external
        // MOVE never reaches here because the watcher follows the inode.
        isDetached = true
        autosaveTask?.cancel()
        autosaveTask = nil
        if isDirty {
            didReportDetachedEdit = true
            onSaveFailure?(
                "“\(url.lastPathComponent)” was moved or deleted outside Quoin. "
                + "Your edits are held in memory — saving is paused until the file returns.")
        }
    }

    /// Merge-banner resolution: overwrite disk with the local version.
    public func resolveConflictKeepingMine() throws {
        hasUnresolvedConflict = false
        conflictOfferedHash = nil
        try saveNow()
    }

    /// Merge-banner resolution: adopt the on-disk version, discarding
    /// unsaved local edits.
    public func resolveConflictTakingDisk(_ diskSource: String) {
        hasUnresolvedConflict = false
        conflictOfferedHash = nil
        isDirty = false
        lastSaveError = nil
        autosaveTask?.cancel()
        lastKnownDiskHash = SHA256Hex.hash(of: diskSource)  // disk is now the baseline
        adoptExternal(MarkdownConverter.parse(diskSource))
    }

    /// Applies new source text wholesale (no undo tracking; external inputs).
    public func apply(source: String) {
        guard SHA256Hex.hash(of: source) != document.sourceHash else { return }
        adoptExternal(MarkdownConverter.parse(source))
    }

    // MARK: - Editing

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// The label for the step ⌘Z would reverse next (nil when there is
    /// nothing to undo) — drives the Edit ▸ Undo item's title and enablement.
    public var undoActionName: UndoActionName? { undoStack.last?.name }
    /// The label for the step ⇧⌘Z would re-apply next (nil when the redo
    /// stack is empty).
    public var redoActionName: UndoActionName? { redoStack.last?.name }

    /// A single read of everything the Edit menu needs, so the UI hops onto
    /// the actor once per refresh instead of four times.
    public struct UndoState: Sendable, Equatable {
        public let undoActionName: UndoActionName?
        public let redoActionName: UndoActionName?
        public var canUndo: Bool { undoActionName != nil }
        public var canRedo: Bool { redoActionName != nil }
    }
    public var undoState: UndoState {
        UndoState(undoActionName: undoStack.last?.name, redoActionName: redoStack.last?.name)
    }

    /// The editor's keystroke path: apply a byte-precise edit, re-parse,
    /// publish, and schedule a debounced autosave. Returns the new document
    /// so callers can restore the caret synchronously.
    ///
    /// `baseRevision` is the `contentRevision` of the snapshot the edit's
    /// byte offsets were computed against (see `revisionedSnapshots()`).
    /// When an external reload has replaced the content in the meantime,
    /// the edit is rejected instead of spliced at stale offsets (ledger
    /// #14). Pass nil only for callers that provably operate on the
    /// session's own current document.
    /// `actionName` labels the resulting undo step for the Edit menu. Pass
    /// nil for edits that carry no explicit intent (typing, format, paste):
    /// the name is then inferred from the edit's shape. Intentful commands
    /// (Move Block, Resolve Suggestion, Edit Properties…) pass their own.
    @discardableResult
    public func applyEdit(
        _ edit: SourceEdit, baseRevision: Int? = nil, publishSnapshot: Bool = true,
        actionName: UndoActionName? = nil
    ) throws -> QuoinDocument {
        if let baseRevision, baseRevision != contentRevision {
            throw SessionError.staleEditBase(expected: contentRevision, got: baseRevision)
        }
        let parsed = try MarkdownConverter.parseAfterEdit(previous: document, edit: edit)
        recordUndo(edit: edit, inverse: parsed.inverse, actionName: actionName)  // reads pre-edit `document`
        if publishSnapshot {
            publish(parsed.document)
        } else {
            document = parsed.document
        }
        scheduleAutosave()
        return document
    }

    /// Push (or coalesce) the inverse of `edit` onto the undo stack. Called
    /// from `applyEdit` while `document` is still the PRE-edit snapshot, so the
    /// deleted text can be read for the whitespace check. A run of contiguous
    /// single-character same-direction non-whitespace edits collapses into one
    /// undo entry; anything else starts a fresh group.
    private func recordUndo(edit: SourceEdit, inverse: SourceEdit, actionName: UndoActionName?) {
        redoStack.removeAll()

        let insertLen = edit.replacement.utf8.count
        let isInsert = edit.range.length == 0 && edit.replacement.count == 1
            && !(edit.replacement.first?.isWhitespace ?? true)
        let deleted = edit.replacement.isEmpty ? document.source.substring(in: edit.range) : nil
        let isDelete = (deleted?.count == 1) && !((deleted?.first?.isWhitespace) ?? true)

        // The step's Edit-menu label: an explicit intent wins; otherwise it is
        // inferred from the edit's shape (single char → Typing, else Edit).
        let name = actionName ?? UndoActionName.inferred(
            replacementIsInsert: edit.range.length == 0,
            replacementCount: edit.replacement.count,
            deletedCount: edit.replacement.isEmpty ? (deleted?.count ?? 0) : 0)

        // Only coalesce anonymous typing — an intentful command (even a
        // one-character one) always starts its own, named, undo group.
        let coalescible = actionName == nil

        // Continue an insertion run: extend the top delete-inverse by one char.
        if coalescible, isInsert, let run = typingRun, run.kind == .insert,
           edit.range.offset == run.nextOffset, let top = undoStack.last {
            undoStack[undoStack.count - 1] = HistoryEntry(
                edit: SourceEdit(
                    range: ByteRange(offset: top.edit.range.offset, length: top.edit.range.length + insertLen),
                    replacement: ""),
                name: top.name)
            typingRun = TypingRun(kind: .insert, nextOffset: edit.range.offset + insertLen)
            return
        }
        // Continue a backspace run: prepend this char to the top insert-inverse.
        if coalescible, isDelete, let run = typingRun, run.kind == .delete,
           edit.range.upperBound == run.nextOffset, let top = undoStack.last {
            undoStack[undoStack.count - 1] = HistoryEntry(
                edit: SourceEdit(
                    range: ByteRange(offset: inverse.range.offset, length: 0),
                    replacement: inverse.replacement + top.edit.replacement),
                name: top.name)
            typingRun = TypingRun(kind: .delete, nextOffset: edit.range.offset)
            return
        }

        // New group; arm a fresh run only for a coalescible typing edit.
        undoStack.append(HistoryEntry(edit: inverse, name: name))
        if coalescible, isInsert {
            typingRun = TypingRun(kind: .insert, nextOffset: edit.range.offset + insertLen)
        } else if coalescible, isDelete {
            typingRun = TypingRun(kind: .delete, nextOffset: edit.range.offset)
        } else {
            typingRun = nil
        }
    }

    /// Append `text` to the end of the document as its own line(s) — the App
    /// Intents "Append Text to Note" path. The edit is COMPUTED IN-ACTOR
    /// against the session's CURRENT source (the `applyResolution` pattern), so
    /// its end-of-source offset can never go stale, and it flows through the
    /// same `applyEdit` pipeline as a keystroke: re-parse, publish, autosave —
    /// a real, undoable, byte-lossless edit, never a raw file rewrite. Returns
    /// nil when `text` has nothing to append (empty/whitespace-only).
    @discardableResult
    public func appendText(_ text: String, publishSnapshot: Bool = true) throws -> QuoinDocument? {
        guard let edit = DocumentAppend.appendEdit(appending: text, to: document.source) else {
            return nil
        }
        return try applyEdit(edit, publishSnapshot: publishSnapshot, actionName: .append)
    }

    // MARK: - Suggestion resolution (computed in-actor, so offsets can't go stale)

    /// Accept/reject ONE mark atomically: the combined mark+record edit is
    /// computed against the session's CURRENT source, inside the actor —
    /// never against a projection snapshot (panel review BLOCKER: two quick
    /// Accepts each computed offsets against the pre-first-resolution
    /// source; the second spliced mid-mark and corrupted the document, and
    /// autosave persisted it). Returns nil when the bytes at `markRange` no
    /// longer parse as one whole mark — the document changed since the card
    /// was rendered; the caller surfaces that, and the re-rendered panel
    /// carries fresh ranges for the next click.
    @discardableResult
    public func applyResolution(
        markRange: ByteRange, action: SuggestionResolver.Action,
        expectedSlice: String? = nil, publishSnapshot: Bool = true
    ) throws -> QuoinDocument? {
        // Identity check (review LOW): the range alone can point at a
        // DIFFERENT equal-length whole mark after an intervening edit —
        // resolving it would accept/reject the wrong suggestion. When the
        // caller knows the bytes the card was rendered from, require them
        // to still be there; a mismatch refuses (the re-rendered panel
        // carries fresh ranges).
        if let expectedSlice {
            let bytes = Array(document.source.utf8)
            guard markRange.offset >= 0,
                  markRange.offset + markRange.length <= bytes.count,
                  String(decoding: bytes[markRange.offset..<(markRange.offset + markRange.length)],
                         as: UTF8.self) == expectedSlice
            else { return nil }
        }
        guard let edit = SuggestionResolver.combinedResolutionEdit(
            resolving: markRange, in: document.source, action: action) else { return nil }
        return try applyEdit(edit, publishSnapshot: publishSnapshot, actionName: .suggestion)
    }

    /// Accept All / Reject All — one atomic edit, one undo (suggestions
    /// design §3.5), with the same in-actor computation guarantee. Nil when
    /// there is nothing left to resolve.
    @discardableResult
    public func applyBulkResolution(
        action: SuggestionResolver.Action, publishSnapshot: Bool = true
    ) throws -> QuoinDocument? {
        guard let edit = SuggestionResolver.resolveAllEdit(
            in: document.source, action: action) else { return nil }
        return try applyEdit(edit, publishSnapshot: publishSnapshot, actionName: .bulkSuggestion)
    }

    /// Hoisted out of `applyAnnotation` — allocating a formatter per annotation
    /// is pure waste (QoL #34). Only `string(from:)` is called (never a config
    /// mutation), which is safe to share across the actor's calls, so the
    /// non-Sendable formatter is marked `nonisolated(unsafe)`.
    nonisolated(unsafe) private static let timestampFormatter = ISO8601DateFormatter()

    /// CREATE an annotation (S3a selection gestures): comment, suggested
    /// replacement/deletion/insertion, or highlight — one atomic edit
    /// (mark + endmatter entry), computed in-actor with the same
    /// guarantees as `applyResolution`. `expectedSlice` is the text the
    /// user SAW selected: if the bytes at `range` no longer match (an
    /// edit landed since the gesture), the annotation refuses instead of
    /// wrapping the wrong text.
    @discardableResult
    public func applyAnnotation(
        kind: ReviewAuthoring.Kind, range: ByteRange, expectedSlice: String,
        reviewer: String, publishSnapshot: Bool = true
    ) throws -> QuoinDocument? {
        let bytes = Array(document.source.utf8)
        guard range.offset >= 0, range.offset + range.length <= bytes.count,
              String(decoding: bytes[range.offset..<(range.offset + range.length)],
                     as: UTF8.self) == expectedSlice
        else { return nil }
        let timestamp = Self.timestampFormatter.string(from: Date())
        guard let edit = ReviewAuthoring.annotationEdit(
            kind: kind, range: range, in: document.source,
            reviewer: reviewer, timestamp: timestamp) else { return nil }
        let name: UndoActionName
        switch kind {
        case .comment, .blockComment: name = .comment
        case .highlight: name = .highlight
        case .replacement, .deletion, .insertion: name = .suggestedEdit
        }
        return try applyEdit(edit, publishSnapshot: publishSnapshot, actionName: name)
    }

    // MARK: - Front-matter fields (Properties panel, #70 — computed in-actor)

    /// Sets or creates one front-matter field: replace the key's line,
    /// append before the closing `---`, or create the whole block at byte
    /// 0 when the document has none. The edit is computed against the
    /// session's CURRENT source at apply time (the `applyResolution`
    /// pattern — never compute-then-queue), so a landed edit can't shift
    /// its offsets. One edit, one undo. Nil means the writer refused
    /// (complex value under that key, unsafe key, failed self-calibration)
    /// — no splice happened; the caller surfaces that.
    @discardableResult
    public func applyFrontMatterEdit(
        key: String, value: String, publishSnapshot: Bool = true
    ) throws -> QuoinDocument? {
        guard let edit = FrontMatterEditing.setFieldEdit(
            key: key, value: value, in: document.source) else { return nil }
        return try applyEdit(edit, publishSnapshot: publishSnapshot, actionName: .properties)
    }

    /// Sets one front-matter field to a TYPED raw value (bool/number/date
    /// scalar or flow list, #79) written verbatim — the Properties panel's
    /// typed editors. Same in-actor computation and one-undo guarantees as
    /// `applyFrontMatterEdit`; nil means the writer refused (not a clean
    /// typed form, block collection under that key, failed
    /// self-calibration).
    @discardableResult
    public func applyTypedFrontMatterEdit(
        key: String, rawValue: String, publishSnapshot: Bool = true
    ) throws -> QuoinDocument? {
        guard let edit = FrontMatterEditing.setTypedFieldEdit(
            key: key, rawValue: rawValue, in: document.source) else { return nil }
        return try applyEdit(edit, publishSnapshot: publishSnapshot, actionName: .properties)
    }

    /// Removes one front-matter field (nested continuation lines ride
    /// along); removing the last field removes the whole block. Same
    /// in-actor computation and one-undo guarantees as
    /// `applyFrontMatterEdit`.
    @discardableResult
    public func removeFrontMatterField(
        key: String, publishSnapshot: Bool = true
    ) throws -> QuoinDocument? {
        guard let edit = FrontMatterEditing.removeFieldEdit(
            key: key, in: document.source) else { return nil }
        return try applyEdit(edit, publishSnapshot: publishSnapshot, actionName: .properties)
    }

    @discardableResult
    public func undo() throws -> QuoinDocument? {
        guard let entry = undoStack.popLast() else { return nil }
        typingRun = nil
        let (newSource, inverse) = try entry.edit.apply(to: document.source)
        // The name rides with the step so redoing it reads "Redo <same name>".
        redoStack.append(HistoryEntry(edit: inverse, name: entry.name))
        // A history splice changes content OUTSIDE the in-flight edit
        // stream — exactly like an external adoption, any edit whose byte
        // offsets were computed against the pre-undo snapshot is
        // meaningless afterward. Bumping the revision makes `applyEdit`
        // REJECT such an edit (`staleEditBase`) instead of splicing it at
        // pre-undo offsets (launch ledger, data integrity #7). The model
        // serializes undo/redo behind its edit pipeline too; this is the
        // backstop for any ordering that slips past it.
        contentRevision += 1
        publish(MarkdownConverter.parse(newSource))
        scheduleAutosave()
        return document
    }

    @discardableResult
    public func redo() throws -> QuoinDocument? {
        guard let entry = redoStack.popLast() else { return nil }
        typingRun = nil
        let (newSource, inverse) = try entry.edit.apply(to: document.source)
        undoStack.append(HistoryEntry(edit: inverse, name: entry.name))
        // Same stale-edit rejection contract as undo (ledger #7).
        contentRevision += 1
        publish(MarkdownConverter.parse(newSource))
        scheduleAutosave()
        return document
    }

    /// Autosave-in-place, debounced across bursts of keystrokes. The write
    /// is atomic and marked self-inflicted so the file watcher stays quiet.
    private func scheduleAutosave() {
        guard fileURL != nil else { return }
        isDirty = true
        // Conflict pending: the edit is held in memory, but no write may
        // land until the user picks a side (ledger #5).
        guard !hasUnresolvedConflict else { return }
        // Detached (file vanished): writing would resurrect the dead path
        // and fork the document (ledger #6). If something reappeared at the
        // path since, route through reloadFromDisk — it re-attaches on
        // matching content and raises the conflict banner on foreign
        // content (we are dirty here by definition). Otherwise tell the
        // user once and hold the edit in memory.
        if isDetached {
            if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                reloadFromDisk()
            }
            if isDetached {
                if !didReportDetachedEdit {
                    didReportDetachedEdit = true
                    reportSaveFailure()
                }
                return
            }
            // Re-attach raised the merge banner instead; it owns the UI.
            guard !hasUnresolvedConflict else { return }
        }
        autosaveTask?.cancel()
        autosaveTask = Task { [autosaveDelay] in
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled else { return }
            do {
                try self.saveNow()
            } catch {
                // Retry once shortly (transient I/O), then tell the user —
                // never fail silently on the write path.
                try? await Task.sleep(for: .milliseconds(800))
                // A newer edit (or an explicit saveNow) cancels this task; the
                // sleep above is `try?`-swallowed, so without this guard a
                // CANCELLED autosave would still fire a stale write — a real
                // race, and the nondeterminism behind the flaky save-retry
                // tests under load (ADR 0007).
                guard !Task.isCancelled else { return }
                do {
                    try self.saveNow()
                } catch {
                    self.reportSaveFailure()
                }
            }
        }
    }

    private func reportSaveFailure() {
        guard let fileURL else { return }
        onSaveFailure?(
            "Couldn't save “\(fileURL.lastPathComponent)”. Your edits are held in memory — "
            + "check the disk or the file's permissions.")
    }

    public func saveNow() throws {
        guard let fileURL else { return }
        if isDetached, FileManager.default.fileExists(atPath: fileURL.path) {
            // Something is back at the path: re-attach through the normal
            // reload (adopts matching/clean content, raises the conflict
            // banner on foreign content while dirty).
            reloadFromDisk()
        }
        guard !hasUnresolvedConflict else {
            // Even an explicit flush (⌘Q drain) must not clobber the disk
            // side while the merge banner is unanswered.
            throw SessionError.conflictUnresolved(fileURL)
        }
        guard !isDetached else {
            // The file vanished from this path; recreating it would fork
            // the document (ledger #6).
            throw SessionError.fileWriteFailed(fileURL, "file was moved or deleted externally")
        }
        let source = document.source
        let wasDirty = isDirty
        do {
            try writeToDisk(source, to: fileURL)
            isDirty = false
            autosaveTask?.cancel()
            autosaveTask = nil
        } catch {
            if wasDirty { isDirty = true }
            throw error
        }
    }

    /// Atomically write `source` to `url`, record it as a self-write so the
    /// file watcher ignores the echo, and clear (or, on failure, set +
    /// rethrow) `lastSaveError`. Callers own the dirty-flag, autosave, and
    /// detached-session bookkeeping around this shared core.
    private func writeToDisk(_ source: String, to url: URL) throws {
        do {
            // Write back in the file's original encoding; only if the current
            // content can't be represented there (e.g. a Latin-1 file that now
            // holds an emoji) fall back to UTF-8 rather than fail the save.
            let data = source.data(using: fileEncoding) ?? Data(source.utf8)
            // Coordinated write (#32): serialize against the sync daemon so a
            // synced library doesn't spawn "conflicted copy" files. Passing
            // our own presenter excludes it from the coordination, so our save
            // never echoes to our own presentedItemDidChange.
            try FileCoordination.writeAtomic(data, to: url, filePresenter: presenterHandle.current)
            let written = SHA256Hex.hash(of: source)
            selfWriteHash = written
            lastKnownDiskHash = written  // disk now holds exactly this
            lastSaveError = nil
        } catch {
            let failure = SessionError.fileWriteFailed(url, String(describing: error))
            lastSaveError = failure
            throw failure
        }
    }

    /// Toggles a task checkbox and writes the change back to disk,
    /// byte-precise. If the file changed on disk since the last parse, it is
    /// re-read first and the toggle is re-validated against fresh content.
    public func toggleTask(markerRange: ByteRange) throws {
        let viewed = document

        typingRun = nil  // a toggle is out-of-band; it can't extend a typing run

        // A checkbox is still an edit: it must obey the same conflict guard
        // as saveNow, or a click quietly picks a side of an unanswered merge.
        if hasUnresolvedConflict, let fileURL {
            throw SessionError.conflictUnresolved(fileURL)
        }

        // The offset the UI sent is only meaningful against the render the
        // user clicked. Capture *which* task that was (by label + ordinal)
        // before touching disk, so a shifted file can't reroute the toggle.
        guard let intended = TaskLocator.identify(offset: markerRange.offset, in: viewed) else {
            throw SessionError.taskNotTogglable
        }

        var base = viewed
        var effectiveRange = markerRange

        // Conflict rule: if disk moved under us, re-parse and re-anchor by
        // identity — never by the stale offset.
        if let fileURL,
           let data = try? FileCoordination.read(fileURL, filePresenter: presenterHandle.current),
           let diskSource = Self.decode(data)?.source,
           SHA256Hex.hash(of: diskSource) != viewed.sourceHash {
            // Disk moved under us. If we ALSO hold unsaved local edits,
            // re-anchoring onto disk and toggling would silently throw those
            // edits away — raise the merge banner (exactly as the reload path
            // does when dirty) and refuse, rather than clobber.
            if isDirty {
                hasUnresolvedConflict = true
                conflictOfferedHash = SHA256Hex.hash(of: diskSource)
                autosaveTask?.cancel()
                onConflict?(diskSource)
                throw SessionError.conflictUnresolved(fileURL)
            }
            let fresh = MarkdownConverter.parse(diskSource)
            guard let relocated = TaskLocator.relocate(intended, in: fresh) else {
                // Can't prove which task the user meant. Surface the current
                // truth so they re-click on accurate content, then refuse.
                adoptExternal(fresh)
                throw SessionError.taskNotTogglable
            }
            base = fresh
            effectiveRange = relocated
        }

        let newSource = try TaskToggler.toggle(source: base.source, markerRange: effectiveRange)

        if let fileURL {
            guard !isDetached else {
                // A detached session's write would recreate the vanished
                // path and fork the document (ledger #6).
                throw SessionError.fileWriteFailed(fileURL, "file was moved or deleted externally")
            }
            try writeToDisk(newSource, to: fileURL)
        }
        if base.sourceHash != viewed.sourceHash {
            // The toggle was re-anchored onto content the user never edited
            // locally — an external adoption plus a toggle. Stale undo
            // offsets don't apply to it, and memory now equals disk, so any
            // pending conflict is resolved toward the disk side.
            hasUnresolvedConflict = false
            conflictOfferedHash = nil
            isDirty = false
            autosaveTask?.cancel()
            adoptExternal(MarkdownConverter.parse(newSource))
        } else {
            publish(MarkdownConverter.parse(newSource))
        }
    }
}
