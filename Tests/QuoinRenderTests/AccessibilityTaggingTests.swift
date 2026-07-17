#if canImport(AppKit) || canImport(UIKit)
import XCTest
@testable import QuoinRender
import QuoinCore

/// End-to-end coverage that the renderer actually STAMPS the accessibility
/// structure attributes the reader view's rotors consume (accessibility
/// structure, #10). `BlockAccessibilityTests` proves the wording; this proves
/// the wiring — that `announcement(for:)` reaches a real attributed-string
/// surface (closing the "dead code" gap) and that headings carry their level.
final class AccessibilityTaggingTests: XCTestCase {

    private func render(_ source: String) -> NSAttributedString {
        let renderer = AttributedRenderer(theme: Theme(prefersDark: false), baseURL: nil)
        return renderer.render(MarkdownConverter.parse(source)).attributed
    }

    /// All `blockAccessibilityLabel` values in the rendered string, in order.
    private func landmarkLabels(_ attributed: NSAttributedString) -> [String] {
        var out: [String] = []
        attributed.enumerateAttribute(
            QuoinAttribute.blockAccessibilityLabel,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            if let label = value as? String { out.append(label) }
        }
        return out
    }

    /// All `headingLevel` values in the rendered string, in order.
    private func headingLevels(_ attributed: NSAttributedString) -> [Int] {
        var out: [Int] = []
        attributed.enumerateAttribute(
            QuoinAttribute.headingLevel,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            if let level = (value as? NSNumber)?.intValue { out.append(level) }
        }
        return out
    }

    // MARK: - Landmarks (announcement(for:) reaches the storage)

    func testCodeBlockRangeCarriesItsAnnouncement() {
        let labels = landmarkLabels(render("```swift\nlet a = 1\nlet b = 2\n```\n"))
        XCTAssertEqual(labels, ["Code block, swift, 2 lines"])
    }

    func testTableRangeCarriesItsAnnouncement() {
        let source = """
        | A | B |
        | - | - |
        | 1 | 2 |
        | 3 | 4 |
        """
        XCTAssertEqual(landmarkLabels(render(source)), ["Table, 2 columns, 2 rows"])
    }

    func testCalloutRangeCarriesItsAnnouncement() {
        let labels = landmarkLabels(render("> [!NOTE]\n> Heads up.\n"))
        XCTAssertEqual(labels, ["Note callout"])
    }

    func testMultipleStructuralBlocksEachTagged() {
        let source = """
        # Title

        A paragraph reads as its own text.

        - one
        - two

        ```
        code
        ```
        """
        // Paragraph is silent; the list and code block announce.
        XCTAssertEqual(landmarkLabels(render(source)),
                       ["Bulleted list, 2 items", "Code block, 1 line"])
    }

    func testParagraphIsNotTagged() {
        XCTAssertTrue(landmarkLabels(render("Just some prose.\n")).isEmpty)
    }

    // MARK: - Headings carry level, not a landmark label

    func testHeadingCarriesLevelAndNoLandmarkLabel() {
        let attributed = render("## Introduction\n")
        XCTAssertEqual(headingLevels(attributed), [2])
        XCTAssertTrue(landmarkLabels(attributed).isEmpty, "headings use the .heading rotor, not Landmarks")
    }

    /// Finding #3: a title-less heading is legal markdown and appears in the
    /// document outline; it must still carry `headingLevel` so it is reachable
    /// from the Headings rotor (rotor-vs-outline agreement).
    func testEmptyHeadingIsStillTaggedWithItsLevel() {
        let attributed = render("###\n")
        XCTAssertEqual(headingLevels(attributed), [3])
    }

    func testEmptyHeadingRendersAZeroWidthPlaceholderOnly() {
        // The placeholder is a single zero-width space — nothing visible, just
        // a navigable position.
        XCTAssertEqual(render("###\n").string, "\u{200B}")
    }
}
#endif
