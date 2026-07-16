#if canImport(AppKit)
import XCTest
import AppKit
@testable import QuoinRender

/// The live panel's presentation decision table (three-expert synthesis,
/// docs/design/embed-editing-ux.md §6b refinement). Every timing constant
/// in the editing feel is pinned here. The governing asymmetry: good news
/// is instant, bad news is patient, motion only where it informs.
final class PreviewPanelChoreographerTests: XCTestCase {

    private func image(_ size: CGSize = CGSize(width: 100, height: 80)) -> NSImage {
        NSImage(size: size)
    }

    func testFirstImageAppears() {
        var choreographer = PreviewPanelChoreographer()
        let plan = choreographer.plan(
            for: .init(image: image(), paused: false, revision: 1), at: 0)
        XCTAssertEqual(plan.treatment, .appear)
        XCTAssertFalse(plan.showsPausedBadge)
    }

    func testGoodNewsIsInstantAtTypingCadence() {
        var choreographer = PreviewPanelChoreographer()
        _ = choreographer.plan(for: .init(image: image(), paused: false, revision: 1), at: 0)
        // 10 keystrokes/second, each producing a fresh render — every one
        // lands immediately, hard cut (no debounce, no crossfade smear).
        for step in 1...10 {
            let plan = choreographer.plan(
                for: .init(image: image(), paused: false, revision: 1 + step),
                at: Double(step) * 0.1)
            XCTAssertEqual(plan.treatment, .instant,
                           "renders are never debounced (step \(step))")
        }
    }

    func testIsolatedSizeChangeDissolves() {
        var choreographer = PreviewPanelChoreographer()
        _ = choreographer.plan(for: .init(image: image(), paused: false, revision: 1), at: 0)
        // An isolated swap (idle > cadence window) whose size changed —
        // paste, undo, big edit — dissolves so the shape-pop is readable.
        let plan = choreographer.plan(
            for: .init(image: image(CGSize(width: 240, height: 200)), paused: false, revision: 2),
            at: 2.0)
        XCTAssertEqual(plan.treatment, .dissolve)
    }

    func testIsolatedSameSizeSwapIsInstant() {
        var choreographer = PreviewPanelChoreographer()
        _ = choreographer.plan(for: .init(image: image(), paused: false, revision: 1), at: 0)
        // Same-size isolated swap: the hard cut IS the signal — the eye
        // reads the delta; crossfading near-identical frames smears.
        let plan = choreographer.plan(
            for: .init(image: image(), paused: false, revision: 2), at: 2.0)
        XCTAssertEqual(plan.treatment, .instant)
    }

    func testCadenceSizeChangeStaysInstant() {
        var choreographer = PreviewPanelChoreographer()
        _ = choreographer.plan(for: .init(image: image(), paused: false, revision: 1), at: 0)
        // Mid-typing size churn (mermaid re-lays-out per label keystroke)
        // must never animate — continuous 10Hz motion is churn, not signal.
        let plan = choreographer.plan(
            for: .init(image: image(CGSize(width: 300, height: 240)), paused: false, revision: 2),
            at: 0.1)
        XCTAssertEqual(plan.treatment, .instant)
    }

    func testIdenticalInputIsInert() {
        var choreographer = PreviewPanelChoreographer()
        let img = image()
        _ = choreographer.plan(for: .init(image: img, paused: false, revision: 1), at: 0)
        // Caret blinks / scrolls re-present constantly; nothing may move.
        for t in stride(from: 1.0, to: 3.0, by: 0.1) {
            let plan = choreographer.plan(
                for: .init(image: img, paused: false, revision: 1), at: t)
            XCTAssertEqual(plan.treatment, .none)
            XCTAssertNil(plan.recheckAfter)
        }
    }

    func testPausedBadgeRequiresTypingIdle() {
        var choreographer = PreviewPanelChoreographer()
        let img = image()
        _ = choreographer.plan(for: .init(image: img, paused: false, revision: 1), at: 0)

        // Typing THROUGH invalid states: every keystroke resets the grace
        // timer — the badge never appears mid-burst, however long.
        var t = 1.0
        for step in 0..<20 {
            let plan = choreographer.plan(
                for: .init(image: img, paused: true, revision: 2 + step), at: t)
            XCTAssertFalse(plan.showsPausedBadge,
                           "no badge while the user is still typing (t=\(t))")
            t += 0.2 // 200ms interkey, 4 seconds of continuously invalid typing
        }

        // The user STOPS on broken source: badge after the grace period.
        let idle = choreographer.plan(
            for: .init(image: img, paused: true, revision: 21), at: t + 0.6)
        XCTAssertTrue(idle.showsPausedBadge,
                      "brokenness is admitted once the user pauses to look")

        // Recovery clears it synchronously with the fixing keystroke.
        let healed = choreographer.plan(
            for: .init(image: img, paused: false, revision: 22), at: t + 0.7)
        XCTAssertFalse(healed.showsPausedBadge)
    }

    func testResumeAfterAdmittedPauseDissolves() {
        var choreographer = PreviewPanelChoreographer()
        let img = image()
        _ = choreographer.plan(for: .init(image: img, paused: false, revision: 1), at: 0)
        // Break, idle past the grace period → badge admitted.
        _ = choreographer.plan(for: .init(image: img, paused: true, revision: 2), at: 1.0)
        let admitted = choreographer.plan(for: .init(image: img, paused: true, revision: 2), at: 1.6)
        XCTAssertTrue(admitted.showsPausedBadge)
        // The fixing render must be PERCEIVABLE — a hard cut after a
        // paused episode is blink-missable (change blindness).
        let resumed = choreographer.plan(
            for: .init(image: image(), paused: false, revision: 3), at: 1.8)
        XCTAssertEqual(resumed.treatment, .dissolve)
        XCTAssertFalse(resumed.showsPausedBadge)
    }

    func testBadgeDecisionSchedulesARecheck() {
        var choreographer = PreviewPanelChoreographer()
        let img = image()
        _ = choreographer.plan(for: .init(image: img, paused: false, revision: 1), at: 0)
        let pending = choreographer.plan(for: .init(image: img, paused: true, revision: 2), at: 1.0)
        XCTAssertFalse(pending.showsPausedBadge)
        let recheck = try! XCTUnwrap(pending.recheckAfter)
        XCTAssertEqual(recheck, 0.5, accuracy: 0.01,
                       "the badge decision re-evaluates exactly at the grace boundary")
    }

    func testResetForgetsEverything() {
        var choreographer = PreviewPanelChoreographer()
        _ = choreographer.plan(for: .init(image: image(), paused: true, revision: 1), at: 0)
        choreographer.reset()
        let plan = choreographer.plan(for: .init(image: image(), paused: false, revision: 9), at: 10)
        XCTAssertEqual(plan.treatment, .appear, "a fresh session appears fresh")
    }
}
#endif
