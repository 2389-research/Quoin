import Foundation

/// Pure arrow-key highlight movement for the keyboard-operable result
/// lists — Quick Open (⇧⌘O) and the library search sidebar (⇧⌘F). The
/// SwiftUI views own the highlight as a plain `Int`; these functions map
/// a keypress to the next index so the wrap / clamp / empty-list rules are
/// tested once and shared instead of re-derived per call site (two
/// recognizers for one grammar WILL diverge).
///
/// Contract: indices are 0-based into a list of `count` items. Down/Up
/// WRAP around the ends (last → first, first → last) so a keyboard user
/// never dead-ends. On an empty list every function returns 0 — a harmless
/// default; callers guard emptiness before acting on the highlight.
public enum ListSelection {

    /// Down-arrow: the next row, wrapping past the last back to the first.
    public static func next(_ current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let clamped = min(max(0, current), count - 1)
        return (clamped + 1) % count
    }

    /// Up-arrow: the previous row, wrapping past the first to the last.
    public static func previous(_ current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let clamped = min(max(0, current), count - 1)
        return (clamped - 1 + count) % count
    }

    /// Home: the first row.
    public static func first(count: Int) -> Int { 0 }

    /// End: the last row.
    public static func last(count: Int) -> Int { max(0, count - 1) }

    /// Fold a highlight back into range when the result list changes length
    /// (a new query shrank it). Keeps a valid index; empty → 0.
    public static func clamped(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, index), count - 1)
    }
}
