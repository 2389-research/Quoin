import Foundation

/// Pure keyboard navigation for the outline panel's tree: arrow keys move a
/// focus cursor through the VISIBLE rows and collapse/expand subtrees, the
/// standard macOS source-list contract (NSOutlineView, Finder's list view).
///
/// The view owns two pieces of state — a `focused: BlockID?` cursor and the
/// `collapsed` set (shared with #74's manual-collapse-sticks rule) — and
/// delegates every keypress here so the movement math is tested once. These
/// functions only READ the outline + collapse state; the caller applies the
/// returned `Response`. Manual collapse stays authoritative: expand/collapse
/// happen ONLY through explicit user keys here, never as a side effect of
/// reading-position follow.
///
/// Ancestry and "has children" are positional, matching the flat outline the
/// parser emits (see `OutlineCollapse`): a heading's parent is the nearest
/// preceding heading of a strictly shallower level, so level skips (H1 → H3)
/// still chain correctly.
public enum OutlineKeyboard {

    /// What a keypress asks the view to do. `move` repoints the focus cursor;
    /// `collapse`/`expand` mutate the collapse set for that heading (focus
    /// stays on it); `none` is a no-op (edge of list, leaf with nowhere to go).
    public enum Response: Equatable {
        case move(BlockID)
        case collapse(BlockID)
        case expand(BlockID)
        case none
    }

    /// Down-arrow: focus the next visible row. No wrap — a source list stops
    /// at its ends. With no (or a now-hidden) focus, land on the first row.
    public static func moveDown(
        from focused: BlockID?,
        outline: [HeadingInfo],
        collapsed: Set<BlockID>
    ) -> Response {
        let visible = OutlineCollapse.visibleHeadings(outline: outline, collapsed: collapsed)
        guard !visible.isEmpty else { return .none }
        guard let focused, let index = visible.firstIndex(where: { $0.id == focused }) else {
            return .move(visible[0].id)
        }
        guard index + 1 < visible.count else { return .none }
        return .move(visible[index + 1].id)
    }

    /// Up-arrow: focus the previous visible row. No wrap. With no (or a
    /// now-hidden) focus, land on the last row.
    public static func moveUp(
        from focused: BlockID?,
        outline: [HeadingInfo],
        collapsed: Set<BlockID>
    ) -> Response {
        let visible = OutlineCollapse.visibleHeadings(outline: outline, collapsed: collapsed)
        guard !visible.isEmpty else { return .none }
        guard let focused, let index = visible.firstIndex(where: { $0.id == focused }) else {
            return .move(visible[visible.count - 1].id)
        }
        guard index - 1 >= 0 else { return .none }
        return .move(visible[index - 1].id)
    }

    /// Left-arrow: collapse an OPEN parent in place; otherwise (a leaf, or an
    /// already-collapsed parent) climb to the positional parent heading. At
    /// the root with nothing open, nothing happens.
    public static func collapseOrParent(
        focused: BlockID,
        outline: [HeadingInfo],
        collapsed: Set<BlockID>
    ) -> Response {
        let parents = OutlineCollapse.parents(outline: outline)
        if parents.contains(focused), !collapsed.contains(focused) {
            return .collapse(focused)
        }
        guard let chain = OutlineCollapse.ancestorChain(of: focused, in: outline),
              chain.count >= 2 else { return .none }
        return .move(chain[chain.count - 2].id)
    }

    /// Right-arrow: expand a COLLAPSED parent in place; on an already-open
    /// parent, descend to its first child (the next row in the full outline).
    /// A leaf has nowhere to go.
    public static func expandOrChild(
        focused: BlockID,
        outline: [HeadingInfo],
        collapsed: Set<BlockID>
    ) -> Response {
        let parents = OutlineCollapse.parents(outline: outline)
        guard parents.contains(focused) else { return .none }
        if collapsed.contains(focused) { return .expand(focused) }
        guard let index = outline.firstIndex(where: { $0.id == focused }),
              index + 1 < outline.count else { return .none }
        return .move(outline[index + 1].id)
    }
}
