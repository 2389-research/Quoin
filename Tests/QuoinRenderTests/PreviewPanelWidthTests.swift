#if canImport(AppKit)
import XCTest
@testable import QuoinRender

/// The responsive live-edit preview panel width (#42): grow to fill a wide
/// editing frame, clamp on narrow ones, always leave the source usable.
final class PreviewPanelWidthTests: XCTestCase {
    private let base = AttributedRenderer.previewPanelWidth          // 320
    private let maxW = AttributedRenderer.previewPanelMaxWidth       // 720
    private let minSrc = AttributedRenderer.previewPanelMinSourceWidth // 340

    func testGrowsOnWideFrames() {
        // A wide frame should give a panel much larger than the old fixed 320.
        let w = AttributedRenderer.previewPanelWidth(forAvailableWidth: 1200)
        XCTAssertGreaterThan(w, base, "the panel fills the space on a wide window")
        XCTAssertLessThanOrEqual(w, maxW, "capped at the max")
        XCTAssertGreaterThanOrEqual(1200 - w, minSrc, "the source keeps its minimum")
    }

    func testCappedAtMax() {
        XCTAssertEqual(AttributedRenderer.previewPanelWidth(forAvailableWidth: 4000), maxW)
    }

    func testNeverStealsTheSourceMinimum() {
        // Across a sweep of widths, the source column never drops below the min.
        for available in stride(from: 660.0, through: 2400.0, by: 37.0) {
            let w = AttributedRenderer.previewPanelWidth(forAvailableWidth: available)
            XCTAssertGreaterThanOrEqual(available - w, minSrc - 0.001,
                                        "source min preserved at width \(available)")
        }
    }

    func testDismissThresholdMatchesOldBehavior() {
        // Below ~660 the panel should be smaller than the base (→ AppKit dismisses),
        // matching the old `available - 320 >= 340` threshold — no regression on
        // narrow windows.
        XCTAssertLessThan(AttributedRenderer.previewPanelWidth(forAvailableWidth: 600), base)
        XCTAssertGreaterThanOrEqual(AttributedRenderer.previewPanelWidth(forAvailableWidth: 700), base)
    }
}
#endif
