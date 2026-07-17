import Foundation

/// Resolving "which section am I reading" for the outline highlight (#R3).
public enum OutlineNavigation {

    /// The section heading the reader is currently within: the nearest heading
    /// at or before the top-of-viewport block, resolved by DOCUMENT ORDER.
    ///
    /// The previous implementation compared laid-out character ranges, which a
    /// heading scrolled ABOVE the viewport can drop out of (TextKit 2 lays out
    /// visible fragments) — so the highlight reverted to an ancestor heading
    /// the moment its own heading left the top, even though the reader was
    /// still inside that section. Block INDEX is always available, laid out or
    /// not, so the highlight tracks the section you're actually in.
    ///
    /// Returns the first heading as a fallback (top block above the first
    /// heading, or the top block unknown); nil only when there are no headings.
    public static func currentSection(
        topBlockID: BlockID?,
        blocks: [Block],
        outline: [HeadingInfo]
    ) -> HeadingInfo? {
        guard let topBlockID else { return outline.first }
        var indexByID: [BlockID: Int] = [:]
        indexByID.reserveCapacity(blocks.count)
        for (index, block) in blocks.enumerated() { indexByID[block.id] = index }
        guard let topIndex = indexByID[topBlockID] else { return outline.first }

        var current: HeadingInfo?
        for heading in outline {
            guard let headingIndex = indexByID[heading.id] else { continue }
            if headingIndex <= topIndex {
                current = heading
            } else {
                break // outline is in document order; nothing later can qualify
            }
        }
        return current ?? outline.first
    }
}
