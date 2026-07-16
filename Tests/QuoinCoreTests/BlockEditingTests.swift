import XCTest
@testable import QuoinCore

/// Block-granularity edits (ideas #9/#10/#11): byte-exact splice builders.
final class BlockEditingTests: XCTestCase {

    private let source = "# Title\n\nFirst paragraph.\n\n```swift\nlet a = 1\n```\n\nLast paragraph.\n"

    private func apply(_ edit: SourceEdit, to source: String) throws -> String {
        try edit.apply(to: source).result
    }

    func testMoveUpSwapsSlicesAroundTheSeparator() throws {
        let document = MarkdownConverter.parse(source)
        let codeIndex = try XCTUnwrap(document.blocks.firstIndex {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        let edit = try XCTUnwrap(BlockEditing.moveEdit(
            source: source, blocks: document.blocks, blockIndex: codeIndex, direction: .up))
        let moved = try apply(edit, to: source)
        XCTAssertEqual(moved, "# Title\n\n```swift\nlet a = 1\n```\n\nFirst paragraph.\n\nLast paragraph.\n",
                       "slices swap; separator bytes stay put")
        // Round-trip: moving back restores the exact original bytes.
        let movedDocument = MarkdownConverter.parse(moved)
        let movedIndex = try XCTUnwrap(movedDocument.blocks.firstIndex {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        let back = try XCTUnwrap(BlockEditing.moveEdit(
            source: moved, blocks: movedDocument.blocks, blockIndex: movedIndex, direction: .down))
        XCTAssertEqual(try apply(back, to: moved), source, "byte-lossless round trip")
    }

    func testMoveAtEdgesReturnsNil() {
        let document = MarkdownConverter.parse(source)
        XCTAssertNil(BlockEditing.moveEdit(
            source: source, blocks: document.blocks, blockIndex: 0, direction: .up))
        XCTAssertNil(BlockEditing.moveEdit(
            source: source, blocks: document.blocks,
            blockIndex: document.blocks.count - 1, direction: .down))
    }

    func testDuplicateInsertsBelow() throws {
        let document = MarkdownConverter.parse(source)
        let edit = try XCTUnwrap(BlockEditing.duplicateEdit(
            source: source, blocks: document.blocks, blockIndex: 1))
        let duplicated = try apply(edit, to: source)
        XCTAssertTrue(duplicated.contains("First paragraph.\n\nFirst paragraph.\n\n```swift"))
    }

    func testDeleteConsumesTheSeparator() throws {
        let document = MarkdownConverter.parse(source)
        let edit = try XCTUnwrap(BlockEditing.deleteEdit(
            source: source, blocks: document.blocks, blockIndex: 1))
        let deleted = try apply(edit, to: source)
        XCTAssertEqual(deleted, "# Title\n\n```swift\nlet a = 1\n```\n\nLast paragraph.\n",
                       "no orphan blank lines")
    }

    func testDeleteLastBlockConsumesPrecedingSeparator() throws {
        let document = MarkdownConverter.parse(source)
        let edit = try XCTUnwrap(BlockEditing.deleteEdit(
            source: source, blocks: document.blocks, blockIndex: document.blocks.count - 1))
        let deleted = try apply(edit, to: source)
        XCTAssertTrue(deleted.hasSuffix("```\n"), "got: \(deleted)")
    }

    func testDeleteSoleBlockPreservesTrailingUnrenderedBytes() throws {
        // Ledger (data integrity #15): the sole-block case used to take
        // everything to EOF, wiping trailing bytes that belong to no
        // rendered block. Only the block and its own line terminator go.
        let cases: [(source: String, expected: String)] = [
            ("Hello", ""),                       // bare block, nothing trailing
            ("Hello\n", ""),                     // its own terminator goes with it
            ("Hello\r\n", ""),                   // CRLF terminator too
            ("Hello\n\n\n", "\n\n"),             // trailing blank lines survive
            ("Hello\n   \n", "   \n"),           // trailing whitespace survives
        ]
        for (source, expected) in cases {
            let document = MarkdownConverter.parse(source)
            XCTAssertEqual(document.blocks.count, 1, "fixture must be a sole block: \(source.debugDescription)")
            let edit = try XCTUnwrap(BlockEditing.deleteEdit(
                source: source, blocks: document.blocks, blockIndex: 0))
            XCTAssertEqual(try apply(edit, to: source), expected,
                           "deleting the sole block of \(source.debugDescription)")
        }
    }

    func testDeleteSoleBlockKeepsLinkReferenceDefinitions() throws {
        // A link reference definition renders no block of its own; deleting
        // the only visible block must not silently destroy it.
        let source = "See the docs.\n\n[docs]: https://example.com\n"
        let document = MarkdownConverter.parse(source)
        guard document.blocks.count == 1 else {
            // If the parser ever starts modeling reference definitions as
            // blocks this fixture stops being a sole-block case; the blank
            // line fixtures above still cover the invariant.
            return
        }
        let block = document.blocks[0]
        // The definition must live OUTSIDE the sole block's range for this
        // fixture to prove anything.
        XCTAssertLessThan(block.range.upperBound, source.utf8.count)
        let edit = try XCTUnwrap(BlockEditing.deleteEdit(
            source: source, blocks: document.blocks, blockIndex: 0))
        let remaining = try apply(edit, to: source)
        XCTAssertTrue(remaining.contains("[docs]: https://example.com"),
                      "trailing reference definition must survive; got \(remaining.debugDescription)")
    }

    // MARK: Tables

    func testAddRowMatchesColumnCount() throws {
        let table = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let grown = try XCTUnwrap(TableEditing.addingRow(to: table))
        XCTAssertEqual(grown, "| A | B |\n| --- | --- |\n| 1 | 2 |\n|    |    |")
    }

    func testAddColumnExtendsEveryRow() throws {
        let table = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let grown = try XCTUnwrap(TableEditing.addingColumn(to: table))
        let lines = grown.split(separator: "\n")
        XCTAssertTrue(lines[0].hasSuffix("|   |"))
        XCTAssertTrue(lines[1].hasSuffix("| --- |"))
        XCTAssertTrue(lines[2].hasSuffix("|   |"))
        // Still parses as a table with 3 columns.
        let reparsed = MarkdownConverter.parse(grown + "\n")
        let hasTable = reparsed.blocks.contains {
            if case .table(let header, _, _) = $0.kind { return header.count == 3 }
            return false
        }
        XCTAssertTrue(hasTable, "grown table must reparse with the new column: \(grown)")
    }

    func testNonTableReturnsNil() {
        XCTAssertNil(TableEditing.addingRow(to: "not a table"))
        XCTAssertNil(TableEditing.addingColumn(to: "plain\ntext"))
    }
}
