#if canImport(AppKit)
import XCTest
import QuoinCore
@testable import QuoinRender

final class BlockMetricsTests: XCTestCase {
    func testHeadingHeightIsPositiveAndStable() {
        let doc = MarkdownConverter.parse("# A heading\n\nBody.")
        let r = AttributedRenderer()
        let h1 = r.measuredHeight(of: doc.blocks[0], in: doc, width: 600)
        let h2 = r.measuredHeight(of: doc.blocks[0], in: doc, width: 600)
        XCTAssertGreaterThan(h1, 10)
        XCTAssertEqual(h1, h2, accuracy: 0.01, "deterministic for the cell-sizing contract")
    }
    func testTallerBlockMeasuresTaller() {
        let doc = MarkdownConverter.parse("Short.\n\nA much longer paragraph that will certainly wrap onto multiple lines when laid out at a narrow width so its measured height exceeds the short one.")
        let r = AttributedRenderer()
        let short = r.measuredHeight(of: doc.blocks[0], in: doc, width: 200)
        let long = r.measuredHeight(of: doc.blocks[1], in: doc, width: 200)
        XCTAssertGreaterThan(long, short)
    }
    func testLineTopsMonotonic() {
        let doc = MarkdownConverter.parse("Line wrapping paragraph long enough to produce several lines at a narrow width for the tops array to have more than one entry here.")
        let tops = AttributedRenderer().lineTops(of: doc.blocks[0], in: doc, width: 160)
        XCTAssertGreaterThan(tops.count, 1)
        XCTAssertEqual(tops, tops.sorted())
    }
}
#endif
