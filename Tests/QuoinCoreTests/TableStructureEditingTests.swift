import XCTest
@testable import QuoinCore

/// Exhaustive coverage of the structural table-source engine (#14): parse,
/// render, and the insert/delete/align/move/normalize operations across
/// simple, aligned, ragged, and malformed tables. Every operation is applied
/// through `SourceEdit.apply` (the same path the session uses) so the tests
/// verify the real byte edit, not just an in-memory model.
final class TableStructureEditingTests: XCTestCase {

    // Apply a slice-relative SourceEdit to the slice and return the result.
    private func apply(_ edit: SourceEdit?, to slice: String) throws -> String {
        let edit = try XCTUnwrap(edit)
        return try edit.apply(to: slice).result
    }

    private let simple = """
    | Name | Age |
    | --- | --- |
    | Ada | 36 |
    | Grace | 45 |
    """

    private let aligned = """
    | Item | Qty | Price |
    | :--- | :---: | ---: |
    | Apple | 3 | 1.20 |
    | Pear | 12 | 0.80 |
    """

    // MARK: - Parse

    func testParseSimple() throws {
        let table = try XCTUnwrap(TableEditing.parse(simple))
        XCTAssertEqual(table.header, ["Name", "Age"])
        XCTAssertEqual(table.columnCount, 2)
        XCTAssertEqual(table.alignments, [.none, .none])
        XCTAssertEqual(table.rows, [["Ada", "36"], ["Grace", "45"]])
    }

    func testParseAlignments() throws {
        let table = try XCTUnwrap(TableEditing.parse(aligned))
        XCTAssertEqual(table.alignments, [.left, .center, .right])
        XCTAssertEqual(table.rows, [["Apple", "3", "1.20"], ["Pear", "12", "0.80"]])
    }

    func testParseWithoutOuterPipes() throws {
        let table = try XCTUnwrap(TableEditing.parse("a | b\n--- | ---\n1 | 2"))
        XCTAssertEqual(table.header, ["a", "b"])
        XCTAssertEqual(table.rows, [["1", "2"]])
    }

    func testParseHeaderOnly() throws {
        // Header + delimiter, no body — still a valid table.
        let table = try XCTUnwrap(TableEditing.parse("| A | B |\n| --- | --- |"))
        XCTAssertEqual(table.header, ["A", "B"])
        XCTAssertTrue(table.rows.isEmpty)
    }

    func testParseRaggedPadsToWidest() throws {
        // Body row wider than the header: no cell text is lost, the model
        // rectangularizes to the widest row.
        let table = try XCTUnwrap(TableEditing.parse("| A | B |\n| --- | --- |\n| x | y | z |"))
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertEqual(table.header, ["A", "B", ""])
        XCTAssertEqual(table.alignments, [.none, .none, .none])
        XCTAssertEqual(table.rows, [["x", "y", "z"]])
    }

    func testParseRaggedShortRowPads() throws {
        let table = try XCTUnwrap(TableEditing.parse("| A | B | C |\n| --- | --- | --- |\n| x |"))
        XCTAssertEqual(table.rows, [["x", "", ""]])
    }

    func testParseMalformedReturnsNil() {
        XCTAssertNil(TableEditing.parse("not a table"))
        XCTAssertNil(TableEditing.parse("| A | B |")) // no delimiter
        XCTAssertNil(TableEditing.parse("| A | B |\n| foo | bar |")) // second line not a delimiter
        XCTAssertNil(TableEditing.parse("")) // empty
        XCTAssertNil(TableEditing.parse("| A | B |\n| --- | x |")) // one bad delimiter cell
    }

    // MARK: - Render / normalize

    func testRenderRoundTripsAndPads() throws {
        let table = try XCTUnwrap(TableEditing.parse(simple))
        let rendered = TableEditing.render(table)
        XCTAssertEqual(rendered, """
        | Name  | Age |
        | ----- | --- |
        | Ada   | 36  |
        | Grace | 45  |
        """)
        // Re-parsing the render yields an equal model (idempotent).
        XCTAssertEqual(TableEditing.parse(rendered), table)
        XCTAssertNil(TableEditing.normalizeEdit(in: rendered)) // already normalized
    }

