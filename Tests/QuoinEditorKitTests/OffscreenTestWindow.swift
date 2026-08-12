#if canImport(AppKit)
import XCTest
import AppKit

/// Shared AppKit test-window support for the recycler / island tests.
///
/// These tests need REAL first-responder traffic — the island's blur seam is
/// driven by genuine `becomeFirstResponder` / `resignFirstResponder` calls — but
/// they must not be a nuisance while `swift test` runs. Two things make that
/// true:
///
///  • **Offscreen placement.** Windows are created at `origin` (far off any
///    real display) instead of `(0, 0)`, so ordering one in never puts a shell
///    on the user's screen. `orderFrontRegardless()` is still required: an
///    unordered window cannot host a responder chain, so invisibility is bought
///    with GEOMETRY, not by skipping the ordering.
///  • **A non-activating process.** `NSApplication.setActivationPolicy` is set
///    once per process so xctest neither appears in the Dock nor steals focus
///    from whatever the user is doing.
///
/// ## About "key" windows here
///
/// These windows are `.borderless`, and a borderless `NSWindow` reports
/// `canBecomeKey == false` unless subclassed — so `isKeyWindow` is false in this
/// suite and ALWAYS WAS, both before and after this harness landed, and both
/// onscreen and off (measured, not assumed). It does not matter: every seam
/// under test is driven by `makeFirstResponder`, which works on a non-key
/// ordered-in window, and the island activation/blur tests prove it end to end.
/// `.borderless` is not negotiable either — a `.titled` window SWALLOWS a
/// dispatched `leftMouseDown` outright, so the click tests would silently stop
/// testing anything.
enum OffscreenTestWindow {

    /// Far enough off-origin to miss every plausible display arrangement,
    /// including displays positioned left of / above the main screen.
    static let origin = CGPoint(x: -20_000, y: -20_000)

    /// Set once, on first window creation. `.prohibited` is the quietest policy
    /// (no Dock tile, cannot activate); if the process refuses it we fall back
    /// to `.accessory`, which is still Dock-less and non-activating. Neither
    /// costs anything the seams need — verified: the island activation, blur and
    /// first-responder tests all still pass under `.prohibited`.
    private static let configureActivationPolicyOnce: Void = {
        let app = NSApplication.shared
        if !app.setActivationPolicy(.prohibited) {
            _ = app.setActivationPolicy(.accessory)
        }
    }()

    /// The process's effective activation policy after configuration (asserted
    /// by `OffscreenTestWindowTests`, so a silent regression to `.regular` —
    /// which is what makes windows visible and steals focus — is caught).
    static var activationPolicy: NSApplication.ActivationPolicy {
        _ = configureActivationPolicyOnce
        return NSApplication.shared.activationPolicy()
    }

    /// An offscreen, ordered-in, borderless window of the given content size.
    @MainActor
    static func make(width: CGFloat, height: CGFloat) -> NSWindow {
        _ = configureActivationPolicyOnce
        let window = NSWindow(
            contentRect: NSRect(x: origin.x, y: origin.y, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        // Tests hold windows in locals and close them in tearDown / defer;
        // AppKit's close-releases-window behavior would make that a dangling use.
        window.isReleasedWhenClosed = false
        // Ordered in (required to host a responder chain) but offscreen, so
        // nothing is ever visible to the user. `makeKey` is a no-op for a
        // borderless window (see the type comment) and is kept only so a future
        // keyable style mask picks key status up for free.
        window.orderFrontRegardless()
        window.makeKey()
        return window
    }
}

/// Base class for tests that stand up real AppKit windows: vends offscreen
/// windows and closes them in `tearDown`, so nothing lingers after the run.
@MainActor
class AppKitWindowTestCase: XCTestCase {
    private var trackedWindows: [NSWindow] = []

    /// An offscreen window, closed automatically at teardown.
    func makeTestWindow(width: CGFloat = 640, height: CGFloat = 480) -> NSWindow {
        let window = OffscreenTestWindow.make(width: width, height: height)
        trackedWindows.append(window)
        return window
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for window in trackedWindows {
                window.contentView = nil
                window.orderOut(nil)
                window.close()
            }
            trackedWindows.removeAll()
        }
        super.tearDown()
    }
}

/// Guards the two properties the shared harness exists to provide. Without
/// these, a refactor could quietly go back to visible, focus-stealing windows
/// and every other test would still pass.
@MainActor
final class OffscreenTestWindowTests: AppKitWindowTestCase {

    func testTestWindowsAreOffscreen() {
        let window = makeTestWindow(width: 320, height: 240)
        XCTAssertLessThan(window.frame.maxX, 0,
                          "test windows must sit off the left of every display")
        XCTAssertLessThan(window.frame.maxY, 0,
                          "test windows must sit below every display")
        for screen in NSScreen.screens {
            XCTAssertFalse(screen.frame.intersects(window.frame),
                           "test window overlaps a real screen: \(NSStringFromRect(window.frame))")
        }
        // Ordered in (so it can host a responder chain) but invisible to the user.
        XCTAssertTrue(window.isVisible,
                      "the window must be ordered in — an unordered window cannot host first responder")
    }

    func testProcessDoesNotActivateOrShowInTheDock() {
        XCTAssertNotEqual(OffscreenTestWindow.activationPolicy, .regular,
                          "the test process must not run as a regular (Dock, focus-stealing) app")
    }

    /// The property the seams actually depend on: a real first-responder handoff
    /// still works on an offscreen, non-activating window.
    func testFirstResponderStillWorksOffscreen() {
        let window = makeTestWindow(width: 320, height: 240)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        host.addSubview(field)
        window.contentView = host

        XCTAssertTrue(window.makeFirstResponder(field),
                      "an offscreen window must still hand out first responder")
        XCTAssertTrue(window.firstResponder === field.currentEditor() || window.firstResponder === field,
                      "the field (or its field editor) must hold first responder")
    }
}
#endif
