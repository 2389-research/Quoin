import Foundation
import SwiftUI
import QuoinCore
import QuoinRender

/// Owns the `DocumentSession` for one window and republishes its snapshots
/// as rendered output for SwiftUI — including the editor's syntax-reveal
/// state (active block + caret), which lives here because it must survive
/// each edit's re-parse round trip.
@MainActor
@Observable
final class ReaderModel {

    // Formerly @Published: with @Observable, plain stored properties are
    // observed automatically. Everything below the UI state is marked
    // @ObservationIgnored so exactly these properties drive view updates —
    // the same set that used to be @Published.
    private(set) var rendered: RenderedDocument = .empty
    private(set) var outline: [HeadingInfo] = []
    private(set) var stats = DocumentStats()
    private(set) var activeBlockID: BlockID?
    private(set) var caretInActiveBlock: Int?
    private(set) var caretGeneration = 0

    /// The current text selection mapped to a source byte range (nil when
    /// empty/unmappable), reported by the reader view. In-Selection replace
    /// scopes to it. Not observed: it changes on every selection move and no
    /// SwiftUI body depends on it directly.
    @ObservationIgnored var selectionSourceRange: ByteRange?
    /// The Edit menu's live Undo/Redo labels, mirrored from the session's
    /// stacks after every operation (nil = that stack is empty, so the item
    /// disables). The session is an actor; these observed copies let the menu
    /// read them synchronously and re-title/re-enable as history changes.
    private(set) var undoActionName: UndoActionName?
    private(set) var redoActionName: UndoActionName?

    /// Non-nil while an external change conflicts with unsaved local edits;
    /// holds the on-disk source for "use disk version".
    private(set) var conflictDiskSource: String?

    /// A transient, non-blocking failure from a user-triggered file action
    /// (image insert, checkbox toggle). Surfaced as a banner and auto-cleared
    /// — never a modal (handoff interaction style). Recording it in model
    /// state means the app can explain what didn't happen instead of failing
    /// silently, which is dangerous in a file-backed editor.
    private(set) var actionFailure: ActionFailure?