    func testNormalizeRepadsMessyTable() throws {
        let messy = "|Name|Age|\n|-|-|\n|Ada|36|"
        let result = try apply(TableEditing.normalizeEdit(in: messy), to: messy)
        XCTAssertEqual(result, """
        | Name | Age |
        | ---- | --- |
        | Ada  | 36  |
        """)
    }

    func testAlignedRenderKeepsColons() throws {
        let table = try XCTUnwrap(TableEditing.parse(aligned))
        let rendered = TableEditing.render(table)
        XCTAssertEqual(TableEditing.parse(rendered)?.alignments, [.left, .center, .right])
        XCTAssertTrue(rendered.contains(":-:")) // centered column, width 3
    }

    // MARK: - Insert row

    func testInsertRowBelowBody() throws {
        let result = try apply(TableEditing.insertRowEdit(in: simple, at: 1, above: false), to: simple)
        let table = try XCTUnwrap(TableEditing.parse(result))
        XCTAssertEqual(table.rows, [["Ada", "36"], ["", ""], ["Grace", "45"]])
    }

    func testInsertRowAboveBody() throws {
        let result = try apply(TableEditing.insertRowEdit(in: simple, at: 1, above: true), to: simple)
        let table = try XCTUnwrap(TableEditing.parse(result))
        XCTAssertEqual(table.rows, [["", ""], ["Ada", "36"], ["Grace", "45"]])
    }

    func testInsertRowBelowHeaderMakesFirstBodyRow() throws {
        let result = try apply(TableEditing.insertRowEdit(in: simple, at: 0, above: false), to: simple)
        let table = try XCTUnwrap(TableEditing.parse(result))
        XCTAssertEqual(table.rows.first, ["", ""])
        XCTAssertEqual(table.rows.count, 3)
    }

    func testInsertRowAboveHeaderRefused() {
        XCTAssertNil(TableEditing.insertRowEdit(in: simple, at: 0, above: true))
    }

    func testInsertRowPreservesAlignment() throws {
        let result = try apply(TableEditing.insertRowEdit(in: aligned, at: 1, above: false), to: aligned)
        XCTAssertEqual(TableEditing.parse(result)?.alignments, [.left, .center, .right])
    }

    // MARK: - Delete row

    func testDeleteRow() throws {
        let result = try apply(TableEditing.deleteRowEdit(in: simple, at: 1), to: simple)
        let table = try XCTUnwrap(TableEditing.parse(result))
        XCTAssertEqual(table.rows, [["Grace", "45"]])
    }

    func testDeleteHeaderRefused() {
        XCTAssertNil(TableEditing.deleteRowEdit(in: simple, at: 0))
    }

    func testDeleteOutOfRangeRowNil() {
        XCTAssertNil(TableEditing.deleteRowEdit(in: simple, at: 9))
    }

    func testDeleteOnlyBodyRowLeavesValidTable() throws {
        let oneRow = "| A | B |\n| --- | --- |\n| x | y |"
        let result = try apply(TableEditing.deleteRowEdit(in: oneRow, at: 1), to: oneRow)
        let table = try XCTUnwrap(TableEditing.parse(result))
        XCTAssertTrue(table.rows.isEmpty)
        XCTAssertEqual(table.header, ["A", "B"])
    }

    // MARK: - Insert column

    func testInsertColumnRight() throws {
        let result = try apply(TableEditing.insertColumnEdit(in: simple, at: 0, left: false), to: simple)
        let table = try XCTUnwrap(TableEditing.parse(result))
        XCTAssertEqual(table.header, ["Name", "", "Age"])
        XCTAssertEqual(table.rows, [["Ada", "", "36"], ["Grace", "", "45"]])
        XCTAssertEqual(table.alignments.count, 3)
    }

