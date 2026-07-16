#if canImport(AppKit) || canImport(UIKit)
import XCTest
import CoreGraphics
@testable import QuoinRender
import MermaidRender
import QuoinCore

/// Quoin-side integration tests for the math + diagram render paths.
///
/// The ENGINE tests (typesetter box invariants, attachment production) moved
/// to Vinculum (VinculumRenderTests) and MermaidKit respectively. What stays
/// here is how Quoin's `AttributedRenderer` wires those engines in: the
/// supported/unsupported classification driving native rendering vs. the
/// styled source-card fallback, and the `mathSource`/diagram source tagging.
final class MathAndDiagramTests: XCTestCase {

    private var theme: Theme { Theme(prefersDark: false) }

    // MARK: - Math block rendering integration

    /// The block-math renderer path: supported LaTeX gets a centered
    /// attachment tagged with `mathSource`; unsupported gets the source-card
    /// fallback (a code canvas) still tagged with `mathSource` plus a caption.
    func testMathBlockRendererTagsSourceOnBothPaths() {
        let renderer = AttributedRenderer(theme: theme, baseURL: nil)

        let supported = renderer.render(MarkdownConverter.parse("$$ x = 1 $$"))
        assertContainsMathSource(supported.attributed, "x = 1", label: "supported block math")

        let unsupported = renderer.render(MarkdownConverter.parse("$$ \\weirdcommand{x} $$"))
        assertHasCodeCanvas(unsupported.attributed, label: "unsupported block math fallback")
    }

    // MARK: - Diagrams: native vs. source-card fallback

    func testSupportedDiagramProducesAttachment() throws {
        let flowchart = """
        flowchart TD
            A[Start] --> B[Middle]
            B --> C[End]
        """
        let attachment = MermaidRenderer.attachmentString(source: flowchart, theme: theme.diagramTheme)
        let string = try XCTUnwrap(attachment, "a flowchart should render natively")
        let value = string.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        let bounds = try XCTUnwrap(value?.bounds)
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
    }

    func testGanttChartRendersNatively() throws {
        let gantt = """
        gantt
            title Schedule
            section Work
            Design :done, d1, 2026-07-01, 2d
            Build  :active, b1, after d1, 3d
            Ship   :milestone, m1, after b1, 0d
        """
        let attachment = MermaidRenderer.attachmentString(source: gantt, theme: theme.diagramTheme)
        let string = try XCTUnwrap(attachment, "a gantt chart should render natively")
        let bounds = try XCTUnwrap((string.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.bounds)
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
    }

    func testUnsupportedDiagramReturnsNilSoRendererFallsBack() {
        // A dialect the parser doesn't model returns nil from the parser, so
        // the renderer keeps the fenced source card.
        XCTAssertNil(MermaidParser.parse("nonesuchDiagram\n  a --> b"))
        XCTAssertNil(MermaidRenderer.attachmentString(
            source: "nonesuchDiagram\n  a --> b", theme: theme.diagramTheme
        ), "an unmodeled dialect must return nil so the renderer keeps the source card")
    }

    /// The renderer path: a native diagram is framed and tagged with
    /// `diagramSource`; an unsupported one degrades to a code canvas with the
    /// diagram source still attached plus a caption.
    func testDiagramRendererTagsSourceOnBothPaths() {
        let renderer = AttributedRenderer(theme: theme, baseURL: nil)

        let native = renderer.render(MarkdownConverter.parse("""
        ```mermaid
        flowchart TD
            A --> B
        ```
        """))
        assertHasDecoration(native.attributed, matching: { if case .diagramFrame = $0 { return true }; return false },
                            label: "native flowchart frame")

        let fallback = renderer.render(MarkdownConverter.parse("""
        ```mermaid
        nonesuchDiagram
            a --> b
        ```
        """))
        assertHasCodeCanvas(fallback.attributed, label: "unsupported diagram fallback")
    }

    // MARK: - Helpers

    private func assertContainsMathSource(_ string: NSAttributedString, _ expected: String, label: String) {
        var found = false
        string.enumerateAttribute(QuoinAttribute.mathSource, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if let latex = value as? String, latex.contains(expected) { found = true; stop.pointee = true }
        }
        XCTAssertTrue(found, "\(label): expected a run tagged mathSource containing \(expected)")
    }

    private func assertHasDecoration(
        _ string: NSAttributedString,
        matching predicate: (BlockDecoration.Kind) -> Bool,
        label: String
    ) {
        var found = false
        string.enumerateAttribute(QuoinAttribute.blockDecoration, in: NSRange(location: 0, length: string.length)) { value, _, stop in
            if let deco = value as? BlockDecoration, predicate(deco.kind) { found = true; stop.pointee = true }
        }
        XCTAssertTrue(found, "\(label): expected the matching block decoration")
    }

    private func assertHasCodeCanvas(_ string: NSAttributedString, label: String) {
        assertHasDecoration(string, matching: { if case .codeCanvas = $0 { return true }; return false }, label: label)
    }
}
#endif
