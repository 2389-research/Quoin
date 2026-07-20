#if canImport(AppKit) || canImport(UIKit)
import XCTest
@testable import QuoinRender
import CoreGraphics

/// The block-anchored scroll-preservation arithmetic that keeps the iOS reader
/// from jumping when an async local image finishes decoding (issue #2). The
/// `UITextView`/TextKit-2 plumbing is iOS-only and cannot run here, but the
/// geometry that makes the claim ("the pinned block does not move on screen")
/// true is pure and is verified below.
final class ScrollAnchorMathTests: XCTestCase {

    /// An image that resolves ABOVE the viewport grows the content by its
    /// height delta; the anchor fragment therefore moves down by that delta,
    /// and the restored offset must grow by exactly the delta so the pinned
    /// fragment stays at the same on-screen Y. This is the failure the finding
    /// describes ("image above the viewport expanding pushes all following
    /// content down").
    func testImageGrowingAboveViewportKeepsAnchorFixed() {
        // Reader scrolled to y=500; the anchor fragment currently sits at
        // container-Y 480 (20pt above the viewport top). A placeholder above
        // resolves and grows by 300pt, so the anchor is now at 780.
        let restored = ScrollAnchorMath.restoredOffsetY(
            oldOffsetY: 500, anchorYBefore: 480, anchorYAfter: 780, maxOffsetY: 10_000)
        XCTAssertEqual(restored, 800, accuracy: 0.001)
        // The fragment's on-screen position (its Y minus the scroll offset) is
        // unchanged: 480-500 == 780-800 == -20.
        XCTAssertEqual(780 - restored, 480 - 500, accuracy: 0.001)
    }

    /// Nothing changes above the anchor (only images BELOW the viewport
    /// resolved): the anchor keeps its Y and the offset is untouched.
    func testNoChangeAboveAnchorLeavesOffsetUntouched() {
        let restored = ScrollAnchorMath.restoredOffsetY(
            oldOffsetY: 500, anchorYBefore: 480, anchorYAfter: 480, maxOffsetY: 10_000)
        XCTAssertEqual(restored, 500, accuracy: 0.001)
    }

    /// The restore never overscrolls into blank space: a target beyond the
    /// bottom is clamped to the maximum legal offset.
    func testClampsToMaxOffset() {
        let restored = ScrollAnchorMath.restoredOffsetY(
            oldOffsetY: 950, anchorYBefore: 100, anchorYAfter: 400, maxOffsetY: 1_000)
        XCTAssertEqual(restored, 1_000, accuracy: 0.001)
    }

    /// The restore never produces a negative offset (which would show blank
    /// space above the content), even if a fragment shrinks.
    func testNeverNegative() {
        let restored = ScrollAnchorMath.restoredOffsetY(
            oldOffsetY: 50, anchorYBefore: 400, anchorYAfter: 100, maxOffsetY: 1_000)
        XCTAssertEqual(restored, 0, accuracy: 0.001)
    }

    /// A degenerate content shorter than the viewport (maxOffsetY <= 0) pins to
    /// the top rather than producing a bogus positive offset.
    func testShortDocumentPinsToTop() {
        let restored = ScrollAnchorMath.restoredOffsetY(
            oldOffsetY: 0, anchorYBefore: 0, anchorYAfter: 40, maxOffsetY: -20)
        XCTAssertEqual(restored, 0, accuracy: 0.001)
    }
}
#endif
