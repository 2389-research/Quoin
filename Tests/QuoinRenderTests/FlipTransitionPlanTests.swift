#if canImport(AppKit)
import XCTest
@testable import QuoinRender

/// The motion system's decision table (embed-editing brief, Phase 3).
/// The treatment is keyed to the flip's height delta; these pin the
/// thresholds so tuning stays deliberate.
@MainActor
final class FlipTransitionPlanTests: XCTestCase {

    private func plan(
        old: CGFloat, new: CGFloat, viewport: CGFloat = 800,
        reduceMotion: Bool = false, length: Int = 10_000
    ) -> FlipTransitionController.Plan {
        FlipTransitionController.plan(
            oldBlockHeight: old, newBlockHeight: new, viewportHeight: viewport,
            reduceMotion: reduceMotion, documentLength: length)
    }

    func testSmallDeltasStayInstant() {
        // The habituated check-the-render loop: ≥100ms of mediation would
        // tax every open/close cycle on a typical code block.
        XCTAssertEqual(plan(old: 200, new: 200), .none)
        XCTAssertEqual(plan(old: 200, new: 240), .none)
        XCTAssertEqual(plan(old: 240, new: 200), .none)
    }

    func testLargeDeltaGetsSlices() {
        guard case .slices(let fade, let slide, let delta) = plan(old: 300, new: 120) else {
            return XCTFail("collapsing flip should slice")
        }
        XCTAssertEqual(delta, -180)
        XCTAssertLessThan(fade, slide, "the fade must land before the slide ends")
    }

    func testExpandingFlipGetsTheLongerBeat() {
        guard case .slices(_, let slideExpanding, _) = plan(old: 120, new: 300),
              case .slices(_, let slideCollapsing, _) = plan(old: 300, new: 120) else {
            return XCTFail("both directions should slice")
        }
        XCTAssertGreaterThan(slideExpanding, slideCollapsing,
                             "incoming content needs a beat to be received")
    }

    func testHalfViewportDeltaBecomesCrossfade() {
        // Sliding most of a screen reads as scrolling — a lie.
        guard case .crossfade(let duration) = plan(old: 100, new: 600, viewport: 800) else {
            return XCTFail("huge delta should crossfade")
        }
        XCTAssertEqual(duration, 0.20, accuracy: 0.001)
    }

    func testReduceMotionCollapsesToShortCrossfade() {
        guard case .crossfade(let duration) = plan(old: 300, new: 120, reduceMotion: true) else {
            return XCTFail("Reduce Motion must not slide")
        }
        XCTAssertEqual(duration, 0.12, accuracy: 0.001)
    }

    func testReduceMotionKeepsSmallDeltasInstant() {
        XCTAssertEqual(plan(old: 200, new: 230, reduceMotion: true), .none,
                       "Reduce Motion never ADDS animation")
    }

    func testNovelScaleDocumentsSkipMotion() {
        // No eager layout past 200k chars → geometry is estimates; motion
        // built on estimates would animate to a lie.
        XCTAssertEqual(plan(old: 300, new: 120, length: 500_000), .none)
    }

    func testDegenerateViewportSkips() {
        XCTAssertEqual(plan(old: 300, new: 120, viewport: 0), .none)
    }
}
#endif
