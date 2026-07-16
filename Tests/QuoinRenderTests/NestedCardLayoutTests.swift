#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// Ledger #1/#2: content nested inside a container must LOOK nested. A
/// card child (code canvas, diagram frame) carries the container's
/// accumulated leading inset so its full-width chrome starts at the text
/// column instead of x = 0; a loose list item's continuation paragraph
/// aligns under the item's text, not the margin.
final class NestedCardLayoutTests: XCTestCase {

    private func render(_ source: String) -> RenderedDocument {
        AttributedRenderer().render(MarkdownConverter.parse(source))
    }

    private func decorations(in attributed: NSAttributedString) -> [(NSRange, BlockDecoration)] {
        var found: [(NSRange, BlockDecoration)] = []
        attributed.enumerateAttribute(
            QuoinAttribute.blockDecoration,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            if let decoration = value as? BlockDecoration { found.append((range, decoration)) }
        }
        return found
    }

    func testCodeInsideBlockquoteIsInset() throws {
        let rendered = render("""
        > Quote text.
        >
        > ```js
        > console.log("nested");
        > ```
        >
        > More quote.
        """)
        let canvas = try XCTUnwrap(decorations(in: rendered.attributed).first {
            if case .codeCanvas = $0.1.kind { return true }
            return false
        })
        XCTAssertEqual(canvas.1.leadingInset, 16,
                       "the canvas nests inside the quote (was x=0 full-width breakout)")
        // And its text moved with it.
        let style = try XCTUnwrap(rendered.attributed.attribute(
            .paragraphStyle, at: canvas.0.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThanOrEqual(style.headIndent, 16 + 12,
                                    "code text carries quote indent + canvas padding")
    }

    func testCodeInsideLooseListItemIsInset() throws {
        let rendered = render("""
        - Loose item.

          ```python
          print("inside item")
          ```

        - Next item.
        """)
        let canvas = try XCTUnwrap(decorations(in: rendered.attributed).first {
            if case .codeCanvas = $0.1.kind { return true }
            return false
        })
        XCTAssertEqual(canvas.1.leadingInset, 22,
                       "the canvas nests under the item's text column")
    }

    func testLooseContinuationParagraphAlignsUnderTheItem() throws {
        let rendered = render("""
        - Loose item one.

          This paragraph belongs to loose item one.

        - Loose item two.
        """)
        let text = rendered.attributed.string as NSString
        let continuation = text.range(of: "This paragraph belongs")
        XCTAssertNotEqual(continuation.location, NSNotFound)
        let style = try XCTUnwrap(rendered.attributed.attribute(
            .paragraphStyle, at: continuation.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.firstLineHeadIndent, 22,
                       "continuation paragraphs start at the item's text column, not x=0")
        XCTAssertEqual(style.headIndent, 22)
    }

    func testCalloutPreservesNestedCardDecoration() throws {
        let rendered = render("""
        > [!NOTE]
        > Callout text.
        >
        > ```js
        > console.log("in callout");
        > ```
        """)
        let all = decorations(in: rendered.attributed)
        let canvas = all.first {
            if case .codeCanvas = $0.1.kind { return true }
            return false
        }
        // Fixture only meaningful if this parsed as a callout at all.
        let hasCallout = all.contains {
            if case .callout = $0.1.kind { return true }
            return false
        }
        guard hasCallout else { throw XCTSkip("fixture did not parse as a callout") }
        let unwrapped = try XCTUnwrap(canvas,
            "the callout box must not blanket-replace the child's canvas")
        XCTAssertEqual(unwrapped.1.leadingInset, 12, "canvas nests inside the callout box")
    }

    func testTopLevelCardsKeepZeroInset() throws {
        let rendered = render("```swift\nlet a = 1\n```\n")
        let canvas = try XCTUnwrap(decorations(in: rendered.attributed).first {
            if case .codeCanvas = $0.1.kind { return true }
            return false
        })
        XCTAssertEqual(canvas.1.leadingInset, 0)
    }
}
#endif