    func testInsertColumnLeft() throws {
        let result = try apply(TableEditing.insertColumnEdit(in: simple, at: 0, left: true), to: simple)
        let table = try XCTUnwrap(TableEditing.parse(result))
        XCTAssertEqual(table.header, ["", "Name", "Age"])
        XCTAssertEqual(table.rows.first, ["", "Ada", "36"])
    }

    func testInsertColumnKeepsExistingAlignments() throws {
        let result = try apply(TableEditing.insertColumnEdit(in: aligned, at: 2, left: false), to: aligned)
        let table = try XCTUnwrap(TableEditing.parse(result))
        XCTAssertEqual(table.alignments, [.left, .center, .right, .none])
    }

    // MARK: - Delete column

    func testDeleteColumn() throws {
        let result = try apply(TableEditing.deleteColumnEdit(in: aligned, at: 1), to: aligned)
        let table = try XCTUnwrap(TableEditing.parse(result))
        XCTAssertEqual(table.header, ["Item", "Price"])
        XCTAssertEqual(table.alignments, [.left, .right])
        XCTAssertEqual(table.rows, [["Apple", "1.20"], ["Pear", "0.80"]])
    }

    func testDeleteLastRemainingColumnRefused() {
        let single = "| Only |\n| --- |\n| a |"
        XCTAssertNil(TableEditing.deleteColumnEdit(in: single, at: 0))
    }

    func testDeleteColumnOutOfRangeNil() {
        XCTAssertNil(TableEditing.deleteColumnEdit(in: simple, at: 9))
    }

    // MARK: - Alignment

    func testSetAlignmentRoundTrips() throws {
        for alignment in [TableAlignment.left, .center, .right, .none] {
            let result = try apply(
                TableEditing.setAlignmentEdit(in: simple, at: 1, to: alignment), to: simple)
            XCTAssertEqual(TableEditing.parse(result)?.alignments[1], alignment,
                           "alignment \(alignment) did not round-trip")
            // Cell text survives an alignment change.
            XCTAssertEqual(TableEditing.parse(result)?.rows, [["Ada", "36"], ["Grace", "45"]])
        }
    }

    func testSetAlignmentToNoneStripsColons() throws {
        let result = try apply(
            TableEditing.setAlignmentEdit(in: aligned, at: 1, to: .none), to: aligned)
        XCTAssertEqual(TableEditing.parse(result)?.alignments, [.left, .none, .right])
    }

    func testSetAlignmentOutOfRangeNil() {
        XCTAssertNil(TableEditing.setAlignmentEdit(in: simple, at: 9, to: .center))
    }

    // MARK: - Move row / column

    func testMoveRowDown() throws {
        let result = try apply(TableEditing.moveRowEdit(in: simple, at: 1, up: false), to: simple)
        XCTAssertEqual(TableEditing.parse(result)?.rows, [["Grace", "45"], ["Ada", "36"]])
    }

    func testMoveRowUpIntoHeaderRefused() {
        // Grid row 1 is the first body row; it cannot cross into the header.
        XCTAssertNil(TableEditing.moveRowEdit(in: simple, at: 1, up: true))
    }

    func testMoveHeaderRefused() {
        XCTAssertNil(TableEditing.moveRowEdit(in: simple, at: 0, up: false))
    }

    func testMoveColumnRight() throws {
        let result = try apply(TableEditing.moveColumnEdit(in: simple, at: 0, left: false), to: simple)
        let table = try XCTUnwrap(TableEditing.parse(result))
        XCTAssertEqual(table.header, ["Age", "Name"])
        XCTAssertEqual(table.rows, [["36", "Ada"], ["45", "Grace"]])
    }

    func testMoveColumnCarriesAlignment() throws {
        let result = try apply(TableEditing.moveColumnEdit(in: aligned, at: 0, left: false), to: aligned)
        // left column (:---) and center column (:---:) swap.
        XCTAssertEqual(TableEditing.parse(result)?.alignments, [.center, .left, .right])
    }

