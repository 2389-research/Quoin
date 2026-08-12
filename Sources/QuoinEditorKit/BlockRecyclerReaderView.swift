#if canImport(AppKit)
import AppKit
import SwiftUI
import QuoinCore
import QuoinRender

/// Phase 1, Task 8: the SwiftUI seam that swaps the projection reader for the
/// block recycler when `-QuoinEditorRecycler YES` (the `@AppStorage
/// QuoinEditorRecycler` flag) is set. This is a READ-ONLY view: the recycler
/// (Tasks 1–6) has no editing/format/annotation surface yet, so this wrapper
/// forwards only what a read-only reader needs — the document to lay out, the
/// theme, the outline scroll target, and the top-block callback that drives
/// the outline sync. Everything else on `MarkdownReaderView`'s ~80-callback
/// surface is intentionally absent; the projection reader stays the default.
///
/// `rendered` is carried for its monotonic `revision`: `updateNSView` re-runs
/// `setDocument` only when the revision (or the laid-out width) actually
/// changes, so a benign SwiftUI re-evaluation doesn't reload the table and
/// throw away the scroll position. `searchQuery` is part of the read-only
/// signature for parity with the projection reader, but the Phase-1 recycler
/// has no match-highlight surface yet, so it is not consumed here.
public struct BlockRecyclerReaderView: NSViewRepresentable {

    private let document: QuoinDocument
    private let rendered: RenderedDocument
    private let theme: Theme
    /// The reader's CONFIGURED renderer, threaded from `ReaderModel` so the
    /// recycler projects with byte-identical config to the projection reader:
    /// `baseURL` (relative-path images resolve), `onContentReady` (async image
    /// decodes re-render), and `imageResolution`/`loadsRemoteImages`. `textScale`
    /// and `codeTheme` ride in on `theme` (== `renderer.theme`). A bare
    /// `AttributedRenderer(theme:)` dropped all of these — most visibly, relative
    /// images never resolved.
    private let renderer: AttributedRenderer
    private let scrollTarget: BlockID?
    /// Bumped by the outline on every click, even a repeat click on the SAME
    /// heading (which leaves `scrollTarget` unchanged). Threaded so that repeat
    /// re-fires the scroll, matching `MarkdownReaderView`'s contract.
    private let scrollGeneration: Int
    private let onTopBlockChange: ((BlockID) -> Void)?
    private let searchQuery: String?
    /// Reader-wide `QuoinWordWrap` preference, forwarded for parity with the
    /// projection reader (which honours it). See `BlockRecyclerView.wordWrap`.
    private let wordWrap: Bool
    /// Phase 2, Task 7: the app's KEEP-path island reconcile. Fired with the
    /// flushed island's byte range + new text; applies the edit through
    /// `ReaderModel.reconcileIsland` and returns the resulting document, which
    /// this view hands back to the `IslandController` via `applyReconciled` so
    /// the island re-anchors. Nil in read-only contexts (no editing surface).
    private let onReconcile: ((ByteRange, String) async -> QuoinDocument)?

