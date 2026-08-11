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

    public init(
        document: QuoinDocument,
        rendered: RenderedDocument,
        theme: Theme,
        renderer: AttributedRenderer,
        scrollTarget: BlockID?,
        scrollGeneration: Int = 0,
        onTopBlockChange: ((BlockID) -> Void)?,
        searchQuery: String?,
        wordWrap: Bool = true
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
        apply(to: view, coordinator: coordinator, initial: true)
        return view
    }

    /// Re-run `setDocument` when the document (revision) or the laid-out width
    /// changed, then honor the outline scroll target.
    func apply(to view: BlockRecyclerView, coordinator: Coordinator, initial: Bool) {
        let width = contentWidth(for: view)
        if initial
            || coordinator.appliedRevision != rendered.revision
            || coordinator.appliedWidth != width {
            view.setDocument(document, contentWidth: width)
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
    }
}
#endif
