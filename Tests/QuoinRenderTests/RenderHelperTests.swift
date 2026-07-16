#if canImport(AppKit) || canImport(UIKit)
import XCTest
import CoreGraphics
@testable import QuoinRender
import QuoinCore
#if canImport(AppKit)
import AppKit
#endif

/// Focused unit tests for the small render helpers that the recent
/// decomposition passes extracted, exercised through the public render
/// surface so the helpers stay `private` (the render layer keeps its
/// internals encapsulated on purpose — see docs/architecture.md).
final class RenderHelperTests: XCTestCase {

    private var theme: Theme { Theme(prefersDark: false) }
    private func render(_ source: String) -> NSAttributedString {
        AttributedRenderer(theme: theme, baseURL: nil).render(MarkdownConverter.parse(source)).attributed
    }

    /// Resolved-color equality, appearance-pinned (dodges dynamic-color
    /// pointer inequality).
    private func sameColor(_ a: PlatformColor, _ b: PlatformColor) -> Bool {
        ColorTokenizer.rgba(a, prefersDark: false) == ColorTokenizer.rgba(b, prefersDark: false)
    }

    /// The substring of the first run whose foreground resolves to `color`.
    private func firstRun(coloredLike color: PlatformColor, in string: NSAttributedString) -> String? {
        var result: String?
        string.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: string.length)) { value, range, stop in
            if let c = value as? PlatformColor, sameColor(c, color) {
                result = string.attributedSubstring(from: range).string
                stop.pointee = true
            }
        }
        return result
    }

    // MARK: - codeTokenColor mapping

    /// Each highlighter token kind maps to its Graphite code color. A Swift
    /// snippet exercises keyword (`func`), function (`greet`), and string.
    func testCodeTokenColorsMapToTheme() {
        let string = render("""
        ```swift
        func greet() {
            let name = "world"
        }
        ```
        """)
        XCTAssertEqual(firstRun(coloredLike: Theme.CodeToken.keyword, in: string), "func",
            "the `func` keyword should take the keyword color")
        XCTAssertEqual(firstRun(coloredLike: Theme.CodeToken.function, in: string), "greet",
            "the call `greet(` should take the function color")
        XCTAssertEqual(firstRun(coloredLike: Theme.CodeToken.string, in: string), "\"world\"",
            "the string literal should take the string color")
    }

    /// The code-token ranges are computed as UTF-16 offsets via a prefix sum
    /// over characters, precisely so a non-BMP glyph (which is two UTF-16
    /// code units) doesn't shift every later token's color. A naive
    /// char-index == UTF-16-index mapping would paint `func` one unit early.
    func testCodeTokenOffsetsSurviveNonBMPCharacter() {
        // The emoji is one Character but two UTF-16 units; `func` follows it.
        let string = render("""
        ```swift
        // 😀 comment
        func f() {}
        ```
        """)
        // The keyword color must land exactly on "func", not on a shifted span.
        XCTAssertEqual(firstRun(coloredLike: Theme.CodeToken.keyword, in: string), "func",
            "keyword color must map through the non-BMP emoji to the exact `func` range")
    }

    // MARK: - blockSeparator card spacing

    /// The inter-block separator adds an extra low spacer line so two boxed
    /// cards never touch, and so a card not introduced by a heading gets air
    /// above it — but a heading hugs the card it introduces. The spacer is a
    /// `\n` run with a distinct paragraph style (lineHeightMultiple 1.0,
    /// paragraphSpacing 0) at 14pt.
    func testCardSpacingRules() {
        // Two paragraphs: single separator, no card spacer.
        XCTAssertFalse(hasCardSpacer(render("Alpha\n\nBravo")),
            "adjacent paragraphs should not get the card spacer")
        // Two code cards: spacer between them.
        XCTAssertTrue(hasCardSpacer(render("```\nx\n```\n\n```\ny\n```")),
            "adjacent code cards should be separated by the card spacer")
        // Paragraph then card: spacer (the card is not introduced by a heading).
        XCTAssertTrue(hasCardSpacer(render("Intro text.\n\n```\ncode\n```")),
            "a card after a paragraph should get air above it")
        // Heading then card: no spacer (the heading hugs its card).
        XCTAssertFalse(hasCardSpacer(render("# Title\n\n```\ncode\n```")),
            "a heading should hug the card it introduces")
    }

    private func hasCardSpacer(_ string: NSAttributedString) -> Bool {
        var found = false
        string.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: string.length)) { value, range, stop in
            guard let style = value as? NSParagraphStyle,
                  style.lineHeightMultiple == 1.0, style.paragraphSpacing == 0 else { return }
            let substring = string.attributedSubstring(from: range).string
            let font = string.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont
            if substring.contains("\n"), font?.pointSize == 14 { found = true; stop.pointee = true }
        }
        return found
    }

    // MARK: - MarkdownSourceStyler (syntax reveal)

    /// The single most important invariant of the source styler: it styles
    /// but never inserts or removes a character, so a caret offset in the
    /// revealed text is a source offset. The output string must equal the
    /// source exactly, UTF-16 length included.
    func testSourceStylerIsCharacterForCharacter() {
        let styler = MarkdownSourceStyler(theme: theme)
        for source in [
            "# Heading with **bold** and `code`",
            "- [ ] a task\n- [x] done with a [link](https://example.com)",
            "> quote with *emphasis* and ==highlight==\n> second line",
            "Plain paragraph with $x^2$ inline math.",
        ] {
            let styled = styler.style(source, caretOffset: nil)
            XCTAssertEqual(styled.string, source, "styler changed the text")
            XCTAssertEqual(styled.length, (source as NSString).length, "styler changed the UTF-16 length")
        }
    }

    /// Span delimiters reveal only while the caret is inside the span: 35% ink
    /// mono when the caret is within, collapsed to a 1pt clear glyph when
    /// outside. `a **b** c` — the `**` opens at UTF-16 offset 2.
    func testSpanDelimitersRevealOnlyUnderCaret() {
        let styler = MarkdownSourceStyler(theme: theme)
        let source = "a **b** c"
        let delimiterLocation = 2

        let inside = styler.style(source, caretOffset: 4)
        let insideFont = inside.attribute(.font, at: delimiterLocation, effectiveRange: nil) as? PlatformFont
        XCTAssertEqual(insideFont?.pointSize, theme.inlineCodeFont().pointSize,
            "caret inside the span reveals the delimiter at reading size")

        let outside = styler.style(source, caretOffset: 0)
        let outsideFont = outside.attribute(.font, at: delimiterLocation, effectiveRange: nil) as? PlatformFont
        // 0.1pt, not 1pt: collapsed runs must occupy ~zero width, or a long
        // hidden URL still wraps its line (see hiddenDelimiterAttributes).
        XCTAssertEqual(outsideFont?.pointSize ?? 0, 0.1, accuracy: 0.01,
            "caret outside the span collapses the delimiter to a hairline glyph")
    }

    #if canImport(AppKit)
    func testHintedSpliceAppliesBoundedReplacement() {
        let storage = NSTextStorage(string: "abcdef")
        let replacement = NSAttributedString(string: "abcXYZdef")
        let hint = RenderSpliceHint(
            oldRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: 3, length: 3)
        )

        let changed = MarkdownReaderView.Coordinator.spliceChanges(
            in: storage,
            to: replacement,
            hint: hint
        )

        XCTAssertEqual(storage.string, "abcXYZdef")
        XCTAssertEqual(changed, NSRange(location: 3, length: 3))
    }

    func testStoragePatchAppliesBoundedAttributedReplacement() {
        let storage = NSTextStorage(string: "abcdef")
        let replacement = NSAttributedString(string: "XYZ", attributes: [.foregroundColor: PlatformColor.systemRed])
        let patch = RenderStoragePatch(
            oldRange: NSRange(location: 3, length: 0),
            replacement: replacement
        )

        let changed = MarkdownReaderView.Coordinator.applyStoragePatch(
            in: storage,
            patch: patch
        )

        XCTAssertEqual(storage.string, "abcXYZdef")
        XCTAssertEqual(changed, NSRange(location: 3, length: 3))
        XCTAssertNotNil(storage.attribute(.foregroundColor, at: 3, effectiveRange: nil))
    }

    func testInvalidHintFallsBackToDiffSplice() {
        let storage = NSTextStorage(string: "abcdef")
        let replacement = NSAttributedString(string: "abQdef")
        let hint = RenderSpliceHint(
            oldRange: NSRange(location: 99, length: 1),
            replacementRange: NSRange(location: 99, length: 1)
        )

        let changed = MarkdownReaderView.Coordinator.spliceChanges(
            in: storage,
            to: replacement,
            hint: hint
        )

        XCTAssertEqual(storage.string, "abQdef")
        XCTAssertEqual(changed, NSRange(location: 2, length: 1))
    }
    #endif
}
#endif
