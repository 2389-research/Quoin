import XCTest

/// Launches the app against a fixture library and captures window
/// screenshots. On CI the PNGs are uploaded as artifacts — this is how a
/// cloud session (no macOS GUI) gets eyes on the real app.
final class ScreenshotTests: XCTestCase {

    private var outputDirectory: URL {
        let path = ProcessInfo.processInfo.environment["QUOIN_SCREENSHOT_DIR"]
            ?? "/tmp/quoin-shots"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private var fixturesPath: String {
        ProcessInfo.processInfo.environment["QUOIN_FIXTURES"] ?? "/tmp/quoin-fixtures"
    }

    override func setUp() {
        // A single failed event synthesis must skip one shot, not kill the
        // whole gallery.
        continueAfterFailure = true
    }

    func testCaptureMainWindow() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let app = XCUIApplication()
        app.launchArguments = ["-QuoinLibraryPath", fixturesPath]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "main window should appear")
        capture(name: "01-library", window: window)

        // Open the showcase document from the sidebar.
        let row = app.staticTexts["showcase"]
        if row.waitForExistence(timeout: 5) {
            row.click()
            Thread.sleep(forTimeInterval: 2)
            capture(name: "02-document", window: window)

            // The engines fixture leads with math + diagrams, so the
            // interesting content is in the first viewport — no synthetic
            // scrolling (which is unreliable on runner Macs).
            let engines = app.staticTexts["engines"]
            if engines.waitForExistence(timeout: 3) {
                engines.click()
                Thread.sleep(forTimeInterval: 2)
                capture(name: "03-native-engines", window: window)
            }

            // Structure fixture: state, class, and ER diagrams.
            let structure = app.staticTexts["structure"]
            if structure.waitForExistence(timeout: 3) {
                structure.click()
                Thread.sleep(forTimeInterval: 2)
                capture(name: "04-structure-diagrams", window: window)
            }

            // Syntax reveal: click into the document body.
            let textView = app.textViews.firstMatch
            if textView.exists {
                textView.click()
                Thread.sleep(forTimeInterval: 1.5)
                capture(name: "07-syntax-reveal", window: window)
            }
        }
        app.terminate()
    }

    /// Chrome states are driven by launch arguments (deterministic) rather
    /// than synthetic keyboard events (flaky on headless runners): one
    /// short launch per state.
    func testCaptureChromeStates() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // `open == nil` relies on the state's default fixture
        // (MainWindow.defaultShotFixture); `extra` carries any additional
        // launch args (e.g. the code-theme id). The review-family states
        // open the 21-suggestion review-stress-test fixture.
        let states: [(state: String, open: String?, extra: [String], shot: String)] = [
            ("find", "engines.md", [], "08-find-bar"),
            ("export", "engines.md", [], "09-export-sheet"),
            ("quickopen", nil, [], "10-quick-open"),
            ("libsearch", nil, [], "11-library-search"),
            // New feature surfaces (review loop, properties, code themes, footnotes).
            ("review", nil, [], "15-review-panel"),
            ("properties", nil, [], "16-properties-panel"),
            ("reviewmode", nil, [], "17-review-mode"),
            ("codethemes", nil, ["-QuoinCodeTheme", "dracula"], "18-code-theme"),
            ("codethemes", nil, ["-QuoinCodeTheme", "github-light"], "18b-code-theme-light"),
            ("footnotes", nil, [], "19-footnotes"),
        ]

        for entry in states {
            let app = XCUIApplication()
            var arguments = ["-QuoinLibraryPath", fixturesPath, "-QuoinShotState", entry.state]
            if let open = entry.open {
                arguments += ["-QuoinShotOpen", open]
            }
            arguments += entry.extra
            app.launchArguments = arguments
            app.launch()
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 3.5)
            capture(name: entry.shot, window: window)
            app.terminate()
        }
    }

    /// Dark-appearance pass for the review loop — Quoin's differentiator, so
    /// it earns a dark shot like the document/engines gallery.
    func testCaptureReviewDark() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let app = XCUIApplication()
        app.launchArguments = [
            "-QuoinLibraryPath", fixturesPath,
            "-QuoinShotState", "review",
            "-QuoinForceDarkMode", "YES",
        ]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3.5)
        capture(name: "15-review-panel-dark", window: window)
        app.terminate()
    }

    /// Dark-appearance pass: verifies the handoff rules (inverted ink/canvas,
    /// code surface constant) on a real render.
    func testCaptureDarkMode() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let app = XCUIApplication()
        app.launchArguments = [
            "-QuoinLibraryPath", fixturesPath,
            "-QuoinForceDarkMode", "YES",
        ]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let row = app.staticTexts["showcase"]
        if row.waitForExistence(timeout: 5) {
            row.click()
            Thread.sleep(forTimeInterval: 2)
            capture(name: "05-dark-document", window: window)

            // Syntax reveal in dark: click into the body to activate a block.
            let textView = app.textViews.firstMatch
            if textView.exists {
                textView.click()
                Thread.sleep(forTimeInterval: 1.5)
                capture(name: "07-syntax-reveal-dark", window: window)
            }
        }
        let engines = app.staticTexts["engines"]
        if engines.waitForExistence(timeout: 3) {
            engines.click()
            Thread.sleep(forTimeInterval: 2)
            capture(name: "06-dark-engines", window: window)
        }
        app.terminate()
    }

    /// Diagnostic: drives the `codeEdit` self-repro (activate the first code
    /// block + type into it) and captures the active editing state, so a
    /// headless session can SEE the code-block rendering overlap (accent frame
    /// vs canvas vs revealed source geometry) instead of guessing.
    func testCaptureCodeEditing() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let app = XCUIApplication()
        app.launchArguments = [
            "-QuoinLibraryPath", fixturesPath,
            "-QuoinShotOpen", "showcase.md",
            "-QuoinShotState", "codeEdit",
        ]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        // The self-drive activates at ~2s and types at ~3s; capture after it
        // settles, then once more to catch any lingering box-lag.
        Thread.sleep(forTimeInterval: 4.5)
        capture(name: "20-code-editing", window: window)
        Thread.sleep(forTimeInterval: 1.5)
        capture(name: "21-code-editing-settled", window: window)
        app.terminate()
    }

    /// Captures the app's window (cropped — README/CI quality) when
    /// available, falling back to the full screen.
    private func capture(name: String, window: XCUIElement? = nil) {
        let screenshot: XCUIScreenshot
        if let window, window.exists {
            screenshot = window.screenshot()
        } else {
            screenshot = XCUIScreen.main.screenshot()
        }
        let url = outputDirectory.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// README feature gallery: each gallery fixture leads with its feature
    /// so the first viewport is the shot — no synthetic scrolling.
    func testCaptureFeatureGallery() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // The site shows the diagram/math galleries with a `<picture>` dark
        // source, so both galleries get a `-dark` companion; blocks stays
        // light-only (README only).
        let shots: [(fixture: String, name: String, dark: Bool)] = [
            ("gallery-diagrams", "12-gallery-diagrams", false),
            ("gallery-math", "13-gallery-math", false),
            ("gallery-blocks", "14-gallery-blocks", false),
            ("gallery-diagrams", "12-gallery-diagrams-dark", true),
            ("gallery-math", "13-gallery-math-dark", true),
        ]
        for entry in shots {
            let app = XCUIApplication()
            app.launchArguments = [
                "-QuoinLibraryPath", fixturesPath,
                "-QuoinShotOpen", "\(entry.fixture).md",
            ] + (entry.dark ? ["-QuoinForceDarkMode", "YES"] : [])
            app.launch()
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 3)
            capture(name: entry.name, window: window)
            app.terminate()
        }
    }
}
