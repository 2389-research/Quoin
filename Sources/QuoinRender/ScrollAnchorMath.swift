#if canImport(AppKit) || canImport(UIKit)
import CoreGraphics

/// Pure geometry for block-anchored scroll preservation across a re-render
/// (issue #2).
///
/// When an async local-image decode finishes, its placeholder fragment grows
/// from a single line to the image's full height. Re-assigning the projection
/// to a `UITextView` would otherwise jump the reader two ways: (a) assigning
/// `attributedText` resets the scroll to the top, and (b) any image ABOVE the
/// viewport growing pushes everything below it down by the height delta. The
/// fix pins one fragment that is visible at the top of the viewport: it records
/// that fragment's layout Y and the scroll offset BEFORE the swap, then after
/// the swap shifts the scroll offset by exactly the fragment's Y delta so the
/// pinned fragment stays put on screen — honouring the viewport invariant the
/// macOS reader enforces with its settle pass.
///
/// This isolates the arithmetic from the iOS-only `UITextView`/TextKit-2
/// plumbing so it is unit-testable on the macOS CI runner (where `UIKit` is not
/// importable and the reader view compiles away).
enum ScrollAnchorMath {
    /// The content offset that keeps the anchor fragment at the same on-screen
    /// position after a re-render.
    ///
    /// - Parameters:
    ///   - oldOffsetY: the scroll offset captured before the swap.
    ///   - anchorYBefore: the anchor fragment's top in the text layout's own
    ///     coordinate space before the swap.
    ///   - anchorYAfter: the same fragment's top after the swap and relayout.
    ///     The constant text-container inset cancels out of the delta, so the
    ///     two Ys need only share a coordinate space, not equal the content
    ///     offset's.
    ///   - maxOffsetY: the largest legal offset (content height minus the
    ///     viewport height); the result is clamped to `0...maxOffsetY` so a
    ///     restore never overscrolls into blank space.
    /// - Returns: the clamped content offset to apply.
    static func restoredOffsetY(
        oldOffsetY: CGFloat,
        anchorYBefore: CGFloat,
        anchorYAfter: CGFloat,
        maxOffsetY: CGFloat
    ) -> CGFloat {
        let target = oldOffsetY + (anchorYAfter - anchorYBefore)
        return min(max(target, 0), max(0, maxOffsetY))
    }
}
#endif
