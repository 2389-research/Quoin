import XCTest
@testable import QuoinCore

/// Regression coverage for the structural-table caller guard (#14).
///
/// `TableEditing.parse` is deliberately lenient — it accepts single-column
/// borderless slices and column-count-mismatched slices that GFM /
/// swift-markdown reject as tables. That leniency is fine for the pure engine,
/// but it is NOT a safe gate for *which blocks a table command may rewrite*:
/// a setext heading (`Title` / `-----`) and a malformed pipe paragraph both
/// parse as a "table" slice, yet neither is a table in the AST. Gating either
/// the context-menu Table submenu or `ReaderModel.perform`'s table cases on
/// `TableEditing.parse` (two recognizers for one grammar) let a table command
/// silently rewrite those blocks into pipe tables — corruption that violated
/// byte-losslessness (CLAUDE.md: "two recognizers for one grammar WILL
/// diverge").
///
/// The fix makes the AST's `BlockKind.table` the single recognizer of record:
/// the menu gate asks `isTableBlockProvider` (AST kind) and `perform` guards
/// `case .table = block.kind`. These tests pin that discriminator: they prove
/// the two recognizers diverge on real inputs, that a table op WOULD corrupt
/// the block (so the guard is load-bearing), and that the kind predicate the
/// callers now use correctly rejects the non-table blocks and accepts a table.
final class TableCommandKindGuardTests: XCTestCase {

    /// The exact predicate both callers now use to decide whether a block may
    /// receive a table command (mirrors `perform`'s `case .table` guard and
    /// `isTableBlockProvider`).
    private func isTableBlock(_ block: Block) -> Bool {
        if case .table = block.kind { return true }
        return false
    }

    /// The single, first content block of a parsed document (skips any leading
    /// front matter — none of these fixtures have any, but be explicit).
    private func firstBlock(of source: String) throws -> Block {
        let document = MarkdownConverter.parse(source)
        return try XCTUnwrap(document.blocks.first, "expected at least one block")
    }

    /// A setext-underlined H2. The block is a heading; its source slice is
    /// `TableEditing.parse`-accepted (header=[Title], delimiter row `-----`).
    func testSetextHeadingIsNotATableTarget() throws {
        let source = "Title\n-----\n"
        let block = try firstBlock(of: source)

        // AST: a heading, never a table.
        guard case .heading = block.kind else {
            return XCTFail("expected a setext heading block, got \(block.kind)")
        }
        XCTAssertFalse(isTableBlock(block), "kind guard must reject the heading")

        // Recognizer divergence: the lenient engine parser DOES accept the
        // heading's slice as a table — which is exactly why gating on it (not
        // the AST kind) was unsafe.
        let slice = try XCTUnwrap(source.substring(in: block.range))
        XCTAssertNotNil(
            TableEditing.parse(slice),
            "documents the leniency the guard defends against")
    }

    /// A malformed pipe paragraph (column-count mismatch): GFM rejects it as a
    /// table, so the AST yields a paragraph, but `TableEditing.parse` accepts
    /// it. The kind guard must reject it.
    func testMalformedPipeParagraphIsNotATableTarget() throws {
        let source = "a | b\n--- | --- | ---\n"
        let block = try firstBlock(of: source)

        guard case .paragraph = block.kind else {
            return XCTFail("expected a paragraph block, got \(block.kind)")
        }
        XCTAssertFalse(isTableBlock(block), "kind guard must reject the paragraph")

        let slice = try XCTUnwrap(source.substring(in: block.range))
        XCTAssertNotNil(
            TableEditing.parse(slice),
            "documents the leniency the guard defends against")
    }

    /// A real GFM table IS a table target — the guard must not over-reject.
    func testRealTableIsATableTarget() throws {
        let source = "| Name | Age |\n| --- | --- |\n| Ada | 36 |\n"
        let block = try firstBlock(of: source)

        guard case .table = block.kind else {
            return XCTFail("expected a table block, got \(block.kind)")
        }
        XCTAssertTrue(isTableBlock(block), "kind guard must accept a real table")
    }

    /// The guard is load-bearing: without it, running a table command through
    /// the caller's slice → rebase → apply path (the same path `perform` uses)
    /// REWRITES the setext heading into a pipe table — proving the guard
    /// prevents genuine corruption, not a harmless no-op. We assert both that
    /// the destructive edit exists (leniency) and that the kind guard blocks it.
    func testTableCommandWouldCorruptSetextHeadingWithoutKindGuard() throws {
        let source = "Title\n-----\n"
        let block = try firstBlock(of: source)
        let slice = try XCTUnwrap(source.substring(in: block.range))

        // Engine happily produces a whole-slice normalize edit for the heading.
        let edit = try XCTUnwrap(
            TableEditing.normalizeEdit(in: slice),
            "lenient engine emits a destructive edit for a non-table slice")
        let rewritten = try edit.apply(to: slice).result
        XCTAssertNotEqual(
            rewritten, slice,
            "the edit is destructive — it turns the heading into a pipe table")
        XCTAssertTrue(
            rewritten.contains("| Title |"),
            "confirms the corruption shape the guard prevents")

        // The kind guard is what stops that edit from ever being built/applied
        // by the callers.
        XCTAssertFalse(isTableBlock(block))
    }
}