    struct ActionFailure: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }
    /// The document's current URL; changes when the first H1 renames an
    /// Untitled file (design rule).
    private(set) var fileURL: URL?

    /// The parsed document, read by the editor screen; it changes in lockstep
    /// with `rendered`, so it stays observed rather than ignored.
    private(set) var document: QuoinDocument = .empty

    /// Caret moved within the active block (view-side restyle already ran).
    /// Keeps this model's caret copy fresh so a model-initiated re-render
    /// mid-edit (async image decode) styles the reveal at the caret's real
    /// position — with a stale copy, the revealed span snapped back to the
    /// activation-time caret (editor-modes plan, 0.4). Writes the backing
    /// storage directly: this is bookkeeping, not a UI state change — going
    /// through the observed property would re-evaluate the SwiftUI body on
    /// every arrow key. Every flow that DOES need the view to react also
    /// bumps `caretGeneration`, which stays observed.
    func noteActiveCaretMoved(_ relativeCaret: Int) {
        guard activeBlockID != nil else { return }
        _caretInActiveBlock = relativeCaret
    }

    @ObservationIgnored var onFileRenamed: ((URL) -> Void)?
    /// The tab's last scroll + selection, stashed when its editor is torn down
    /// on a tab switch and handed back when the tab is shown again (#22). Lives
    /// here because the model outlives the transient editor in the store.
    @ObservationIgnored var savedViewport: ViewportSnapshot?

    @ObservationIgnored private var session: DocumentSession?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var renderer = AttributedRenderer()
    /// The active reveal's held last-good preview (mermaid/math). SESSION
    /// state owned here — the renderer takes it as an explicit inout and
    /// holds nothing (editor-modes plan, 1.1). Reset on every activation
    /// change so a stale artifact can never appear over foreign source.
    @ObservationIgnored private var heldPreview: AttributedRenderer.HeldPreview?
    @ObservationIgnored private var renameTask: Task<Void, Never>?
    @ObservationIgnored private var actionFailureTask: Task<Void, Never>?
    @ObservationIgnored private var editPipelineTask: Task<Void, Never>?
    @ObservationIgnored private var latestEditGeneration = 0
    /// Mirror of the session's non-edit adoption counter, taken from the
    /// snapshot each rendered document was built from. Every edit this
    /// model computes is stamped with it, so an external reload that lands
    /// between computing an edit and the session applying it makes the
    /// session REJECT the edit instead of splicing stale offsets (launch
    /// ledger, data integrity #14).
    @ObservationIgnored private var sessionContentRevision = 0
    /// Monotonic revision stamped on every published RenderedDocument, so
    /// the view layer applies each projection (and its storage patches)
    /// exactly once.
    @ObservationIgnored private var renderedRevision = 0

    /// Monotonic guard for the OFF-MAIN full-render path (issue #33). Every
    /// projection publish — sync or async — bumps it; a background render
    /// captures the value at launch and its result is adopted ONLY if the
    /// counter is unchanged when it hops back to the main actor. Any newer
    /// edit/activation/theme/reload that published in the meantime therefore
    /// DROPS the now-stale async projection instead of overwriting a fresher
    /// one (which would resurrect a pre-edit render on top of a keystroke —
    /// the corruption this guard closes). Non-Sendable state
    /// (`NSAttributedString` fragments, `RenderedDocument`) only crosses the
    /// actor hop as a clean, single-owner handoff: the background task is the
    /// sole reader while it renders; the main actor is the sole reader after.
    @ObservationIgnored private var renderGeneration = 0
    /// The in-flight background render, cancelled when a newer one supersedes
    /// it and on teardown. Cancellation is cooperative (the render loop has no
    /// checkpoints) so a cancelled task still finishes and is dropped by the
    /// generation guard — wasted CPU, never a wrong projection.
    @ObservationIgnored private var backgroundRenderTask: Task<Void, Never>?

    /// The authoritative projection, mirrored through every publish: full
    /// renders replace it; patch publishes apply their patches to it FIRST.
    /// SwiftUI coalesces rapid publishes, so the view can skip a patch
    /// revision entirely — when its `patchBaseLength` check misses, it
    /// resyncs by splicing to this string, which is correct precisely
    /// because it never skips a patch.
    @ObservationIgnored private var liveAttributed = NSMutableAttributedString()

    private func nextRevision() -> Int {
        renderedRevision += 1
        return renderedRevision
    }

    /// Applies a descending, disjoint patch batch to the authoritative
    /// string, returning its pre-patch length (the view's expected base).
    /// Nil on any bounds surprise — the caller must fall back to a full
    /// render.
    private func applyToLiveAttributed(_ patches: [RenderStoragePatch]) -> Int? {
        let base = liveAttributed.length
        for patch in patches {
            guard patch.oldRange.location >= 0,
                  NSMaxRange(patch.oldRange) <= liveAttributed.length else { return nil }
            liveAttributed.replaceCharacters(in: patch.oldRange, with: patch.replacement)
        }
        return base
    }

    @ObservationIgnored private var slugToBlock: [String: BlockID] = [:]
    /// Per-block rendered fragments reused across re-renders so a keystroke
    /// only rebuilds the block that changed (see AttributedRenderer.render).
    @ObservationIgnored private var fragmentCache: [BlockID: NSAttributedString] = [:]

    func start(fileURL: URL?, initialText: String) {
        guard session == nil else { return }
        self.fileURL = fileURL
        renderer = makeRenderer()

        let session: DocumentSession
        if let fileURL, let opened = try? DocumentSession.open(fileURL: fileURL) {
            session = opened
        } else if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            // The file EXISTS but couldn't be read (encoding, permissions,
            // un-downloaded cloud placeholder). Binding a blank session to
            // the real URL meant the first keystroke autosaved ~1 byte
            // over the user's document — silent total data loss (launch
            // audit, senior review BLOCKER #1). Detach from the file:
            // nothing this window does can touch it.
            session = DocumentSession(source: "", fileURL: nil)
            reportFailure(
                "Couldn't read “\(fileURL.lastPathComponent)” (encoding or permissions). "
                + "Editing is detached from the file to protect it.",
                sticky: true)
        } else {
            session = DocumentSession(source: initialText, fileURL: fileURL)
        }
        self.session = session

        // Termination flush registry: ⌘Q must drain every live session's
        // autosave before the process dies (launch audit BLOCKER #4).
        Self.registerLiveSession(session)

        snapshotTask = Task { [weak self] in
            // Each session callback takes its OWN `[weak self]`: it is a
            // @Sendable closure that lives on the session actor, so it can't
            // reach back to the enclosing task's captured `self` (that would
            // be a cross-context capture). Both hop to the main actor to
            // mutate this model.
            await session.setConflictHandler { [weak self] diskSource in
                Task { @MainActor in
                    self?.conflictDiskSource = diskSource
                }
            }
            await session.setSaveFailureHandler { [weak self] message in
                Task { @MainActor in
                    self?.reportFailure(message, sticky: true)
                }
            }
            await session.startWatching()
            let snapshots = await session.revisionedSnapshots()
            for await snapshot in snapshots {
                // This task inherits the model's main-actor isolation, so
                // `ingest` is a same-actor call — no `await` hop needed.
                self?.ingest(snapshot.document, contentRevision: snapshot.contentRevision)
            }
        }
    }

    /// A renderer for the CURRENT appearance — `Theme()` captures light/dark
    /// at creation, so appearance switches must re-create it (see
    /// `refreshTheme`).
    private func makeRenderer() -> AttributedRenderer {
        AttributedRenderer(
            theme: Theme(),
            baseURL: fileURL?.deletingLastPathComponent(),
            onContentReady: { [weak self] in
                Task { @MainActor in self?.scheduleAsyncContentRerender() }
            }
        )
    }

    /// Rebuilds the rendered projection for a new appearance (the user
    /// flipped dark/light, in-app or system-wide). The fragment cache is
    /// per-theme by construction — every cached fragment has the old
    /// palette baked in — so it empties rather than carries stale colors.
    func refreshTheme() {
        guard session != nil else { return }
        renderer = makeRenderer()
        fragmentCache.removeAll()
        // Off-main full render (issue #33): a theme flip re-projects the whole
        // document (every cached fragment has the old palette baked in), which
        // is exactly the ~0.5s-at-novel-length beach-ball this defers.
        rerenderAsync()
    }

    // MARK: - Merge banner

    func resolveConflictKeepingMine() {
        guard let session else { return }
        Task {
            do {
                try await session.resolveConflictKeepingMine()
                self.conflictDiskSource = nil
            } catch {
                // The banner stays (the version is still unresolved), but tell
                // the user their choice didn't take — otherwise "Keep Mine"
                // silently ignores the click and the banner just sits there.
                self.reportFailure("Couldn't keep your version — the document is still unresolved.")
            }
        }
    }

    func resolveConflictTakingDisk() {
        guard let session, let diskSource = conflictDiskSource else { return }
        conflictDiskSource = nil
        activeBlockID = nil
        caretInActiveBlock = nil
        Task { await session.resolveConflictTakingDisk(diskSource) }
    }

    func stop() {
        snapshotTask?.cancel()
        snapshotTask = nil
        backgroundRenderTask?.cancel()
        backgroundRenderTask = nil
        asyncRerenderTask?.cancel()
        asyncRerenderTask = nil
        // Also tear down the remaining background tasks the model owns so none
        // outlive teardown (they were harmless with `[weak self]`, but leaving
        // them running past `stop()` is a leak): a debounced H1 rename and the
        // auto-dismiss timer for a transient action-failure banner.
        renameTask?.cancel()
        renameTask = nil
        actionFailureTask?.cancel()
        actionFailureTask = nil
        let session = session
        let pendingEdits = editPipelineTask
        Task {
            await pendingEdits?.value
            try? await session?.saveNow()
            await session?.stopWatching()
        }
    }

    /// Drain any queued edits and force an immediate save WITHOUT tearing the
    /// session down — used before a copy/duplicate so the on-disk bytes match
    /// what the user sees (the autosave is 400ms-debounced, so a fast Duplicate
    /// right after typing would otherwise copy the pre-flush file, #12). Safe to
    /// call on a URL with no unsaved edits: `saveNow` no-ops when not dirty.
    func flush() async {
        let session = session
        let pendingEdits = editPipelineTask
        await pendingEdits?.value
        try? await session?.saveNow()
    }

    /// A new snapshot from the session (file change, checkbox, or our own
    /// edit). Skips re-rendering when both content and reveal state are
    /// unchanged.
    private func ingest(_ document: QuoinDocument, contentRevision: Int) {
        // Track the adoption revision even for echoes, so edit stamping
        // always reflects the newest snapshot this model has seen.
        sessionContentRevision = contentRevision
        // An external adoption (reload, conflict resolution) clears the undo
        // stacks in the session; keep the menu's copies honest.
        Task { await refreshUndoState() }
        // Our own edits already rendered via restoreCaret; skip the echo.
        guard document.sourceHash != self.document.sourceHash
                || rendered.activeBlockID != activeBlockID else { return }
        self.document = document
        // The active block's identity may have changed with its content;
        // keep activation only if the id still exists.
        if let active = activeBlockID, document.block(withID: active) == nil {
            activeBlockID = nil
            caretInActiveBlock = nil
        }
        // Off-main full render (issue #33): an external reload / checkbox
        // toggle / non-echo snapshot re-projects the whole document. No
        // keystroke is mapping a caret against this result in the same turn
        // (the edit paths keep their own synchronous render), so deferring it
        // is safe and lifts the reload beach-ball on large files. `document`
        // is already adopted synchronously above, so any edit that races in
        // renders against the fresh source and its generation bump drops this.
        rerenderAsync()
    }

    @ObservationIgnored private var asyncRerenderTask: Task<Void, Never>?

    /// Coalesces re-renders when async images finish decoding — a document
    /// with 30 photos triggers one re-render, not 30.
    private func scheduleAsyncContentRerender() {
        asyncRerenderTask?.cancel()
        asyncRerenderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            // Off-main full render (issue #33): async image decode re-projects
            // the whole document to pick up the resolved attachment.
            self?.rerenderAsync()
        }
    }

    private func rerender(spliceHint: RenderSpliceHint? = nil, activeBlockPatch: AttributedRenderer.ActiveBlockEditUpdate? = nil) {
        // A synchronous publish supersedes any in-flight background render
        // (issue #33): bumping the guard makes a still-running async render
        // drop its result instead of clobbering this fresher projection.
        renderGeneration += 1
        QuoinPerformanceTrace.measure(
            "model.rerender",
            metadata: "bytes=\(document.source.utf8.count) blocks=\(document.blocks.count) active=\(activeBlockID != nil) patched=\(activeBlockPatch != nil)"
        ) {
            if let patch = activeBlockPatch, let activeBlockID,
               let baseLength = applyToLiveAttributed([patch.storagePatch]) {
                fragmentCache.removeValue(forKey: patch.oldActiveBlockID)
                fragmentCache.removeValue(forKey: activeBlockID)
                rendered = RenderedDocument(
                    attributed: liveAttributed,
                    blockRanges: patch.blockRanges,
                    activeBlockID: activeBlockID,
                    activeEditableRange: patch.activeEditableRange,
                    activeSourceText: patch.activeSourceText,
                    storagePatch: patch.storagePatch,
                    revision: nextRevision(),
                    patchBaseLength: baseLength,
                    previewPanel: AttributedRenderer.previewPanel(for: heldPreview),
                    revealStyler: AttributedRenderer.revealStylerConfig(
                        kind: document.block(withID: activeBlockID)?.kind,
                        slice: patch.activeSourceText)
                )
            } else {
                let next = renderer.render(
                    document, activeBlockID: activeBlockID,
                    activeCaret: caretInActiveBlock, cache: &fragmentCache,
                    heldPreview: &heldPreview)
                liveAttributed = NSMutableAttributedString(attributedString: next.attributed)
                rendered = RenderedDocument(
                    attributed: liveAttributed,
                    blockRanges: next.blockRanges,
                    activeBlockID: next.activeBlockID,
                    activeEditableRange: next.activeEditableRange,
                    activeSourceText: next.activeSourceText,
                    spliceHint: spliceHint,
                    revision: nextRevision(),
                    previewPanel: next.previewPanel,
                    revealStyler: next.revealStyler
                )
            }
            outline = document.outline
            stats = document.stats
            slugToBlock = Dictionary(
                document.outline.map { ($0.slug, $0.id) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    /// The full-document projection rebuilt OFF the main actor (issue #33).
    ///
    /// The expensive part — `AttributedRenderer.render`, which walks every
    /// block and builds the whole attributed string — runs on a background
    /// executor so a multi-MB document no longer beach-balls the UI while it
    /// re-projects. Only the pure computation moves; the caret/viewport
    /// bookkeeping and the actual apply-to-live-storage stay on the main
    /// actor, and the result is adopted under `renderGeneration` so a stale
    /// async projection is dropped rather than applied over a fresher one.
    ///
    /// Used ONLY by the non-interactive, non-edit triggers — theme flip,
    /// external reload, async image decode — where no keystroke is mapping a
    /// caret against the result in the same turn. The per-keystroke patch
    /// path, the edit-recover full render, and the activation flip fallback
    /// stay SYNCHRONOUS (`rerender`): their ordering with the caret
    /// bookkeeping and the coordinator's keystroke-ack serialization is an
    /// invariant, and deferring them would let a queued keystroke map against
    /// a projection that hasn't landed yet.
    ///
    /// Document-derived observable state (`outline`, `stats`, `slugToBlock`)
    /// is refreshed SYNCHRONOUSLY here — it is cheap and some of it
    /// (`slugToBlock` for anchor navigation) should not lag the document —
    /// so only the heavy attributed-string projection is deferred.
    private func rerenderAsync() {
        outline = document.outline
        stats = document.stats
        slugToBlock = Dictionary(
            document.outline.map { ($0.slug, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        renderGeneration += 1
        let generation = renderGeneration
        // Snapshot the inputs the render is a pure function of. The cache
        // holds immutable NSAttributedString fragments (safe to read
        // off-main); the renderer is value-typed (Theme + URL + Bool +
        // @Sendable closure). These snapshots are the background task's
        // private copies — the main actor keeps mutating its own.
        let renderer = self.renderer
        let document = self.document
        let activeBlockID = self.activeBlockID
        let caret = self.caretInActiveBlock
        let cacheSnapshot = self.fragmentCache
        let heldSnapshot = self.heldPreview

        backgroundRenderTask?.cancel()
        // The task inherits this model's main-actor isolation; the heavy render
        // runs off-main inside `buildAsyncRender` (a `nonisolated` async method)
        // and its non-Sendable result is handed back as a single `sending`
        // value — the region-based, single-owner handoff issue #33 always
        // intended, now proven by the compiler instead of asserted in a comment.
        backgroundRenderTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let output = await self.buildAsyncRender(
                renderer: renderer, document: document, activeBlockID: activeBlockID,
                caret: caret, cache: cacheSnapshot, held: heldSnapshot)
            guard !Task.isCancelled, generation == self.renderGeneration else { return }
            self.liveAttributed = output.live
            self.fragmentCache = output.cache
            self.heldPreview = output.held
            self.rendered = RenderedDocument(
                attributed: output.live,
                blockRanges: output.next.blockRanges,
                activeBlockID: output.next.activeBlockID,
                activeEditableRange: output.next.activeEditableRange,
                activeSourceText: output.next.activeSourceText,
                revision: self.nextRevision(),
                previewPanel: output.next.previewPanel,
                revealStyler: output.next.revealStyler
            )
        }
    }

    /// The single-owner handoff bundle for `rerenderAsync`: the freshly built
    /// projection plus the caches it advanced. Non-Sendable (it holds
    /// NSAttributedString fragments), so it only ever crosses actors as a
    /// `sending` value — built by `buildAsyncRender`, consumed once on the main
    /// actor, never aliased.
    private struct AsyncRenderOutput {
        let next: RenderedDocument
        let live: NSMutableAttributedString
        let cache: [BlockID: NSAttributedString]
        let held: AttributedRenderer.HeldPreview?
    }

    /// The pure, off-main portion of `rerenderAsync`. `nonisolated`, so
    /// awaiting it from the main-actor render task runs the walk on a
    /// background executor. `cache`/`held` are transferred in as `sending`
    /// (the main actor snapshotted them and doesn't touch them again until it
    /// adopts the result), and the whole output is transferred back as
    /// `sending`.
    private nonisolated func buildAsyncRender(
        renderer: AttributedRenderer,
        document: QuoinDocument,
        activeBlockID: BlockID?,
        caret: Int?,
        cache: sending [BlockID: NSAttributedString],
        held: sending AttributedRenderer.HeldPreview?
    ) async -> sending AsyncRenderOutput {
        var cache = cache
        var held = held
        let next = renderer.render(
            document, activeBlockID: activeBlockID, activeCaret: caret,
            cache: &cache, heldPreview: &held)
        // Copy into the string that becomes authoritative on adoption, still
        // off-main, so the main actor receives a fully-built value.
        let live = NSMutableAttributedString(attributedString: next.attributed)
        return AsyncRenderOutput(next: next, live: live, cache: cache, held: held)
    }

    // MARK: - Syntax reveal

    /// Activates a block for editing. `caretHint` carries the caret's target
    /// offset tagged with its coordinate space (`CaretHint`): `.rendered`
    /// offsets are aligned to the source through the projection mapper
    /// (the source hides characters the projection dropped — hard-break
    /// spaces, `**`, `### `, entity source); `.source` offsets (embed
    /// bodies, 1:1 by construction) are used verbatim — running them
    /// through the mapper again landed the caret early by the header run's
    /// width. `pendingInsertion` is a keystroke that triggered this
    /// activation by landing on the rendered block: it is applied at the
    /// mapped caret through the normal session edit path, so the character
    /// is inserted, not swallowed.
    func activateBlock(_ id: BlockID?, caretHint: CaretHint? = nil, pendingInsertion: String? = nil) {
        guard id != activeBlockID else { return }
        // The review endmatter never opens as editable YAML — it is
        // machinery whose UI is the Review panel (user redline 2026-07-14).
        // Guarded here, the single chokepoint every activation path
        // (click, ⌘↩, edit chip, context menu, typing) funnels through.
        if let id, let block = document.blocks.first(where: { $0.id == id }),
           case .reviewEndmatter = block.kind {
            return
        }
        let previousActiveID = activeBlockID
        // Fence healing on commit-while-broken (ledger senior #10): a
        // fenced block committed without its closing fence would swallow
        // every following block. Close it with an ORDINARY session edit —
        // undoable, byte-honest — before the projection flips back.
        if let closing = previousActiveID,
           let block = document.blocks.first(where: { $0.id == closing }),
           let slice = document.source.substring(in: block.range),
           let suffix = FenceHealing.healingSuffix(for: slice, kind: block.kind) {
            applyAbsolute(
                SourceEdit(
                    range: ByteRange(offset: block.range.offset + block.range.length, length: 0),
                    replacement: suffix),
                caretUTF8: nil)
        }
        activeBlockID = id
        // Each editing session holds its own last-good preview; a stale
        // artifact from the previous session must never appear over a
        // different block's source.
        heldPreview = nil
        if let id, let block = document.blocks.first(where: { $0.id == id }),
           let slice = document.source.substring(in: block.range) {
            let sourceLength = slice.utf16.count
            switch caretHint {
            case .source(let offset):
                caretInActiveBlock = min(max(0, offset), sourceLength)
            case .rendered(let offset):
                if let renderedRange = rendered.blockRanges[id],
                   renderedRange.location + renderedRange.length <= rendered.attributed.length {
                    let renderedText = (rendered.attributed.string as NSString)
                        .substring(with: renderedRange)
                    let mapped = EditMapping.sourceOffset(
                        forRenderedOffset: offset,
                        renderedText: renderedText,
                        sourceText: slice
                    )
                    caretInActiveBlock = min(max(0, mapped), sourceLength)
                } else {
                    caretInActiveBlock = min(max(0, offset), sourceLength)
                }
            case nil:
                caretInActiveBlock = sourceLength
            }
        } else {
            caretInActiveBlock = nil
        }
        caretGeneration += 1
        if QuoinPerformanceTrace.isEnabled, let id,
           let block = document.blocks.first(where: { $0.id == id }),
           let slice = document.source.substring(in: block.range) {
            let head = slice.prefix(500).replacingOccurrences(of: "\n", with: "⏎")
            QuoinPerformanceTrace.log(
                "model.activate", startedAt: DispatchTime.now().uptimeNanoseconds,
                metadata: "kind=\(String(describing: block.kind).prefix(24)) sliceLen=\(slice.count) head=<<\(head)>>")
        }
        // A flip changes only the flipped blocks' PROJECTION — the document
        // is untouched. Patch just those fragments into the live storage
        // instead of re-rendering the whole document (which costs ~half a
        // second at novel length even with a warm fragment cache).
        if !applyActivationFlipPatch(from: previousActiveID, to: id) {
            rerender()
        }
        replayPendingInsertion(pendingInsertion)
    }

    /// The keystroke that opened the block, applied at the freshly mapped
    /// caret through the ordinary edit path — one async round-trip later
    /// the revealed source carries the character with the caret after it,
    /// exactly as if the block had been open when the key went down. Runs
    /// AFTER the flip publish so the edit's splice hint and block-local
    /// fast path see the revealed projection they patch against.
    private func replayPendingInsertion(_ insertion: String?) {
        guard let insertion, !insertion.isEmpty,
              let id = activeBlockID,
              let caret = caretInActiveBlock,
              let block = document.blocks.first(where: { $0.id == id }),
              let slice = document.source.substring(in: block.range),
              let caretBytes = EditMapping.utf8Offset(inText: slice, utf16Offset: caret)
        else { return }
        applyEdit(relativeRange: ByteRange(offset: caretBytes, length: 0), replacement: insertion)
    }

    /// Publishes storage patches for an activate/deactivate flip (built by
    /// the renderer — see `AttributedRenderer.activationFlipUpdate`).
    /// Returns false when the projection state doesn't line up; the caller
    /// then takes the full re-render, which is always correct.
    private func applyActivationFlipPatch(from oldID: BlockID?, to newID: BlockID?) -> Bool {
        guard let update = renderer.activationFlipUpdate(
            document: document, current: rendered,
            from: oldID, to: newID, caret: caretInActiveBlock,
            heldPreview: &heldPreview
        ) else { return false }

        guard let baseLength = applyToLiveAttributed(update.storagePatches) else { return false }
        if let cacheable = update.cacheableReadFragment {
            fragmentCache[cacheable.id] = cacheable.fragment
        }
        if let newID {
            fragmentCache.removeValue(forKey: newID)
        }
        // Supersede any in-flight background render (issue #33) — this flip
        // publish is the fresher projection.
        renderGeneration += 1
        rendered = RenderedDocument(
            attributed: liveAttributed,
            blockRanges: update.blockRanges,
            activeBlockID: newID,
            activeEditableRange: update.activeEditableRange,
            activeSourceText: update.activeSourceText,
            storagePatches: update.storagePatches,
            revision: nextRevision(),
            patchBaseLength: baseLength,
            previewPanel: newID != nil ? AttributedRenderer.previewPanel(for: heldPreview) : nil,
            revealStyler: newID.flatMap { id in
                update.activeSourceText.map { slice in
                    AttributedRenderer.revealStylerConfig(
                        kind: document.block(withID: id)?.kind, slice: slice)
                }
            }
        )
        return true
    }

    // MARK: - Edits

    /// A keystroke from the revealed block: `relativeRange` is UTF-8 bytes
    /// within the active block's source slice. `caretDelta` (UTF-8 from the
    /// edit start) overrides the landing spot for smart pairs and format
    /// commands.
    /// Review Mode (S3b): while ON, ordinary typing becomes suggestion
    /// marks through SuggestTransform. Per-model (v1) — flipping it in one
    /// window flips it for that document everywhere.
    var isSuggestMode = false

    func applyEdit(relativeRange: ByteRange, replacement: String, caretDelta: Int? = nil) {
        // `applyAbsolute` re-guards the session at apply time; here we only
        // need to know one exists, so this binding is existence-only.
        guard session != nil,
              let activeBlockID,
              let block = document.blocks.first(where: { $0.id == activeBlockID })
        else { return }

        var relativeRange = relativeRange
        var replacement = replacement
        var caretDelta = caretDelta
        if isSuggestMode {
            // Marks only live in prose containers (headings and embeds are
            // documented v1 degradations) — and a refused transform BEEPS,
            // never silently applies a real edit in review mode.
            let proseKind: Bool
            switch block.kind {
            case .paragraph, .list, .blockQuote, .callout: proseKind = true
            default: proseKind = false
            }
            guard proseKind, let slice = document.source.substring(in: block.range) else {
                NSSound.beep()
                return
            }
            switch SuggestTransform.outcome(
                relativeRange: relativeRange, replacement: replacement, in: slice) {
            case .plain:
                break
            case .transformed(let newRange, let newReplacement, let newCaret):
                relativeRange = newRange
                replacement = newReplacement
                caretDelta = newCaret
            case .refused:
                NSSound.beep()
                return
            }
        }

        let absolute = ByteRange(
            offset: block.range.offset + relativeRange.offset,
            length: relativeRange.length
        )
        let caretUTF8 = absolute.offset + (caretDelta ?? replacement.utf8.count)
        let edit = SourceEdit(range: absolute, replacement: replacement)
        let spliceHint = makeActiveEditSpliceHint(relativeRange: relativeRange, replacement: replacement)
        applyAbsolute(edit, caretUTF8: caretUTF8, spliceHint: spliceHint)
    }

    /// Block-granularity commands from the context menu (ideas #9/10/11):
    /// byte-exact splices built in QuoinCore, routed through the normal
    /// session pipeline (undo, losslessness, re-projection all apply).
    func perform(_ command: BlockCommand, on id: BlockID) {
        guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        let edit: SourceEdit?
        switch command {
        case .moveUp:
            edit = BlockEditing.moveEdit(
                source: document.source, blocks: document.blocks, blockIndex: index, direction: .up)
        case .moveDown:
            edit = BlockEditing.moveEdit(
                source: document.source, blocks: document.blocks, blockIndex: index, direction: .down)
        case .duplicate:
            edit = BlockEditing.duplicateEdit(
                source: document.source, blocks: document.blocks, blockIndex: index)
        case .delete:
            edit = BlockEditing.deleteEdit(
                source: document.source, blocks: document.blocks, blockIndex: index)
        case .addTableRow, .addTableColumn:
            let block = document.blocks[index]
            guard let slice = document.source.substring(in: block.range),
                  let grown = command == .addTableRow
                    ? TableEditing.addingRow(to: slice)
                    : TableEditing.addingColumn(to: slice)
            else { return }
            edit = SourceEdit(range: block.range, replacement: grown)
        case .tableInsertRow, .tableDeleteRow, .tableInsertColumn, .tableDeleteColumn,
             .tableMoveRow, .tableMoveColumn, .tableSetAlignment, .tableNormalize:
            // Structural table edits (#14): the engine emits a SLICE-RELATIVE
            // SourceEdit; rebase it onto the block's absolute source range so
            // untouched blocks stay byte-lossless and only this table re-pads.
            let block = document.blocks[index]
            guard let slice = document.source.substring(in: block.range),
                  let relative = tableEdit(command, in: slice) else { return }
            edit = SourceEdit(
                range: ByteRange(
                    offset: block.range.offset + relative.range.offset,
                    length: relative.range.length),
                replacement: relative.replacement)
        }
        guard let edit else { return }
        let actionName: UndoActionName
        switch command {
        case .moveUp, .moveDown: actionName = .moveBlock
        case .duplicate: actionName = .duplicateBlock
        case .delete: actionName = .deleteBlock
        case .addTableRow, .addTableColumn, .tableInsertRow, .tableDeleteRow,
             .tableInsertColumn, .tableDeleteColumn, .tableMoveRow, .tableMoveColumn,
             .tableSetAlignment, .tableNormalize:
            actionName = .editTable
        }
        // nil caret: keep the current reveal state — a block command must
        // not fling the caret or open the block it touched.
        applyAbsolute(edit, caretUTF8: nil, actionName: actionName)
    }

    /// Maps a structural table `BlockCommand` to a slice-relative `SourceEdit`
    /// (#14). Pure delegation to `TableEditing`; a non-table slice or an
    /// out-of-range target yields nil and the command no-ops.
    private func tableEdit(_ command: BlockCommand, in slice: String) -> SourceEdit? {
        switch command {
        case let .tableInsertRow(row, above):
            return TableEditing.insertRowEdit(in: slice, at: row, above: above)
        case let .tableDeleteRow(row):
            return TableEditing.deleteRowEdit(in: slice, at: row)
        case let .tableInsertColumn(column, left):
            return TableEditing.insertColumnEdit(in: slice, at: column, left: left)
        case let .tableDeleteColumn(column):
            return TableEditing.deleteColumnEdit(in: slice, at: column)
        case let .tableMoveRow(row, up):
            return TableEditing.moveRowEdit(in: slice, at: row, up: up)
        case let .tableMoveColumn(column, left):
            return TableEditing.moveColumnEdit(in: slice, at: column, left: left)
        case let .tableSetAlignment(column, alignment):
            return TableEditing.setAlignmentEdit(in: slice, at: column, to: alignment)
        case .tableNormalize:
            return TableEditing.normalizeEdit(in: slice)
        default:
            return nil
        }
    }

    /// Format ▸ Table menu command (#14): the keyboard/menu counterpart to the
    /// context-menu submenu. Acts on the active table block, targeting the cell
    /// under the caret (`caretInActiveBlock`). A quiet no-op when the active
    /// block is not a table or the op is unknown — so the menu item can stay
    /// enabled while any block is edited without misbehaving elsewhere.
    func performTableMenu(_ op: String) {
        guard let id = activeBlockID,
              let block = document.blocks.first(where: { $0.id == id }),
              case .table = block.kind,
              let slice = document.source.substring(in: block.range) else { return }
        let (row, column) = TableEditing.location(
            forOffsetUTF16: caretInActiveBlock ?? 0, in: slice) ?? (0, 0)
        let command: BlockCommand?
        switch op {
        case "insertRowAbove": command = .tableInsertRow(at: row, above: true)
        case "insertRowBelow": command = .tableInsertRow(at: row, above: false)
        case "deleteRow": command = .tableDeleteRow(at: row)
        case "insertColumnLeft": command = .tableInsertColumn(at: column, left: true)
        case "insertColumnRight": command = .tableInsertColumn(at: column, left: false)
        case "deleteColumn": command = .tableDeleteColumn(at: column)
        case "moveRowUp": command = .tableMoveRow(at: row, up: true)
        case "moveRowDown": command = .tableMoveRow(at: row, up: false)
        case "moveColumnLeft": command = .tableMoveColumn(at: column, left: true)
        case "moveColumnRight": command = .tableMoveColumn(at: column, left: false)
        case "alignLeft": command = .tableSetAlignment(at: column, alignment: .left)
        case "alignCenter": command = .tableSetAlignment(at: column, alignment: .center)
        case "alignRight": command = .tableSetAlignment(at: column, alignment: .right)
        case "alignNone": command = .tableSetAlignment(at: column, alignment: .none)
        case "normalize": command = .tableNormalize
        default: command = nil
        }
        if let command { perform(command, on: id) }
    }

    /// A structural line-prefix command (#25) — heading level, list/quote
    /// toggle, checkbox — applied to the caret's active block. Structural edits
    /// only touch prose blocks; a code/table/math slice would be corrupted by
    /// line-prefix surgery, so anything else is a quiet no-op.
    enum StructureCommand: Equatable {
        case setHeading(Int)   // 0 = plain paragraph, 1…6 = ATX level
        case cycleHeading
        case toggleBullet
        case toggleNumbered
        case toggleQuote
        case toggleCheckbox
    }

    func applyStructure(_ command: StructureCommand) {
        guard let id = activeBlockID,
              let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        let block = document.blocks[index]
        switch block.kind {
        case .paragraph, .heading, .list, .blockQuote: break
        default: return
        }
        guard let slice = document.source.substring(in: block.range) else { return }

        let newSlice: String?
        switch command {
        case .setHeading(let level):
            guard isHeadingTarget(block.kind) else { return }
            newSlice = StructureEditing.settingHeadingLevel(slice, level: level)
        case .cycleHeading:
            guard isHeadingTarget(block.kind) else { return }
            newSlice = StructureEditing.cyclingHeadingLevel(slice)
        case .toggleBullet:
            newSlice = StructureEditing.togglingList(slice, ordered: false)
        case .toggleNumbered:
            newSlice = StructureEditing.togglingList(slice, ordered: true)
        case .toggleQuote:
            newSlice = StructureEditing.togglingQuote(slice)
        case .toggleCheckbox:
            newSlice = StructureEditing.togglingCheckbox(slice, caretUTF16: caretInActiveBlock ?? 0)
        }
        guard let newSlice, newSlice != slice else { return }
        // nil caret: don't fling the caret; the block transforms in place.
        applyAbsolute(SourceEdit(range: block.range, replacement: newSlice), caretUTF8: nil, actionName: .structure)
    }

    private func isHeadingTarget(_ kind: BlockKind) -> Bool {
        switch kind {
        case .paragraph, .heading: return true
        default: return false
        }
    }

    /// Typing into a document with no blocks (freshly created, empty):
    /// append the text; the first block materializes around the caret.
    /// Without this, ⌘N produced an untypeable blank pane (launch audit
    /// BLOCKER #1).
    func insertIntoEmptyDocument(_ text: String) {
        guard document.blocks.isEmpty else { return }
        let end = document.source.utf8.count
        applyAbsolute(
            SourceEdit(range: ByteRange(offset: end, length: 0), replacement: text),
            caretUTF8: end + text.utf8.count)
    }

    /// The shared edit pipeline: serialize through the session, then adopt
    /// the new document with caret/projection bookkeeping.
    /// Accept or reject a CriticMarkup mark (suggestions design, S2): the
    /// splice is computed from the CURRENT source's bytes at the mark's
    /// range — if the document changed since the projection was built and
    /// those bytes no longer parse as one whole mark, refuse with a banner
    /// rather than splice blind. Rides the ordinary edit path: undoable,
    /// autosaved, stale-base protected.
    /// Accept All / Reject All: one atomic edit, one undo (design §3.5).
    /// Acts on suggestions only — comments/highlights are annotations.
    func resolveAllSuggestions(action: SuggestionResolver.Action) {
        // Nothing to resolve is a quiet no-op, not a failure. No pulse:
        // a batch changes the whole document, there is no one "where".
        applySessionResolution(refusalMessage: nil, flashOffset: nil) { session in
            try await session.applyBulkResolution(action: action, publishSnapshot: false)
        }
    }

    /// Find & Replace (#85): replace operates on the RAW SOURCE (a replace
    /// changes what the file says), computed against the model's current
    /// truth and routed through the atomic edit pipeline. Returns whether a
    /// replacement was made so the find bar can report it.
    @discardableResult
    func replaceNextMatch(
        of query: String, with replacement: String, fromByteOffset: Int,
        options: SearchOptions = SearchOptions(), inSelection: Bool = false
    ) -> Bool {
        guard !query.isEmpty else { return false }
        // In-Selection with no mappable selection replaces nothing (never the
        // whole document); the find bar surfaces "Select text first".
        if inSelection, selectionSourceRange == nil { return false }
        guard let (edit, next) = SourceReplace.replaceNextEdit(
                of: query, with: replacement, in: document.source,
                fromByteOffset: fromByteOffset, options: options,
                within: inSelection ? selectionSourceRange : nil)
        else { return false }
        applyAbsolute(edit, caretUTF8: next, actionName: .replace)
        return true
    }

    /// Replace every match as ONE atomic edit (one undo restores all).
    /// Returns the count replaced (a negative sentinel `-1` means the query
    /// is an invalid regex, so the bar can distinguish it from "no matches").
    @discardableResult
    func replaceAllMatches(
        of query: String, with replacement: String,
        options: SearchOptions = SearchOptions(), inSelection: Bool = false
    ) -> Int {
        guard !query.isEmpty else { return 0 }
        guard TextMatcher.isValidQuery(query, options: options) else { return -1 }
        if inSelection, selectionSourceRange == nil { return 0 }
        let scope = inSelection ? selectionSourceRange : nil
        let count = SourceReplace.matches(
            of: query, in: document.source, options: options, within: scope).count
        guard count > 0,
              let edit = SourceReplace.replaceAllEdit(
                of: query, with: replacement, in: document.source,
                options: options, within: scope)
        else { return 0 }
        applyAbsolute(edit, caretUTF8: nil, actionName: .replace)
        return count
    }

    /// The caret's current absolute byte offset, so "Replace" acts on the
    /// match at or after where you are.
    var caretByteOffset: Int {
        guard let activeBlockID,
              let block = document.blocks.first(where: { $0.id == activeBlockID }),
              let caret = caretInActiveBlock,
              let slice = document.source.substring(in: block.range),
              let caretUTF8 = EditMapping.utf8Offset(inText: slice, utf16Offset: caret)
        else { return 0 }
        return block.range.offset + caretUTF8
    }

    /// The "something happened, HERE" pulse (user ask): after a resolution
    /// applies, the view rings the spliced location. Generation-fired.
    private(set) var resolutionFlashOffset: Int?
    private(set) var resolutionFlashGeneration = 0

    /// S3a: create an annotation from a selection gesture. The coordinator
    /// reports rendered offsets RELATIVE to the block plus the text the
    /// user saw; this maps both endpoints through the projection mapper,
    /// snaps outward over emphasis delimiters (a whole-span selection wraps
    /// complete `**`, never half of one), and hands the byte range to the
    /// session — which recomputes against ITS current source and refuses on
    /// drift. Every refusal is a banner, never a silent no-op.
    func addAnnotation(
        kind: ReviewAuthoring.Kind, blockID: BlockID,
        renderedStart: Int, renderedEnd: Int, renderedText: String
    ) {
        let refusal = "Couldn't annotate that selection — try a smaller one inside a single paragraph."

        // Document-level comment: no selection, no mark, no mapping.
        if case .comment = kind, renderedStart == renderedEnd {
            applySessionResolution(refusalMessage: refusal) { [reviewer = Self.reviewerName] session in
                try await session.applyAnnotation(
                    kind: kind, range: ByteRange(offset: 0, length: 0), expectedSlice: "",
                    reviewer: reviewer, publishSnapshot: false)
            }
            return
        }

        guard let block = document.blocks.first(where: { $0.id == blockID }),
              let slice = document.source.substring(in: block.range),
              let blockRendered = rendered.blockRanges[blockID],
              NSMaxRange(blockRendered) <= rendered.attributed.length,
              renderedStart <= renderedEnd,
              renderedEnd <= blockRendered.length
        else { reportFailure(refusal); return }
        let renderedBlockText = (rendered.attributed.string as NSString).substring(with: blockRendered)
        // The projection may have moved since the gesture (an edit landed):
        // the text at those offsets must still be what the user saw.
        let renderedNS = renderedBlockText as NSString
        guard renderedNS.length >= renderedEnd,
              renderedNS.substring(
                with: NSRange(location: renderedStart, length: renderedEnd - renderedStart))
                == renderedText
        else { reportFailure(refusal); return }

        var startUTF16 = EditMapping.sourceOffset(
            forRenderedOffset: renderedStart, renderedText: renderedBlockText, sourceText: slice)
        var endUTF16 = EditMapping.sourceOffset(
            forRenderedOffset: renderedEnd, renderedText: renderedBlockText, sourceText: slice)
        // A whole-item selection maps to the line START — wrapping the list
        // marker would erase the structure (the live list-renumber bug):
        // annotate the item's CONTENT, marker excluded.
        startUTF16 = ReviewAuthoring.clampPastLinePrefix(startUTF16, in: slice)
        // Snap outward over emphasis delimiter runs (`*_~=`) so a rendered
        // whole-span selection wraps complete syntax — but only when the
        // capture is BALANCED. A selection at a span's edge must not pull
        // in the opening `**` while the closer stays outside the mark
        // (accepting would orphan it; the torn-bold live report).
        (startUTF16, endUTF16) = ReviewAuthoring.balancedDelimiterSnap(
            start: startUTF16, end: endUTF16, in: slice)

        guard startUTF16 < endUTF16 || renderedStart == renderedEnd,
              let relRange = EditMapping.utf8Range(inText: slice, utf16Range: startUTF16..<endUTF16)
        else { reportFailure(refusal); return }
        let absolute = ByteRange(offset: block.range.offset + relRange.offset, length: relRange.length)
        let bytes = Array(document.source.utf8)
        let expected = String(decoding: bytes[absolute.offset..<(absolute.offset + absolute.length)], as: UTF8.self)

        applySessionResolution(
            refusalMessage: refusal,
            flashOffset: absolute.offset
        ) { [reviewer = Self.reviewerName] session in
            try await session.applyAnnotation(
                kind: kind, range: absolute, expectedSlice: expected,
                reviewer: reviewer, publishSnapshot: false)
        }
    }

    /// Block-adjacent comment (#68): computed and validated in-actor like
    /// every annotation; the block's bytes are the drift check.
    func addBlockComment(blockID: BlockID, body: String) {
        guard let block = document.blocks.first(where: { $0.id == blockID }),
              let slice = document.source.substring(in: block.range) else {
            reportFailure("Couldn't comment on that block — try again.")
            return
        }
        applySessionResolution(
            refusalMessage: "Couldn't comment on that block — try again.",
            flashOffset: block.range.offset + block.range.length + 2
        ) { [reviewer = Self.reviewerName, range = block.range] session in
            try await session.applyAnnotation(
                kind: .blockComment(body: body), range: range,
                expectedSlice: slice, reviewer: reviewer, publishSnapshot: false)
        }
    }

    // MARK: - Front-matter properties (#70)

    /// Sets or creates one front-matter field from the Properties panel —
    /// computed in-actor at apply time like every resolution (the writer
    /// re-reads the session's current source), one edit, one undo. A
    /// writer refusal (complex value, drifted structure) is a banner,
    /// never a silent no-op.
    func setFrontMatterField(key: String, value: String) {
        applySessionResolution(
            refusalMessage: "Couldn't set “\(key)” — that property isn't a simple value.",
            flashOffset: nil
        ) { session in
            try await session.applyFrontMatterEdit(
                key: key, value: value, publishSnapshot: false)
        }
    }

    /// Sets one front-matter field to a TYPED raw value (bool/number/date
    /// scalar or flow list, #79) written verbatim — the panel's typed
    /// editors. Same in-actor guarantees as `setFrontMatterField`.
    func setTypedFrontMatterField(key: String, rawValue: String) {
        applySessionResolution(
            refusalMessage: "Couldn't set “\(key)” — the value lost its type. Try Edit as Text.",
            flashOffset: nil
        ) { session in
            try await session.applyTypedFrontMatterEdit(
                key: key, rawValue: rawValue, publishSnapshot: false)
        }
    }

    /// Removes one front-matter field (removing the last one removes the
    /// whole block). Same in-actor guarantees as `setFrontMatterField`.
    func removeFrontMatterField(key: String) {
        applySessionResolution(
            refusalMessage: "Couldn't remove “\(key)” — the front matter changed underneath. Try again.",
            flashOffset: nil
        ) { session in
            try await session.removeFrontMatterField(key: key, publishSnapshot: false)
        }
    }

    /// The name annotations are attributed to (`by:`). `AI` stays reserved
    /// for agents; the default is the macOS account name.
    static var reviewerName: String {
        let stored = UserDefaults.standard.string(forKey: "QuoinReviewerName")?
            .trimmingCharacters(in: .whitespaces)
        if let stored, !stored.isEmpty { return stored }
        return NSUserName()
    }

    /// The active block's reveal fragment re-styled at a caret offset —
    /// the caret-move restyle's source of truth (same pipeline as the
    /// reveal itself; editor-modes plan 3.3).
    func restyledActiveFragment(caretOffset: Int) -> NSAttributedString? {
        guard let activeBlockID,
              let block = document.blocks.first(where: { $0.id == activeBlockID }),
              let slice = document.source.substring(in: block.range) else { return nil }
        return renderer.renderEditableSourceFragment(
            slice, caretOffset: caretOffset, block: block, document: document,
            heldPreview: &heldPreview
        ).attributed
    }

    /// The block whose source range contains this byte offset — the review
    /// panel's card→document navigation.
    func blockID(containingByteOffset offset: Int) -> BlockID? {
        document.blocks.first {
            offset >= $0.range.offset && offset < $0.range.offset + $0.range.length
        }?.id
    }

    func resolveSuggestion(markRange: ByteRange, action: SuggestionResolver.Action) {
        // ONE atomic edit: mark replacement + the endmatter resolution
        // record (RDFM-native history) in a single splice — a single ⌘Z
        // restores both together (the two-edit version left a mark-back/
        // record-stale chimera after one undo; live screenshot 2026-07-14).
        // The edit is computed INSIDE the session actor, behind the pipeline
        // queue — computing it here against the model's projection let a
        // second quick Accept splice at pre-first-resolution offsets and
        // corrupt the document (panel review BLOCKER).
        // The bytes the card was rendered from — the session refuses if a
        // DIFFERENT equal-length mark now occupies that range (review LOW).
        let expected = document.source.substring(in: markRange)
        applySessionResolution(
            refusalMessage: "That suggestion changed since it was rendered — try again.",
            flashOffset: markRange.offset
        ) { session in
            try await session.applyResolution(
                markRange: markRange, action: action,
                expectedSlice: expected, publishSnapshot: false)
        }
    }

    /// Suggestion resolutions ride the ordinary edit pipeline (serialized,
    /// undoable, autosaved) but their edits are computed by the session at
    /// APPLY time, against its current truth. A nil result means the
    /// operation refused (mark bytes drifted / nothing to resolve) — no
    /// splice happened; `refusalMessage` surfaces it when that deserves a
    /// banner. Caret is never restored into the mark (a card click is not
    /// an edit-intent into the block; see resolveSuggestion).
    private func applySessionResolution(
        refusalMessage: String?,
        flashOffset: Int? = nil,
        _ operation: @escaping @Sendable (DocumentSession) async throws -> QuoinDocument?
    ) {
        guard let session else { return }
        latestEditGeneration += 1
        let generation = latestEditGeneration
        let previousEditTask = editPipelineTask

        editPipelineTask = Task { [weak self] in
            await previousEditTask?.value
            guard let self else { return }
            do {
                let newDocument = try await QuoinPerformanceTrace.measure(
                    "model.session.applyResolution") {
                    try await operation(session)
                }
                guard generation == self.latestEditGeneration else { return }
                if let newDocument {
                    QuoinPerformanceTrace.measure("model.restoreCaret") {
                        self.restoreCaret(in: newDocument, atUTF8Offset: nil)
                    }
                    self.scheduleH1Rename(for: newDocument)
                    if let flashOffset {
                        self.resolutionFlashOffset = flashOffset
                        self.resolutionFlashGeneration += 1
                    }
                } else if let refusalMessage {
                    self.reportFailure(refusalMessage)
                }
                await self.refreshUndoState()
            } catch {
                await self.recoverFromFailedEdit(error, generation: generation)
            }
            if generation == self.latestEditGeneration {
                self.editPipelineTask = nil
            }
        }
    }

    private func applyAbsolute(
        _ edit: SourceEdit, caretUTF8: Int?, spliceHint: RenderSpliceHint? = nil,
        actionName: UndoActionName? = nil,
        onError: (@Sendable () -> Void)? = nil
    ) {
        guard let session else { return }
        let absolute = edit.range
        let replacement = edit.replacement
        // Stamp NOW, synchronously: this is the revision of the content the
        // edit's offsets were computed against. The session rejects the
        // edit if an external reload replaces the content before the
        // pipeline task applies it (ledger #14).
        let baseRevision = sessionContentRevision
        latestEditGeneration += 1
        let generation = latestEditGeneration
        let previousEditTask = editPipelineTask

        editPipelineTask = Task { [weak self] in
            await previousEditTask?.value
            guard let self else { return }
            do {
                let newDocument = try await QuoinPerformanceTrace.measure(
                    "model.session.applyEdit",
                    metadata: "range_offset=\(absolute.offset) replacement_bytes=\(replacement.utf8.count)"
                ) {
                    try await session.applyEdit(
                        edit, baseRevision: baseRevision, publishSnapshot: false, actionName: actionName)
                }
                guard generation == self.latestEditGeneration else { return }
                QuoinPerformanceTrace.measure("model.restoreCaret") {
                    self.restoreCaret(in: newDocument, atUTF8Offset: caretUTF8, spliceHint: spliceHint)
                }
                self.scheduleH1Rename(for: newDocument)
                await self.refreshUndoState()
            } catch {
                onError?()
                await self.recoverFromFailedEdit(error, generation: generation)
            }
            if generation == self.latestEditGeneration {
                self.editPipelineTask = nil
            }
        }
    }

    /// A session edit was rejected or failed (ledger, data integrity #8).
    /// The old behavior wedged typing until the coordinator's 2s watchdog
    /// fired and then silently DISCARDED the queued keystrokes. Instead:
    /// adopt the session's current truth and republish the projection with
    /// a caret echo NOW — the echo unwedges the coordinator immediately,
    /// and its queued keystrokes replay against the fresh state through
    /// the ordinary pipeline (they are content + order; each applies at
    /// the freshly restored caret). Only the rejected edit itself cannot
    /// be replayed (its range is stale by definition); its loss — and the
    /// loss of the queue when the active block itself is gone — is
    /// surfaced as a banner, never swallowed.
    private func recoverFromFailedEdit(_ error: Error, generation: Int) async {
        guard let session else { return }
        let truth = await session.document
        sessionContentRevision = await session.contentRevision
        await refreshUndoState()
        // Superseded submissions stay quiet: the newest one (or its own
        // recovery) owns the projection and the banner.
        guard generation == latestEditGeneration else { return }
        let hadActiveBlock = activeBlockID != nil
        restoreCaret(in: truth, atUTF8Offset: nil)
        let replayImpossible = hadActiveBlock && activeBlockID == nil
        if case SessionError.staleEditBase = error {
            reportFailure(replayImpossible
                ? "The document changed underneath your typing — recent keystrokes weren't applied."
                : "The document changed underneath your typing — the last keystroke wasn't applied.")
        } else {
            reportFailure("Couldn't apply the last edit — the view has been refreshed.")
        }
    }

    private func makeActiveEditSpliceHint(relativeRange: ByteRange, replacement: String) -> RenderSpliceHint? {
        guard !replacement.contains("\n"),
              let active = rendered.activeEditableRange,
              let source = rendered.activeSourceText,
              let start = EditMapping.utf16Offset(inText: source, utf8Offset: relativeRange.offset),
              let end = EditMapping.utf16Offset(inText: source, utf8Offset: relativeRange.upperBound)
        else { return nil }
        let location = active.location + start
        return RenderSpliceHint(
            oldRange: NSRange(location: location, length: end - start),
            replacementRange: NSRange(location: location, length: replacement.utf16.count)
        )
    }

    // MARK: - First H1 renames Untitled files (debounced, silent suffix)

    private func scheduleH1Rename(for doc: QuoinDocument) {
        guard let url = fileURL,
              url.deletingPathExtension().lastPathComponent.hasPrefix("Untitled"),
              let first = doc.outline.first, first.level == 1
        else { return }
        let title = sanitizedFilename(first.title)
        guard !title.isEmpty, title != url.deletingPathExtension().lastPathComponent else { return }

        renameTask?.cancel()
        renameTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.performH1Rename(to: title)
        }
    }

    private func performH1Rename(to title: String) async {
        guard let session, let url = fileURL else { return }
        do {
            try await session.saveNow()
        } catch {
            return
        }
        guard let renamed = try? Library.rename(url, to: title) else { return }
        await session.relocate(to: renamed)
        fileURL = renamed
        onFileRenamed?(renamed)
    }

    private func sanitizedFilename(_ title: String) -> String {
        FilenamePolicy.sanitize(title)
    }

    func undo() {
        performHistoryOperation { try await $0.undo() }
    }

    func redo() {
        performHistoryOperation { try await $0.redo() }
    }

    /// Pull the session's current Undo/Redo labels onto the main actor so the
    /// Edit menu (via focused values) re-titles and re-enables. Called after
    /// every edit, resolution, history op, and external adoption — the only
    /// events that can change the stacks.
    private func refreshUndoState() async {
        guard let session else { return }
        let state = await session.undoState
        undoActionName = state.undoActionName
        redoActionName = state.redoActionName
    }

    /// Undo/redo serialized with the edit pipeline (launch ledger, data
    /// integrity #7). A ⌘Z issued while a keystroke's round-trip was still
    /// in flight used to hop onto the session actor in NONDETERMINISTIC
    /// order — when the undo won, it spliced first and the in-flight
    /// keystroke then applied at pre-undo offsets, corrupting the source.
    /// History operations now JOIN the same FIFO pipeline the keystrokes
    /// flow through, so they run strictly after every edit submitted
    /// before them. (The session's `contentRevision` bump on undo/redo is
    /// the backstop: an edit stamped against pre-undo content is rejected
    /// as `staleEditBase` rather than spliced.)
    private func performHistoryOperation(
        _ operation: @escaping @Sendable (DocumentSession) async throws -> QuoinDocument?
    ) {
        guard let session else { return }
        latestEditGeneration += 1
        let generation = latestEditGeneration
        let previousEditTask = editPipelineTask
        editPipelineTask = Task { [weak self] in
            await previousEditTask?.value
            guard let self else { return }
            let newDocument = (try? await operation(session)) ?? nil
            // Adopt the bumped revision stamp immediately — the ingest of
            // the published snapshot is asynchronous, and a keystroke typed
            // in that window must not be stamped (and rejected) as stale.
            self.sessionContentRevision = await session.contentRevision
            guard generation == self.latestEditGeneration else { return }
            if let newDocument {
                QuoinPerformanceTrace.measure("model.restoreCaret.history") {
                    self.restoreCaret(in: newDocument, atUTF8Offset: nil)
                }
            }
            await self.refreshUndoState()
            if generation == self.latestEditGeneration {
                self.editPipelineTask = nil
            }
        }
    }

    /// After an edit round-trip: adopt the new document, re-locate the
    /// block containing the caret (block identity changes with content, and
    /// an Enter can split one block into two), and restore the caret.
    private func restoreCaret(in newDocument: QuoinDocument, atUTF8Offset caretUTF8: Int?, spliceHint: RenderSpliceHint? = nil) {
        let oldDocument = document
        let oldRendered = rendered
        let oldActiveBlockID = activeBlockID
        document = newDocument
        if let caretUTF8 {
            let block = newDocument.blocks.last(where: { $0.range.offset <= caretUTF8 })
                ?? newDocument.blocks.first
            if let block, let slice = newDocument.source.substring(in: block.range) {
                activeBlockID = block.id
                let relative = max(0, min(caretUTF8 - block.range.offset, slice.utf8.count))
                caretInActiveBlock = EditMapping.utf16Offset(inText: slice, utf8Offset: relative) ?? slice.utf16.count
            } else {
                activeBlockID = nil
                caretInActiveBlock = nil
            }
        } else if let active = activeBlockID, newDocument.block(withID: active) == nil {
            activeBlockID = nil
            caretInActiveBlock = nil
        }
        caretGeneration += 1
        let activeBlockPatch = makeActiveBlockRenderPatch(
            oldDocument: oldDocument,
            oldRendered: oldRendered,
            oldActiveBlockID: oldActiveBlockID,
            newDocument: newDocument,
            requiresSimpleEditHint: spliceHint != nil
        )
        rerender(spliceHint: spliceHint, activeBlockPatch: activeBlockPatch)
    }

    /// Thin wrapper: the per-keystroke patch construction lives in the
    /// renderer (editor-modes plan 3.2 — package-testable, proven by the
    /// equivalence corpus); the model contributes only its editing state
    /// and the splice-hint gate.
    private func makeActiveBlockRenderPatch(
        oldDocument: QuoinDocument,
        oldRendered: RenderedDocument,
        oldActiveBlockID: BlockID?,
        newDocument: QuoinDocument,
        requiresSimpleEditHint: Bool
    ) -> AttributedRenderer.ActiveBlockEditUpdate? {
        guard requiresSimpleEditHint else { return nil }
        return renderer.activeBlockEditUpdate(
            oldDocument: oldDocument,
            oldRendered: oldRendered,
            oldActiveBlockID: oldActiveBlockID,
            newDocument: newDocument,
            newActiveBlockID: activeBlockID,
            caret: caretInActiveBlock,
            heldPreview: &heldPreview
        )
    }

    // MARK: - Image drop

    // `nonisolated`: an immutable Sendable lookup table, read from off-main
    // drag-and-drop completion handlers as well as the main actor.
    nonisolated static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]

    /// Drag-dropped image: copy the asset next to the document (assets/),
    /// insert `![](assets/…)` at the caret (or document end). Every file step
    /// can fail; a failure is surfaced as a banner rather than swallowed, so
    /// the user never believes an image landed when it didn't.
    func insertImage(from sourceURL: URL) {
        guard session != nil,
              Self.imageExtensions.contains(sourceURL.pathExtension.lowercased()),
              let assetsFolder = ensureAssetsFolder()
        else { return }

        // Silent-suffix collision handling, same rule as document names.
        let destination = Library.uniqueURL(
            baseName: sourceURL.deletingPathExtension().lastPathComponent,
            extension: sourceURL.pathExtension, in: assetsFolder
        )
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            reportFailure("Couldn't copy “\(sourceURL.lastPathComponent)” into the library.")
            return
        }
        insertAssetReference(to: destination)
    }

    /// Clipboard image paste (#24): a screenshot / copied bitmap / copied image
    /// file on the pasteboard is written into `assets/` and referenced inline.
    /// Returns true if an image was found and handled (so the caller can skip
    /// the plain-text paste). Screenshots and copied bitmaps normalize to PNG;
    /// a copied image FILE reuses the drag-drop path to keep its own format.
    @discardableResult
    func insertPastedImage(from pasteboard: NSPasteboard = .general) -> Bool {
        guard session != nil, fileURL != nil else { return false }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let imageURL = urls.first(where: { Self.imageExtensions.contains($0.pathExtension.lowercased()) }) {
            insertImage(from: imageURL)
            return true
        }

        guard let png = ClipboardImage.pngData(from: pasteboard),
              let assetsFolder = ensureAssetsFolder()
        else { return false }
        let destination = Library.uniqueURL(baseName: "pasted-image", extension: "png", in: assetsFolder)
        do {
            try png.write(to: destination)
        } catch {
            reportFailure("Couldn't save the pasted image into the library.")
            return false
        }
        insertAssetReference(to: destination)
        return true
    }

    /// The library `assets/` folder beside the current document, created on
    /// demand; nil (with a banner) when it can't be made.
    private func ensureAssetsFolder() -> URL? {
        guard let docURL = fileURL else { return nil }
        let folder = docURL.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            reportFailure("Couldn't create the assets folder for the image.")
            return nil
        }
        return folder
    }

    /// Insert `![](assets/<name>)` for an asset ALREADY written to `destination`,
    /// at the caret (or document end). Routed through the FIFO edit pipeline
    /// like every other mutation (review HIGH: a bare Task computed the offset
    /// against the model projection and applied it OUT OF BAND, so an image
    /// dropped while a keystroke was still round-tripping spliced at a stale
    /// offset and landed in the wrong place — a well-formed but wrong document
    /// that autosave then persisted). On failure the orphaned asset is removed
    /// so a retry doesn't accumulate copies.
    private func insertAssetReference(to destination: URL) {
        let markdown = "\n\n![](assets/\(destination.lastPathComponent))\n"
        let offset: Int
        if let activeBlockID,
           let block = document.blocks.first(where: { $0.id == activeBlockID }),
           let caret = caretInActiveBlock,
           let slice = document.source.substring(in: block.range),
           let caretUTF8 = EditMapping.utf8Offset(inText: slice, utf16Offset: caret) {
            offset = block.range.offset + caretUTF8
        } else {
            offset = document.source.utf8.count
        }

        let edit = SourceEdit(range: ByteRange(offset: offset, length: 0), replacement: markdown)
        applyAbsolute(edit, caretUTF8: offset + markdown.utf8.count) {
            try? FileManager.default.removeItem(at: destination)
        }
    }

    // MARK: - Checkbox & anchors

    func toggleTask(markerOffset: Int) {
        guard let session else { return }
        Task {
            do {
                try await session.toggleTask(markerRange: ByteRange(offset: markerOffset, length: 3))
            } catch SessionError.taskNotTogglable {
                // The file shifted under the click; the session republished the
                // fresh state (see DocumentSession.toggleTask). Tell the user
                // their tap didn't apply so they can re-tap on current content.
                self.reportFailure("The document changed on disk, so the checkbox wasn't toggled — it's been refreshed.")
            } catch {
                self.reportFailure("Couldn't save the checkbox change.")
            }
        }
    }

    // MARK: - Non-blocking action failures

    func dismissActionFailure() {
        actionFailureTask?.cancel()
        actionFailure = nil
    }

    private func reportFailure(_ message: String, sticky: Bool = false) {
        actionFailure = ActionFailure(message: message)
        actionFailureTask?.cancel()
        guard !sticky else { return } // data-integrity failures never auto-dismiss
        actionFailureTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.actionFailure = nil
        }
    }

    func blockID(forSlug slug: String) -> BlockID? {
        slugToBlock[slug]
    }

    // MARK: - Termination flush (launch audit BLOCKER #4)

    /// Weak registry of live sessions so app termination can drain every
    /// pending autosave before the process exits — SwiftUI's onDisappear
    /// is not reliably delivered at ⌘Q, and a detached flush task races
    /// process death.
    private static var liveSessions: [() -> DocumentSession?] = []

    static func registerLiveSession(_ session: DocumentSession) {
        liveSessions.removeAll { $0() == nil }
        liveSessions.append { [weak session] in session }
    }

    /// Synchronously-awaitable flush of every live session.
    static func flushAllSessions() async {
        for accessor in liveSessions {
            guard let session = accessor() else { continue }
            try? await session.saveNow()
        }
        liveSessions.removeAll { $0() == nil }
    }

    /// Main-actor-synchronous snapshot for the termination path: the
    /// delegate grabs the sessions HERE (on main, where the registry
    /// lives) and flushes them on a detached executor — a plain
    /// MainActor Task may never run in the terminateLater runloop mode,
    /// which is exactly how the first flush implementation lost data.
    static func liveSessionSnapshot() -> [DocumentSession] {
        liveSessions.compactMap { $0() }
    }
}
