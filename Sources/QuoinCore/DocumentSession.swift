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
    private var continuations: [UUID: AsyncStream<QuoinDocument>.Continuation] = [:]
    /// Hash of content we ourselves just wrote, so the resulting file-system
    /// event is recognized as self-inflicted and not re-published.
    private var selfWriteHash: String?
    private var undoStack: [SourceEdit] = []
    private var redoStack: [SourceEdit] = []
    private var autosaveTask: Task<Void, Never>?
    /// Debounce for keystroke-driven autosave; checkbox toggles still write
    /// immediately.
    private let autosaveDelay: Duration = .milliseconds(400)

    // MARK: - Lifecycle

    public init(source: String, fileURL: URL? = nil) {
        self.document = MarkdownConverter.parse(source)
        self.fileURL = fileURL
    }

    /// Opens a file and starts watching it for external changes.
    public static func open(fileURL: URL) throws -> DocumentSession {
        guard let data = try? Data(contentsOf: fileURL),
              let source = String(data: data, encoding: .utf8)
        else { throw SessionError.fileUnreadable(fileURL) }
        return DocumentSession(source: source, fileURL: fileURL)
    }

    /// Begins publishing snapshots for external file changes. Idempotent.
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
    }

    public func stopWatching() {
        watcher?.cancel()
        watcher = nil
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
        vanishCheckTask?.cancel()
        vanishCheckTask = nil
        isDetached = false
        didReportDetachedEdit = false
        fileURL = url
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
        guard let data = try? Data(contentsOf: fileURL),
              let source = String(data: data, encoding: .utf8)
        else {
            scheduleVanishCheck(for: fileURL)
            return
        }
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
            return
        }
        // Clean → reload silently. Dirty → surface a merge banner instead
        // of clobbering unsaved local edits. The pending autosave is
        // cancelled so it can't overwrite the disk version while the user
        // decides.
        if isDirty {
            hasUnresolvedConflict = true
            autosaveTask?.cancel()
            onConflict?(source)
            return
        }
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
            await self.confirmVanished(expecting: url)
        }
    }

    private func confirmVanished(expecting url: URL) {
        vanishCheckTask = nil
        guard fileURL == url, !isDetached else { return }
        if let data = try? Data(contentsOf: url), String(data: data, encoding: .utf8) != nil {
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
        try saveNow()
    }

    /// Merge-banner resolution: adopt the on-disk version, discarding
    /// unsaved local edits.
    public func resolveConflictTakingDisk(_ diskSource: String) {
        hasUnresolvedConflict = false
        isDirty = false
        lastSaveError = nil
        autosaveTask?.cancel()
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
    @discardableResult
    public func applyEdit(
        _ edit: SourceEdit, baseRevision: Int? = nil, publishSnapshot: Bool = true
    ) throws -> QuoinDocument {
        if let baseRevision, baseRevision != contentRevision {
            throw SessionError.staleEditBase(expected: contentRevision, got: baseRevision)
        }
        let parsed = try MarkdownConverter.parseAfterEdit(previous: document, edit: edit)
        undoStack.append(parsed.inverse)
        redoStack.removeAll()
        if publishSnapshot {
            publish(parsed.document)
        } else {
            document = parsed.document
        }
        scheduleAutosave()
        return document
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
        return try applyEdit(edit, publishSnapshot: publishSnapshot)
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
        return try applyEdit(edit, publishSnapshot: publishSnapshot)
    }

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
        let timestamp = ISO8601DateFormatter().string(from: Date())
        guard let edit = ReviewAuthoring.annotationEdit(
            kind: kind, range: range, in: document.source,
            reviewer: reviewer, timestamp: timestamp) else { return nil }
        return try applyEdit(edit, publishSnapshot: publishSnapshot)
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
        return try applyEdit(edit, publishSnapshot: publishSnapshot)
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
        return try applyEdit(edit, publishSnapshot: publishSnapshot)
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
        return try applyEdit(edit, publishSnapshot: publishSnapshot)
    }

    @discardableResult
    public func undo() throws -> QuoinDocument? {
        guard let edit = undoStack.popLast() else { return nil }
        let (newSource, inverse) = try edit.apply(to: document.source)
        redoStack.append(inverse)
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
        guard let edit = redoStack.popLast() else { return nil }
        let (newSource, inverse) = try edit.apply(to: document.source)
        undoStack.append(inverse)
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
                try await self.saveNow()
            } catch {
                // Retry once shortly (transient I/O), then tell the user —
                // never fail silently on the write path.
                try? await Task.sleep(for: .milliseconds(800))
                do {
                    try await self.saveNow()
                } catch {
                    await self.reportSaveFailure()
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
            try Data(source.utf8).write(to: fileURL, options: .atomic)
            selfWriteHash = SHA256Hex.hash(of: source)
            isDirty = false
            lastSaveError = nil
            autosaveTask?.cancel()
            autosaveTask = nil
        } catch {
            if wasDirty { isDirty = true }
            let failure = SessionError.fileWriteFailed(fileURL, String(describing: error))
            lastSaveError = failure
            throw failure
        }
    }

    /// Toggles a task checkbox and writes the change back to disk,
    /// byte-precise. If the file changed on disk since the last parse, it is
    /// re-read first and the toggle is re-validated against fresh content.
    public func toggleTask(markerRange: ByteRange) throws {
        let viewed = document

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
           let data = try? Data(contentsOf: fileURL),
           let diskSource = String(data: data, encoding: .utf8),
           SHA256Hex.hash(of: diskSource) != viewed.sourceHash {
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
            do {
                try Data(newSource.utf8).write(to: fileURL, options: .atomic)
                selfWriteHash = SHA256Hex.hash(of: newSource)
                lastSaveError = nil
            } catch {
                let failure = SessionError.fileWriteFailed(fileURL, String(describing: error))
                lastSaveError = failure
                throw failure
            }
        }
        if base.sourceHash != viewed.sourceHash {
            // The toggle was re-anchored onto content the user never edited
            // locally — an external adoption plus a toggle. Stale undo
            // offsets don't apply to it, and memory now equals disk, so any
            // pending conflict is resolved toward the disk side.
            hasUnresolvedConflict = false
            isDirty = false
            autosaveTask?.cancel()
            adoptExternal(MarkdownConverter.parse(newSource))
        } else {
            publish(MarkdownConverter.parse(newSource))
        }
    }
}
