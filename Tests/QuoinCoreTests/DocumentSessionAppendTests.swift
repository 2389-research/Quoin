import XCTest
@testable import QuoinCore

/// `DocumentSession.appendText` — the in-actor append the App Intents "Append
/// Text to Note" action drives. It must reduce to a real, undoable, byte-
/// lossless edit through the same pipeline as a keystroke (not a raw rewrite).
final class DocumentSessionAppendTests: XCTestCase {

    func testAppendMutatesSourceAndIsByteLosslessForThePrefix() async throws {
        let session = DocumentSession(source: "# Title\n\nbody")
        let doc = try await session.appendText("new line")
        XCTAssertEqual(doc?.source, "# Title\n\nbody\nnew line\n")
        // The prefix is untouched (a pure tail insertion).
        XCTAssertTrue(doc?.source.hasPrefix("# Title\n\nbody") == true)
    }

    func testAppendToEmptyDocument() async throws {
        let session = DocumentSession(source: "")
        let doc = try await session.appendText("first")
        XCTAssertEqual(doc?.source, "first\n")
    }

    func testEmptyAppendIsANoOpReturningNil() async throws {
        let session = DocumentSession(source: "abc\n")
        let doc = try await session.appendText("   \n\n")
        XCTAssertNil(doc)
        // Source is unchanged.
        let current = await session.document.source
        XCTAssertEqual(current, "abc\n")
    }

    func testAppendIsUndoable() async throws {
        let session = DocumentSession(source: "abc\n")
        _ = try await session.appendText("more")
        let afterAppend = await session.document.source
        XCTAssertEqual(afterAppend, "abc\nmore\n")
        let undone = try await session.undo()
        XCTAssertEqual(undone?.source, "abc\n")
        let name = await session.redoActionName
        XCTAssertEqual(name, .append)
    }
}
