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
    private let scrollTarget: BlockID?
    private let onTopBlockChange: ((BlockID) -> Void)?
    private let searchQuery: String?

    public init(
        document: QuoinDocument,
        rendered: RenderedDocument,
        theme: Theme,
        scrollTarget: BlockID?,
        onTopBlockChange: ((BlockID) -> Void)?,
        searchQuery: String?
    ) {
        self.document = document
        self.rendered = rendered
        self.theme = theme
        self.scrollTarget = scrollTarget
        self.onTopBlockChange = onTopBlockChange
        self.searchQuery = searchQuery
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> BlockRecyclerView {
        makeRecycler(coordinator: context.coordinator)
    }

    public func updateNSView(_ view: BlockRecyclerView, context: Context) {
        view.onTopBlockChange = onTopBlockChange
        apply(to: view, coordinator: context.coordinator, initial: false)
    }

    // MARK: - Wiring (internal so the smoke test can exercise it without a
    // SwiftUI `Context`, which cannot be constructed directly).

    /// Build the hosted `BlockRecyclerView` and seed it with the document.
    func makeRecycler(coordinator: Coordinator) -> BlockRecyclerView {
        let view = BlockRecyclerView(renderer: AttributedRenderer(theme: theme), theme: theme)
        view.onTopBlockChange = onTopBlockChange
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
        // Only re-scroll when the target actually changes, so an unrelated
        // re-evaluation doesn't fight the user's own scrolling.
        if let target = scrollTarget, coordinator.lastScrollTarget != target {
            coordinator.lastScrollTarget = target
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
    }
}
#endif