    public init(
        document: QuoinDocument,
        rendered: RenderedDocument,
        theme: Theme,
        renderer: AttributedRenderer,
        scrollTarget: BlockID?,
        scrollGeneration: Int = 0,
        onTopBlockChange: ((BlockID) -> Void)?,
        searchQuery: String?,
        wordWrap: Bool = true,
        onReconcile: ((ByteRange, String) async -> QuoinDocument)? = nil
    ) {
        self.document = document
        self.rendered = rendered
        self.theme = theme
        self.renderer = renderer
        self.scrollTarget = scrollTarget
        self.scrollGeneration = scrollGeneration
        self.onTopBlockChange = onTopBlockChange
        self.searchQuery = searchQuery
        self.wordWrap = wordWrap
        self.onReconcile = onReconcile
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> BlockRecyclerView {
        makeRecycler(coordinator: context.coordinator)
    }

    public func updateNSView(_ view: BlockRecyclerView, context: Context) {
        view.onTopBlockChange = onTopBlockChange
        view.wordWrap = wordWrap
        apply(to: view, coordinator: context.coordinator, initial: false)
    }

    // MARK: - Wiring (internal so the smoke test can exercise it without a
    // SwiftUI `Context`, which cannot be constructed directly).

    /// Build the hosted `BlockRecyclerView` and seed it with the document.
    func makeRecycler(coordinator: Coordinator) -> BlockRecyclerView {
        // Use the model's CONFIGURED renderer (baseURL / onContentReady / image
        // resolution), NOT a bare `AttributedRenderer(theme:)` — that dropped the
        // reader's config and, most visibly, never resolved relative-path images.
        let view = BlockRecyclerView(renderer: renderer, theme: theme)
        view.onTopBlockChange = onTopBlockChange
        view.wordWrap = wordWrap
        installIslandWiring(on: view, coordinator: coordinator)
        apply(to: view, coordinator: coordinator, initial: true)
        return view
    }

    /// Phase 2, Task 7: own the `IslandController` (on the Coordinator, so it
    /// survives SwiftUI re-evaluations) and connect the two edit seams:
    ///
    /// 1. `recycler.onBlockClicked → controller.activate(...)` — a click promotes
    ///    that row to an editable island. The click closure reads the CURRENT
    ///    document/revision off the Coordinator (refreshed every `apply`), never
    ///    the stale values captured when this ran once at `makeRecycler` time.
    /// 2. `controller.onReconcile → onReconcile app closure → applyReconciled` —
    ///    a flushed island applies its edit through `ReaderModel.reconcileIsland`
    ///    and the resulting document is handed back so the island re-anchors
    ///    (terminal swap/blur flushes drop the island first, so `applyReconciled`
    ///    is inert there — safe to always call).
    private func installIslandWiring(on view: BlockRecyclerView, coordinator: Coordinator) {
        let controller = IslandController(recycler: view)
        coordinator.islandController = controller

        view.onBlockClicked = { [weak coordinator] blockID, point in
            guard let coordinator, let controller = coordinator.islandController else { return }
            controller.activate(blockID: blockID, localPoint: point,
                                 in: coordinator.document, baseRevision: coordinator.baseRevision)
        }

        controller.onReconcile = { [weak coordinator, weak controller] range, text, caret in
            guard let coordinator, let onReconcile = coordinator.onReconcile else { return }
            // Phase 3, Task 4: compute the reconcile-time caret's ABSOLUTE document
            // byte at FLUSH time — bytes before the caret don't move, so this is
            // stable even if the split makes the live cell's selection meaningless.
            // Threaded to `applyReconciled` so a split RE-HOMES the island into the
            // caret's new block instead of tearing down.
            let caretDocByte = IslandCaretMapping.documentByte(
                localUTF16: caret, islandSource: text, islandByteStart: range.offset)
            Task { @MainActor in
                let newDocument = await onReconcile(range, text)
                controller?.applyReconciled(newDocument, caretDocByte: caretDocByte)
            }
        }
    }

    /// Re-run `setDocument` when the document (revision) or the laid-out width
    /// changed, then honor the outline scroll target.
    func apply(to view: BlockRecyclerView, coordinator: Coordinator, initial: Bool) {
        // Keep the click/reconcile seams pointed at the CURRENT document, base
        // revision, and app closure — the click closure and controller reconcile
        // read these off the Coordinator so they never fire against the stale
        // values captured once at `makeRecycler` time.
        coordinator.document = document
        coordinator.baseRevision = rendered.revision
        coordinator.onReconcile = onReconcile

        let width = contentWidth(for: view)
        if initial {
            view.setDocument(document, contentWidth: width)
            coordinator.appliedRevision = rendered.revision
            coordinator.appliedWidth = width
        } else if coordinator.appliedRevision != rendered.revision
                    || coordinator.appliedWidth != width {
            // Phase 2 final-review fix: a revision bump is USUALLY an external
            // document swap, but it is ALSO how the active island's OWN KEEP
            // reconcile re-projects. A bare `setDocument` would tear the island
            // down (clear editing + full reload) and desync the controller, whose
            // `activeIsland` still points at a now-missing editor cell — the next
            // flush then empty-splices and DELETES the block. Route every
            // non-initial refresh through `updateDocumentPreservingEditing`, which
            // KEEPS the live editing row (first responder + caret) when the island
            // is active and re-anchored, and falls back to `setDocument` otherwise
            // (read-only, external swap, structural change) — so the non-editing
            // path is byte-identical to before.
            // Re-anchor by the active island's STABLE start byte (bytes before the
            // island never move across its own edits), so the preserve path is
            // idempotent with `IslandController.applyReconciled` in EITHER order —
            // it no longer depends on `_editingBlockID` having already been
            // re-pointed onto the new content-hash id. Nil when no island is active
            // (read-only / external swap), which falls through to `setDocument`.
            let islandStart = coordinator.islandController?.activeIsland?.byteRange.lowerBound
            view.updateDocumentPreservingEditing(
                document, contentWidth: width, islandStartByte: islandStart)
            coordinator.appliedRevision = rendered.revision
            coordinator.appliedWidth = width
        }
        // Re-scroll when the target changes OR the scroll generation was bumped
        // (a repeat outline click on the SAME heading keeps `scrollTarget` but
        // bumps the generation — per CLAUDE.md that must re-fire the scroll).
        // Comparing targets alone would swallow the repeat click; comparing the
        // generation alone would miss the first scroll to a never-before target.
        if let target = scrollTarget,
           coordinator.lastScrollTarget != target
            || coordinator.lastScrollGeneration != scrollGeneration {
            coordinator.lastScrollTarget = target
            coordinator.lastScrollGeneration = scrollGeneration
            view.scroll(to: target)
        }
    }

    /// The text-column width: the laid-out view width minus the reader's
    /// symmetric content insets, floored so a not-yet-laid-out view (width 0)
    /// still gets a sane initial column.
    func contentWidth(for view: BlockRecyclerView) -> CGFloat {
        let available = view.bounds.width
        guard available > 0 else { return 600 }
        return max(available - 2 * theme.contentInset, 320)
    }

    public final class Coordinator {
        var appliedRevision: Int?
        var appliedWidth: CGFloat?
        var lastScrollTarget: BlockID?
        var lastScrollGeneration: Int?
        /// Phase 2, Task 7: the editable-island machine, owned here so it (and its
        /// active island) survive SwiftUI re-evaluations. Created in `makeRecycler`.
        var islandController: IslandController?
        /// The current document/base-revision/app-closure, refreshed every `apply`
        /// so the click and reconcile seams act on live values, not the snapshot
        /// captured when the wiring was installed.
        var document: QuoinDocument = .empty
        var baseRevision: Int = 0
        var onReconcile: ((ByteRange, String) async -> QuoinDocument)?
    }
}
#endif
