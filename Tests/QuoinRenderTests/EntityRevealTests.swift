#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Ledger #3: a revealed line of HTML entities must be READABLE. Entities
/// on the caret's line show their full literal source (`&amp;`, not a
/// naked faded `&`); entities on other lines stay collapsed so the
/// block's reveal height stays put.
final class EntityRevealTests: XCTestCase {

    private let source = "Entities: &amp; &lt; &gt; here.\nSecond line: &copy; &trade; done."

    /// True when the run at `location` is hidden (the 0.1pt collapse font).
    private func isHidden(_ styled: NSAttributedString, at location: Int) -> Bool {
        guard let font = styled.attribute(.font, at: location, effectiveRange: nil) as? NSFont else {
            return false
        }
        return font.pointSize < 1
    }

    func testEntitiesOnTheCaretLineExpand() throws {
        let styler = MarkdownSourceStyler(theme: Theme())
        let ns = source as NSString
        // Caret at the END of line 1 — inside no entity span, but on their line.
        let caret = ns.range(of: "here").location
        let styled = styler.style(source, caretOffset: caret)

        // The tail of EVERY entity on line 1 is visible.
        for entity in ["&amp;", "&lt;", "&gt;"] {
            let range = ns.range(of: entity)
            XCTAssertFalse(isHidden(styled, at: range.location + 2),
                           "\(entity) on the caret's line must show its literal source")
        }
        // Entities on the OTHER line stay collapsed (anti-reflow).
        let copyRange = ns.range(of: "&copy;")
        XCTAssertTrue(isHidden(styled, at: copyRange.location + 2),
                      "entities off the caret's line stay compact")
    }

    func testEntitiesCollapseWhenCaretIsElsewhere() throws {
        let styler = MarkdownSourceStyler(theme: Theme())
        let ns = source as NSString
        let styled = styler.style(source, caretOffset: ns.range(of: "done").location)
        let ampRange = ns.range(of: "&amp;")
        XCTAssertTrue(isHidden(styled, at: ampRange.location + 2))
        XCTAssertFalse(isHidden(styled, at: ns.range(of: "&copy;").location + 2),
                       "second line is the caret's line now")
    }
}
#endif
