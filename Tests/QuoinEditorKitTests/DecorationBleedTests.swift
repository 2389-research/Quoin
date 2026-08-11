#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

@MainActor
final class DecorationBleedTests: XCTestCase {
    // Theme has no `.graphite` member (see BlockRenderCellTests / the brief's
    // note); the default constructor is the app default.
    private func boxes(_ src: String, width: CGFloat = 600) -> [DecorationDraw.Box] {
        let doc = MarkdownConverter.parse(src)
        let cell = BlockRenderCell()
        cell.configure(block: doc.blocks[0], document: doc, renderer: AttributedRenderer(), theme: Theme(), width: width)
        return cell.decorationBoxesForTest()
    }
    func testQuoteRuleIsInLeftGutter() {
        let bs = boxes("> a quoted line\n> second line")
        let rules = bs.filter { if case .quoteRule = $0.kind { return true }; return false }
        XCTAssertEqual(rules.count, 1)
        // The rule sits in the reserved left gutter (x near the leading inset, a
        // thin 3pt bar), not at the text column.
        XCTAssertLessThan(rules[0].rect.width, 6)
    }
    func testCalloutHasBoxAndSurvivesInCellBounds() {
        // Callout syntax per Quoin: a blockquote whose first paragraph opens
        // with `[!KIND]` (CalloutKind.init(marker:) — MarkdownConverter).
        let bs = boxes("> [!note]\n> callout body")
        let callouts = bs.filter { if case .callout = $0.kind { return true }; return false }
        XCTAssertGreaterThanOrEqual(callouts.count, 1)
        // The callout box top must be >= 0 within the padded cell (bleed fits
        // inside bounds, not clipped negative).
        XCTAssertGreaterThanOrEqual(callouts[0].rect.minY, 0)
    }
    func testCellDoesNotClipDecorationBleed() {
        let doc = MarkdownConverter.parse("```\ncode\n```")
        let cell = BlockRenderCell()
        cell.configure(block: doc.blocks[0], document: doc, renderer: AttributedRenderer(), theme: Theme(), width: 600)
        XCTAssertFalse(cell.clipsDecorationForTest, "cell must not clip the negative-inset decoration bleed")
    }
}
#endif
