#if canImport(AppKit) || canImport(UIKit)
import XCTest
@testable import QuoinRender
import QuoinCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Unit tests for the pure `TableLayout` extracted from `renderTable`. A fake
/// measurer (width = character count × 10) makes the geometry deterministic
/// and font-free, so these cover exactly what the render golden can't: column
/// widths, tab-stop *locations*, alignment inference, and numeric detection.
final class TableLayoutTests: XCTestCase {

    private func cell(_ text: String) -> TableCell { TableCell(inlines: [.text(text)]) }
    private func row(_ texts: [String]) -> [TableCell] { texts.map(cell) }

    /// width = 10 per character — independent of the (ignored) font.
    private let measure: TableLayout.Measurer = { text, _ in CGFloat(text.count) * 10 }

    private func layout(
        header: [String], rows: [[String]], alignments: [TableAlignment] = [],
        columnGap: CGFloat = 24, maxColumnWidth: CGFloat = 1000
    ) -> TableLayout? {
        let font = PlatformFont.systemFont(ofSize: 14)
        return TableLayout.compute(
            header: header.map(cell), rows: rows.map(row), alignments: alignments,
            bodyFont: font, headerFont: font, columnGap: columnGap, maxColumnWidth: maxColumnWidth,
            measure: measure
        )
    }

    func testWidthsTakeTheWidestCellAndColumnCountSpansRows() {
        let l = try! XCTUnwrap(layout(header: ["Name", "Qty"], rows: [["Apple", "3"], ["Fig", "12"]]))
        XCTAssertEqual(l.columnCount, 2)
        XCTAssertEqual(l.widths, [50, 30], "col0 widest is Apple(5), col1 widest is Qty(3)")
        XCTAssertEqual(l.totalWidth, 104, "0..50 + 24 gap → col1 start 74, +30 width")
    }

    func testNumericColumnsRightAlignAndUseTabularNumerals() {
        let l = try! XCTUnwrap(layout(header: ["Name", "Qty"], rows: [["Apple", "3"], ["Fig", "12"]]))
        XCTAssertEqual(l.isNumeric, [false, true])
        XCTAssertEqual(l.alignments, [.left, .right], "an all-numeric column auto right-aligns")
    }

    func testExplicitAlignmentOverridesNumericInference() {
        // A numeric column marked centered stays centered, not auto-right.
        let l = try! XCTUnwrap(layout(
            header: ["A", "N"], rows: [["x", "1"], ["y", "2"]], alignments: [.left, .center]
        ))
        XCTAssertEqual(l.isNumeric, [false, true])
        XCTAssertEqual(l.alignments, [.left, .center])
    }

    func testTabStopsPlaceEachColumnAfterTheFirst() {
        let l = try! XCTUnwrap(layout(header: ["Name", "Qty"], rows: [["Apple", "3"]]))
        XCTAssertEqual(l.tabStops.count, 1, "column 0 needs no tab; column 1 gets one")
        let tab = l.tabStops[0]
        XCTAssertEqual(tab.alignment, .right, "the numeric column right-aligns within its span")
        XCTAssertEqual(tab.location, 104, "col1 start 74 + width 30 = right edge 104")
    }

    func testCenterColumnTabSitsAtColumnMidpoint() {
        let l = try! XCTUnwrap(layout(
            header: ["A", "Middle"], rows: [["x", "y"]], alignments: [.left, .center]
        ))
        let tab = l.tabStops[0]
        XCTAssertEqual(tab.alignment, .center)
        // col0 width = A(1)*10 = 10 → col1 start 10 + 24 = 34; width Middle(6)=60;
        // center tab at start + width/2 = 34 + 30 = 64.
        XCTAssertEqual(tab.location, 64)
    }

    func testRunawayColumnIsCappedAtMaxColumnWidth() {
        let long = String(repeating: "x", count: 200) // would be 2000pt uncapped
        let l = try! XCTUnwrap(layout(header: ["A", long], rows: [["1", "2"]], maxColumnWidth: 300))
        XCTAssertEqual(l.widths[1], 300, "a runaway column is capped so it can't eat the page")
    }

    func testEmptyTableProducesNoLayout() {
        XCTAssertNil(layout(header: [], rows: []), "no columns → nil, and renderTable emits nothing")
    }

    func testNumericDetectionAcceptsPunctuationButRequiresADigit() {
        XCTAssertTrue(TableLayout.isNumeric("1,234.50"))
        XCTAssertTrue(TableLayout.isNumeric("$99"))
        XCTAssertTrue(TableLayout.isNumeric("-3.5%"))
        XCTAssertFalse(TableLayout.isNumeric("N/A"))
        XCTAssertFalse(TableLayout.isNumeric("--"), "punctuation alone with no digit is not numeric")
        XCTAssertFalse(TableLayout.isNumeric(""))
    }

    func testWrapIndentAnchorsToWidestColumnStart() {
        // A wide LAST prose column: wrapped lines must indent to its start so
        // they stay under the column, not the left margin.
        let l = try! XCTUnwrap(layout(
            header: ["Repo", "Disposition", "Role"],
            rows: [["tracker", "keep-core", "a very long role description that wraps"]]))
        // col0=70, col1=110 (Disposition), col2 widest. Starts: 0, 94, 228.
        XCTAssertEqual(l.wrapIndent, 228, "wrap indent = widest (last) column's left edge")
    }

    func testWrapIndentZeroWhenWidestColumnIsNotLeftAligned() {
        // A right-aligned widest column has no left-edge tab stop to anchor to.
        let l = try! XCTUnwrap(layout(
            header: ["Name", "Amount"],
            rows: [["a", "1234567890 a long right aligned value"]],
            alignments: [.left, .right]))
        XCTAssertEqual(l.wrapIndent, 0)
    }
}
#endif
