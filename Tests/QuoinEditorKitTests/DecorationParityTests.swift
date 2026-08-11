#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
import QuoinRender
@testable import QuoinEditorKit

@MainActor
final class DecorationParityTests: XCTestCase {
    // Theme has no `.graphite` member (see BlockRenderCellTests); the default
    // constructor is the app default.
    private func boxes(for source: String, width: CGFloat = 600) -> [DecorationDraw.Box] {
        let doc = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        let cell = BlockRenderCell()
        cell.configure(block: doc.blocks[0], document: doc, renderer: renderer, theme: Theme(), width: width)
        return cell.decorationBoxesForTest()   // test hook exposing DecorationDraw.boxes(...) for the configured cell
    }
    func testCodeBlockHasOneFullWidthCanvas() {
        let bs = boxes(for: "```swift\nlet x = 1\nlet y = 2\n```")
        let canvases = bs.filter { if case .codeCanvas = $0.kind { return true }; return false }
        XCTAssertEqual(canvases.count, 1)
        XCTAssertGreaterThan(canvases[0].rect.width, 400)     // spans the content column, not one glyph
        XCTAssertGreaterThan(canvases[0].rect.height, 20)     // covers both code lines
    }
    func testTableHasPerRowRules() {
        let bs = boxes(for: "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |")
        let rules = bs.filter { if case .tableRules = $0.kind { return true }; return false }
        XCTAssertEqual(rules.count, 1)
        XCTAssertGreaterThanOrEqual(rules[0].rowFrames.count, 3)   // header + 2 body rows
    }
}
#endif
