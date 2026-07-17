import Foundation

/// Pure geometry of outline collapse for the outline panel's follow
/// highlight. Manual collapse is authoritative: reading-position follow
/// must NEVER expand a branch the user closed — instead the "you are
/// here" highlight climbs to the deepest ancestor whose whole chain is
/// expanded. Only explicit user actions (chevron toggle, heading click)
/// may change expansion state, and that state lives in the view; these
/// functions only read it.
///
/// Ancestry is positional, matching the flat outline the parser emits: a
/// heading's parent is the nearest PRECEDING heading of a strictly
/// shallower level, so level skips (H1 → H3) still chain correctly.
public enum OutlineCollapse {

    /// The outline with every collapsed subtree removed. A collapsed
    /// heading itself stays visible (it carries the chevron); its
    /// descendants hide unconditionally — there is no current-section
    /// exception, or follow would punch orphan rows into closed branches.
    public static func visibleHeadings(
        outline: [HeadingInfo],
        collapsed: Set<BlockID>
    ) -> [HeadingInfo] {
        var result: [HeadingInfo] = []
        var hiddenBelowLevel: Int?
        for heading in outline {
            if let level = hiddenBelowLevel {
                if heading.level > level { continue }
                hiddenBelowLevel = nil
            }
            result.append(heading)
            if collapsed.contains(heading.id) {
                hiddenBelowLevel = heading.level
            }
        }
        return result
    }

    /// Where the follow highlight lands: the current section itself when
    /// its whole ancestor chain is expanded, otherwise the SHALLOWEST
    /// collapsed ancestor — that row is the deepest one still on screen
    /// (deeper collapsed ancestors are themselves hidden inside it).
    /// Returns nil when the current section is unknown or not in the
    /// outline (e.g. mid-reparse); the panel then highlights nothing.
    public static func resolveHighlight(
        for currentID: BlockID?,
        outline: [HeadingInfo],
        collapsed: Set<BlockID>
    ) -> BlockID? {
        guard let currentID,
              let chain = ancestorChain(of: currentID, in: outline) else { return nil }
        // A collapsed heading hides its descendants, not itself — so only
        // strict ancestors (chain minus the section itself) can bump the
        // highlight upward.
        for ancestor in chain.dropLast() where collapsed.contains(ancestor.id) {
            return ancestor.id
        }
        return currentID
    }

    /// The headings that own a subtree — a heading is a parent when the very
    /// next entry is deeper (strictly higher level). Shared by the outline
    /// panel's chevron rendering and the keyboard collapse/expand logic so the
    /// "has children" test is defined once.
    public static func parents(outline: [HeadingInfo]) -> Set<BlockID> {
        var result: Set<BlockID> = []
        for (index, heading) in outline.enumerated() {
            if index + 1 < outline.count, outline[index + 1].level > heading.level {
                result.insert(heading.id)
            }
        }
        return result
    }

    /// The positional ancestor chain, root first, ending with the heading
    /// itself. Nil when `id` is not in the outline.
    static func ancestorChain(of id: BlockID, in outline: [HeadingInfo]) -> [HeadingInfo]? {
        guard let index = outline.firstIndex(where: { $0.id == id }) else { return nil }
        var chain = [outline[index]]
        var level = outline[index].level
        for heading in outline[..<index].reversed() where heading.level < level {
            chain.insert(heading, at: 0)
            level = heading.level
        }
        return chain
    }
}
