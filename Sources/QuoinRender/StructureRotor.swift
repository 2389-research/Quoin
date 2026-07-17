#if canImport(AppKit) || canImport(UIKit)
import Foundation

/// Platform-free navigation math for VoiceOver structure rotors — the
/// Headings rotor and the Landmarks rotor (accessibility structure, #10).
///
/// Kept OUT of the AppKit view on purpose: the novel, bug-prone part is the
/// next/previous/filter selection, so it lives here as a pure function that is
/// unit-tested directly (`StructureRotorTests`) with no text system involved.
/// The AppKit `StructureRotorDelegate` is a thin adapter that maps
/// `NSAccessibilityCustomRotor` calls onto `result(...)`.
enum StructureRotor {

    /// One navigable structural element, in document order.
    struct Item: Equatable {
        /// Start offset of the element's rendered range — the anchor the
        /// caret / last-visited item is compared against.
        let location: Int
        /// Length of the rendered range — the rotor's `targetRange`.
        let length: Int
        /// The spoken label VoiceOver reads for this item.
        let label: String

        init(location: Int, length: Int, label: String) {
            self.location = location
            self.length = length
            self.label = label
        }
    }

    enum Direction { case next, previous }

    /// The item VoiceOver should move to, or nil to leave selection put.
    ///
    /// - `items` MUST be sorted ascending by `location` (document order).
    /// - `currentLocation` anchors the search: the location of the
    ///   last-visited rotor item, or nil on the FIRST search (rotor just
    ///   opened) — then `.next` returns the first matching item and
    ///   `.previous` the last.
    /// - `filter` is a case-insensitive substring the label must contain;
    ///   empty matches everything. A pool emptied by the filter returns nil.
    ///
    /// `.next` picks the first item strictly AFTER the anchor, `.previous` the
    /// last item strictly BEFORE it. The comparison is strict (`>` / `<`, never
    /// `>=` / `<=`) so a step never re-selects the element the caret already
    /// sits on. Returns nil when there is no such item (already at the last /
    /// first match).
    static func result(
        items: [Item],
        currentLocation: Int?,
        direction: Direction,
        filter: String
    ) -> Item? {
        let needle = filter.lowercased()
        let pool = needle.isEmpty
            ? items
            : items.filter { $0.label.lowercased().contains(needle) }
        guard !pool.isEmpty else { return nil }

        switch direction {
        case .next:
            guard let loc = currentLocation else { return pool.first }
            return pool.first { $0.location > loc }
        case .previous:
            guard let loc = currentLocation else { return pool.last }
            return pool.last { $0.location < loc }
        }
    }
}
#endif
