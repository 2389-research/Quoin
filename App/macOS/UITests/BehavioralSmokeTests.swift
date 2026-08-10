import XCTest

/// Proof-of-concept BEHAVIORAL XCUITest: drives the REAL app with REAL key
/// events (not synthetic NSEvent injection, which the sandbox drops) and
/// asserts the outcome — the "the machine tries it, not a human" layer.
/// This one proves typing lands in the editor; the resurrection/Return/Save-As
/// flows follow the same shape.
final class BehavioralSmokeTests: XCTestCase {

    /// The fixture library is created by the SHELL before the test run (the
    /// sandboxed test process can't write /tmp; the app CAN read it — same as
    /// the screenshot tests). Path comes via QUOIN_BEHAVIORAL_LIB.
    private var fixtureLibrary: String {
        ProcessInfo.processInfo.environment["QUOIN_BEHAVIORAL_LIB"]
            ?? "/tmp/quoin-behavioral-fixture"
    }

    override func setUp() { continueAfterFailure = false }

    func testTypingLandsInTheEditor() throws {
        let library = fixtureLibrary
        let app = XCUIApplication()
        app.launchArguments = ["-QuoinLibraryPath", library]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "main window should appear")

        // Open the empty Note.md from the sidebar.
        let row = app.staticTexts["Note"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "sidebar should list Note")
        row.click()

        // Focus the editor text view and type real characters.
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "editor text view should exist")
        editor.click()

        let marker = "XCUITEST_TYPED_THIS_123"
        app.typeText(marker)

        // The typed text must appear in the editor's value — proving real
        // keystrokes reached the projection editor and round-tripped.
        let value = editor.value as? String ?? ""
        XCTAssertTrue(value.contains(marker),
                      "typed text should appear in the editor; got: \(value.prefix(120))")
    }
}
