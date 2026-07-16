import Foundation

/// Which tab gets focus after the active tab is closed (#77).
///
/// Browser-standard positional stability: focus the tab that now occupies
/// the closed tab's slot (its former right neighbor). Closing the rightmost
/// tab falls back to the new rightmost. Platform-free so the selection rule
/// is testable without an app target.
public enum TabSuccession {

    /// Index (into the post-removal array) of the tab to focus after the
    /// active tab at `closedIndex` was removed, or nil when none remain.
    public static func successorIndex(closedIndex: Int, remainingCount: Int) -> Int? {
        guard remainingCount > 0 else { return nil }
        return min(max(closedIndex, 0), remainingCount - 1)
    }

    /// Same rule when SEVERAL tabs vanish at once (a trashed folder closes
    /// every tab under it): the active tab's slot among the survivors is its
    /// original index minus the removals to its left.
    /// `isRemoved` is queried once per original index, in order.
    public static func successorIndex(
        activeIndex: Int,
        originalCount: Int,
        isRemoved: (Int) -> Bool
    ) -> Int? {
        var slot = activeIndex
        var remaining = originalCount
        for index in 0..<originalCount where isRemoved(index) {
            remaining -= 1
            if index < activeIndex { slot -= 1 }
        }
        return successorIndex(closedIndex: slot, remainingCount: remaining)
    }
}
