#if canImport(SwiftUI)
import SwiftUI

// Dynamic Type for the SwiftUI chrome (#28).
//
// The handoff pins the type ramp as final — exact point sizes for every
// sidebar row, status-bar label, tab, panel, and dialog. So we do NOT swap
// the fixed sizes for semantic text styles (.body/.caption), which would
// discard the ramp. Instead we keep each site's design size as the base and
// let @ScaledMetric multiply it by the system's Dynamic Type factor. Every
// site anchors to the same reference style (.body), so the whole ramp scales
// by one shared curve and the design's proportions are preserved.
//
// Usage mirrors `.font(.system(size:weight:design:))`:
//     Text("Outline").quoinScaledFont(size: 12.5, weight: .medium)
// The point size passed in is the design's base size at the default Dynamic
// Type setting; it is the number the handoff specifies.

/// A `ViewModifier` that applies `.font(.system(size:weight:design:))` with the
/// point size scaled for Dynamic Type via `@ScaledMetric`.
///
/// `@ScaledMetric` must live on a stored property of a `View`/`ViewModifier`,
/// so the scaling logic is wrapped here rather than in a free function.
public struct ScaledChromeFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    public init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        // Anchor every chrome font to the body text style's scaling curve so
        // the full ramp grows together and keeps its relative proportions.
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
        self.weight = weight
        self.design = design
    }

    public func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// Dynamic-Type-aware replacement for `.font(.system(size:weight:design:))`
    /// on SwiftUI chrome. `size` is the design's base point size (from the
    /// handoff type ramp); it scales with the system "Larger text" setting
    /// while preserving the ramp's proportions.
    public func quoinScaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(ScaledChromeFont(size: size, weight: weight, design: design))
    }
}
#endif
