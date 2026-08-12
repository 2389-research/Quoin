import XCTest
@testable import QuoinCore

/// C3 (defence in depth). `applyEdit` used to apply ANY well-formed edit, including
/// one whose replacement is BYTE-IDENTICAL to the bytes it replaces. The editable-
/// island flush produces exactly that on a click-in/click-away with no typing: the
/// island is seeded from the block's own bytes and its `byteRange` IS the block's
/// range, so the flush replays the block verbatim. The costs are all real and all
/// user-visible — a dead undo step (⌘Z that does nothing), a scheduled autosave
/// that REWRITES the user's `.md` file and moves its mtime (which then surfaces as
/// an external change), and a published document that refreshes the projection.
///
/// The controller-side short-circuit is the primary fix; this is the backstop, and
/// it is universal because a no-op edit is meaningless from every caller.
final class DocumentSessionNoOpEditTests: XCTestCase {

    func testByteIdenticalEditRecordsNoUndoStepAndLeavesTheSourceAlone() async throws {
        let source = "# Title\n\nA paragraph.\n\nAnother one."
        let session = DocumentSession(source: source)
        // The middle block's exact bytes, replayed onto themselves — what an island
        // flush with zero typing emits.
        let blockRange = await session.document.blocks[1].range
        let bytes = try XCTUnwrap(source.substring(in: blockRange))
        XCTAssertEqual(bytes, "A paragraph.", "precondition: the range really is that block")

        let before = await session.canUndo
        XCTAssertFalse(before, "precondition: a fresh session has an empty undo stack")

        let result = try await session.applyEdit(
            SourceEdit(range: blockRange, replacement: bytes))

        XCTAssertEqual(result.source, source, "the source is returned unchanged")
        let after = await session.document.source
        XCTAssertEqual(after, source)
        let canUndo = await session.canUndo
        XCTAssertFalse(canUndo,
                       "a byte-identical edit must not push an undo step — ⌘Z would "
                       + "otherwise appear enabled and then visibly do nothing")

        // ANTI-VACUITY: the same call shape with a REAL change does everything.
        _ = try await session.applyEdit(
            SourceEdit(range: blockRange, replacement: "A changed paragraph."))
        let changed = await session.document.source
        XCTAssertEqual(changed, "# Title\n\nA changed paragraph.\n\nAnother one.")
        let canUndoNow = await session.canUndo
        XCTAssertTrue(canUndoNow, "control: a real edit IS undoable")
    }

    /// The guard must not swallow a malformed edit: an out-of-range span still has
    /// to reach `parseAfterEdit` and throw, exactly as before.
    func testOutOfRangeEditStillThrows() async throws {
        let session = DocumentSession(source: "abc")
        do {
            _ = try await session.applyEdit(
                SourceEdit(range: ByteRange(offset: 10, length: 5), replacement: ""))
            XCTFail("an out-of-range edit must still throw")
        } catch {
            // expected
        }
    }

    /// An empty replacement over an empty range is also a no-op and must be treated
    /// as one (it is the degenerate shape a zero-length island splice can produce).
    func testEmptyEditIsANoOp() async throws {
        let session = DocumentSession(source: "abc\n")
        _ = try await session.applyEdit(
            SourceEdit(range: ByteRange(offset: 2, length: 0), replacement: ""))
        let canUndo = await session.canUndo
        XCTAssertFalse(canUndo, "an empty splice records no undo step")
        let source = await session.document.source
        XCTAssertEqual(source, "abc\n")
    }
}
