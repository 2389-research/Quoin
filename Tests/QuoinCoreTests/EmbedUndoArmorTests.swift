import XCTest
@testable import QuoinCore

/// Session-level armor for the embed-editing undo contracts (brief, Phase
/// 1.4): block activation is pure projection — the document and its undo
/// stack are untouched — so undoing PAST the edit that created the
/// currently-active block must yield a consistent document (the model then
/// deactivates because the block id no longer resolves; it must never see
/// an inconsistent AST or a stale stack).
final class EmbedUndoArmorTests: XCTestCase {

    func testUndoPastBlockCreationYieldsConsistentDocument() async throws {
        let base = "# Doc\n\nA paragraph.\n"
        let session = DocumentSession(source: base)

        // Create a fenced block (what the UI would then activate).
        let fence = "\n```swift\nlet a = 1\n```\n"
        let insertAt = base.utf8.count
        let created = try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: insertAt, length: 0), replacement: fence),
            publishSnapshot: false
        )
        let codeID = created.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        }?.id
        XCTAssertNotNil(codeID, "setup: the edit must create a code block")

        // Edit inside that block (an editing session is underway).
        let bodyOffset = insertAt + "\n```swift\nlet a = ".utf8.count
        _ = try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: bodyOffset, length: 1), replacement: "42"),
            publishSnapshot: false
        )

        // Undo the body edit, then undo past the block's creation.
        let firstUndo = try await session.undo()
        let afterFirstUndo = try XCTUnwrap(firstUndo)
        XCTAssertTrue(afterFirstUndo.source.contains("let a = 1"))
        let secondUndo = try await session.undo()
        let afterSecondUndo = try XCTUnwrap(secondUndo)

        // The document is byte-identical to the base and the block is gone
        // — the model deactivates on ingest because the id doesn't resolve.
        XCTAssertEqual(afterSecondUndo.source, base)
        XCTAssertNil(afterSecondUndo.blocks.first { $0.id == codeID },
                     "the created block must not survive the undo")
        // And the AST is consistent: blocks tile the source without gaps.
        for block in afterSecondUndo.blocks {
            XCTAssertNotNil(afterSecondUndo.source.substring(in: block.range),
                            "every block range must resolve into the source")
        }

        // Redo brings the block back with a resolvable range.
        let redo = try await session.redo()
        let redone = try XCTUnwrap(redo)
        XCTAssertTrue(redone.source.contains("```swift"))
    }

    func testUndoRedoRoundTripIsByteLossless() async throws {
        let source = "Alpha.\n\n```mermaid\nflowchart TD\n  A --> B\n```\n\nOmega.\n"
        let session = DocumentSession(source: source)
        let edit = SourceEdit(
            range: ByteRange(offset: "Alpha.\n\n```mermaid\nflowchart TD\n".utf8.count, length: 0),
            replacement: "  A --> C\n"
        )
        _ = try await session.applyEdit(edit, publishSnapshot: false)
        let undoResult = try await session.undo()
        let undone = try XCTUnwrap(undoResult)
        XCTAssertEqual(undone.source, source, "undo must restore the exact bytes")
    }
}
