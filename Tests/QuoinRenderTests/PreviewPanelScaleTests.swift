#if canImport(AppKit)
import XCTest
import AppKit
@testable import QuoinRender

/// The live-preview panel fills its space (#3, field report "the diagrams can
/// take up much more space"): a small diagram scales UP toward the panel
/// bounds instead of sitting at native size in a sea of empty space, while a
/// cap keeps a tiny diagram from blowing up to a blurry wall.
final class PreviewPanelScaleTests: XCTestCase {

    func testSmallDiagramScalesUpToFillWidth() {
        // A 100×60 diagram in a 400-wide / 300-tall panel: width is the
        // binding constraint → 4× wanted, but the cap holds it to maxUpscale.
        let scale = PreviewPanelView.fitScale(
            for: CGSize(width: 100, height: 60), maxWidth: 400, maxHeight: 300)
        XCTAssertGreaterThan(scale, 1, "a small diagram must grow, not stay native")
        XCTAssertEqual(scale, PreviewPanelView.maxUpscale, accuracy: 0.001)
    }

    func testModestUpscaleFillsToConstrainingDimension() {
        // 200×100 into 300×220: width→1.5×, height→2.2× → width binds at 1.5×.
        let scale = PreviewPanelView.fitScale(
            for: CGSize(width: 200, height: 100), maxWidth: 300, maxHeight: 220)
        XCTAssertEqual(scale, 1.5, accuracy: 0.001)
    }

    func testLargeDiagramStillScalesDownToFit() {
        // A diagram bigger than the panel is shrunk (unchanged behavior).
        let scale = PreviewPanelView.fitScale(
            for: CGSize(width: 1200, height: 400), maxWidth: 300, maxHeight: 220)
        XCTAssertLessThan(scale, 1)
        XCTAssertEqual(scale, 300.0 / 1200.0, accuracy: 0.001)
    }

    func testZeroSizeIsSafe() {
        XCTAssertEqual(
            PreviewPanelView.fitScale(for: .zero, maxWidth: 300, maxHeight: 220), 1)
    }
}
#endif