    func testMoveColumnOutOfRangeNil() {
        XCTAssertNil(TableEditing.moveColumnEdit(in: simple, at: 1, left: false))
    }

    // MARK: - Single-column / single-row edges

    func testSingleColumnInsertRow() throws {
        let single = "| Only |\n| --- |\n| a |"
        let result = try apply(TableEditing.insertRowEdit(in: single, at: 1, above: false), to: single)
        XCTAssertEqual(TableEditing.parse(result)?.rows, [["a"], [""]])
    }

    func testSingleRowInsertColumn() throws {
        let single = "| A | B |\n| --- | --- |"
        let result = try apply(TableEditing.insertColumnEdit(in: single, at: 1, left: false), to: single)
        let table = try XCTUnwrap(TableEditing.parse(result))
        XCTAssertEqual(table.header, ["A", "B", ""])
        XCTAssertTrue(table.rows.isEmpty)
    }

    // MARK: - Content preservation edge cases

    func testEscapedPipeSurvives() throws {
        let escaped = "| A | B |\n| --- | --- |\n| a \\| b | c |"
        let table = try XCTUnwrap(TableEditing.parse(escaped))
        XCTAssertEqual(table.rows, [["a \\| b", "c"]])
        // A structural edit keeps the escaped pipe intact.
        let result = try apply(TableEditing.insertColumnEdit(in: escaped, at: 1, left: false), to: escaped)
        XCTAssertTrue(result.contains("a \\| b"))
    }

    func testWideContentSetsColumnWidth() throws {
        let wide = "| A | B |\n| --- | --- |\n| supercalifragilistic | y |"
        let result = try apply(TableEditing.normalizeEdit(in: wide), to: wide)
        XCTAssertTrue(result.contains("| supercalifragilistic |"))
        // Header padded to the same width.
        XCTAssertTrue(result.contains("| A                    |"))
    }

    // MARK: - CRLF handling

    func testCRLFPreserved() throws {
        let crlf = "| A | B |\r\n| --- | --- |\r\n| x | y |"
        let result = try apply(TableEditing.insertRowEdit(in: crlf, at: 1, above: false), to: crlf)
        XCTAssertTrue(result.contains("\r\n"))
        XCTAssertFalse(result.contains("\n\n")) // no bare LF slipped in
        XCTAssertEqual(TableEditing.parse(result)?.rows.count, 2)
    }

    func testTrailingNewlinePreserved() throws {
        let withNL = simple + "\n"
        let result = try apply(TableEditing.insertRowEdit(in: withNL, at: 1, above: false), to: withNL)
        XCTAssertTrue(result.hasSuffix("\n"))
        XCTAssertFalse(result.hasSuffix("\n\n"))
    }

    // MARK: - Grid coordinate mapping

    func testLocationMapsHeaderAndBody() throws {
        // Offsets within the simple table's slice.
        let header = try XCTUnwrap(TableEditing.location(forOffsetUTF16: 3, in: simple))
        XCTAssertEqual(header.row, 0)
        // "| Name | Age |\n| --- | --- |\n| Ada | 36 |\n..."
        // Byte 30-ish lands in the first body row.
        let firstBody = try XCTUnwrap(
            TableEditing.location(forOffsetUTF16: (simple as NSString).range(of: "Ada").location, in: simple))
        XCTAssertEqual(firstBody.row, 1)
        XCTAssertEqual(firstBody.column, 0)
        let secondCol = try XCTUnwrap(
            TableEditing.location(forOffsetUTF16: (simple as NSString).range(of: "36").location, in: simple))
        XCTAssertEqual(secondCol.column, 1)
    }

    func testLocationOnDelimiterMapsToHeaderRow() throws {
        let delimiterOffset = (simple as NSString).range(of: "---").location
        let loc = try XCTUnwrap(TableEditing.location(forOffsetUTF16: delimiterOffset, in: simple))
        XCTAssertEqual(loc.row, 0)
    }

    func testLocationNonTableNil() {
        XCTAssertNil(TableEditing.location(forOffsetUTF16: 0, in: "not a table"))
    }
}
