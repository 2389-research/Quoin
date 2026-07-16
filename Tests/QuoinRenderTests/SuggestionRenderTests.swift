#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Rendering + reveal for CriticMarkup marks (suggestions design, S1).
final class SuggestionRenderTests: XCTestCase {

    private let source = "Alpha {++added++} beta {--removed--} gamma {~~old~>new~~} " +
                         "delta {>>a note<<} epsilon {==flagged==}{#c1} omega.\n"

    func testRenderedProjectionStylesEachKind() throws {
        let document = MarkdownConverter.parse(source)
        let rendered = AttributedRenderer().render(document)
        let text = rendered.attributed.string

        // Marks render as tracked changes, never silently collapsed (RDFM
        // rule): inserted and deleted text BOTH visible; the substitution
        // shows old → new; the comment collapses to a labeled chip.
        XCTAssertTrue(text.contains("added"))
        XCTAssertTrue(text.contains("removed"))
        XCTAssertTrue(text.contains("old → new"))
        XCTAssertTrue(text.contains("💬 a note"))
        XCTAssertTrue(text.contains("flagged"))
        // The raw delimiters do NOT appear in the rendered projection.
        XCTAssertFalse(text.contains("{++"))
        XCTAssertFalse(text.contains("~>"))
        XCTAssertFalse(text.contains("{#c1}"))

        // Kind styling: insertion carries the insert fill; deletion is struck.
        let theme = Theme()
        let ns = text as NSString
        let insertAt = ns.range(of: "added").location
        XCTAssertEqual(
            rendered.attributed.attribute(.backgroundColor, at: insertAt, effectiveRange: nil) as? PlatformColor,
            theme.suggestionInsertFill)
        let deleteAt = ns.range(of: "removed").location
        XCTAssertNotNil(rendered.attributed.attribute(.strikethroughStyle, at: deleteAt, effectiveRange: nil))
    }

    func testRevealIsOneToOneAndClaimsBeforeStrikethroughAndHighlight() throws {
        let document = MarkdownConverter.parse(source)
        let block = try XCTUnwrap(document.blocks.first)
        let slice = try XCTUnwrap(document.source.substring(in: block.range))
        let renderer = AttributedRenderer()
        let revealed = renderer.renderEditableSourceFragment(
            slice, caretOffset: 0, block: block, document: document)

        // The 1:1 contract: revealed characters are exactly the source slice.
        XCTAssertEqual((revealed.attributed.string as NSString)
            .substring(with: revealed.editableRange), slice)

        // The critic pass claimed `{~~…~~}` before the `~~` strikethrough
        // pass: the substitution's OLD half is struck (kind styling), but the
        // sigils themselves are faded delimiters, not strikethrough content.
        let ns = revealed.attributed.string as NSString
        let oldAt = ns.range(of: "old~>").location
        XCTAssertNotNil(revealed.attributed.attribute(.strikethroughStyle, at: oldAt, effectiveRange: nil),
                        "substitution old half styles as deletion in the reveal")
        // And `{==flagged==}` took the critic highlight fill, not the lime
        // `==` highlight fill.
        let flaggedAt = ns.range(of: "flagged").location
        XCTAssertEqual(
            revealed.attributed.attribute(.backgroundColor, at: flaggedAt, effectiveRange: nil) as? PlatformColor,
            Theme().suggestionHighlightFill)
    }
}

// MARK: - Styler agrees with the scanner (panel review)

extension SuggestionRenderTests {
    func testRevealDoesNotStyleLiteralTextAsASubstitution() throws {
        // `{~~a~~}` has no arrow before its closer — the scanner degrades
        // it to literal text. The old lazy regex matched from `{~~` through
        // a LATER `~~}`, tinting the literal prose between them as a mark.
        let source = "Odd {~~a~~} then x~>y ~~}.\n"
        let document = MarkdownConverter.parse(source)
        XCTAssertTrue(SuggestionResolver.marks(in: document).isEmpty, "scanner: literal")
        let block = try XCTUnwrap(document.blocks.first)
        let revealed = AttributedRenderer().renderEditableSourceFragment(
            source.trimmingCharacters(in: .newlines), caretOffset: 0,
            block: block, document: document)
        let ns = revealed.attributed.string as NSString
        let thenAt = ns.range(of: "then x").location
        XCTAssertNil(
            revealed.attributed.attribute(.strikethroughStyle, at: thenAt, effectiveRange: nil),
            "literal prose must not carry substitution mark styling")
    }
}

// MARK: - The endmatter is INVISIBLE in the document (redline 2026-07-15)

extension SuggestionRenderTests {
    func testEndmatterRendersNothingButKeepsItsBlockRange() throws {
        // v1 rendered the YAML, v2 a summary chip — both redlined. The
        // Review panel is the endmatter's ENTIRE UI; the document shows
        // nothing, and the caret can't land inside phantom metadata text.
        let source = "Body {++x++}{#s1}.\n\n---\nsuggestions:\n  s1: { by: AI }\n"
        let document = MarkdownConverter.parse(source)
        let rendered = AttributedRenderer().render(document)
        let block = try XCTUnwrap(document.blocks.first {
            if case .reviewEndmatter = $0.kind { return true }
            return false
        })
        let range = try XCTUnwrap(rendered.blockRanges[block.id], "block bookkeeping survives")
        let text = (rendered.attributed.string as NSString).substring(with: range)
        XCTAssertTrue(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "no visible endmatter text, got: \(text.debugDescription)")
        XCTAssertFalse(rendered.attributed.string.contains("review metadata"),
                       "the chip is gone")
    }
}
#endif
