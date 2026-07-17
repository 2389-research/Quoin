import XCTest
@testable import QuoinCore

/// The pure document-resolution seam behind the App Intents document entity.
/// It operates on a `Library.scan` tree (no filesystem of its own), so the
/// name/path matching and root-relative identity rules are unit-testable and
/// Linux-safe. The `@available`-gated AppIntents structs are a thin shell over
/// this.
final class LibraryQueryTests: XCTestCase {

    private let rootPath = "/lib"

    /// A small fixed tree mirroring what `Library.scan` would produce.
    private func makeTree() -> LibraryNode {
        func doc(_ path: String) -> LibraryNode {
            let url = URL(fileURLWithPath: path)
            return LibraryNode(url: url, kind: .document, name: url.deletingPathExtension().lastPathComponent)
        }
        let notes = LibraryNode(
            url: URL(fileURLWithPath: "/lib/Notes"), kind: .folder, name: "Notes",
            children: [doc("/lib/Notes/Today.md"), doc("/lib/Notes/Meeting.md")])
        let journal = LibraryNode(
            url: URL(fileURLWithPath: "/lib/Journal"), kind: .folder, name: "Journal",
            children: [doc("/lib/Journal/2026-07-17.md")])
        let asset = LibraryNode(
            url: URL(fileURLWithPath: "/lib/logo.png"), kind: .asset, name: "logo.png")
        return LibraryNode(
            url: URL(fileURLWithPath: "/lib"), kind: .folder, name: "lib",
            children: [notes, journal, doc("/lib/README.md"), asset])
    }

    func testDocumentsFlattenWithRelativePaths() {
        let refs = LibraryQuery.documents(in: makeTree(), rootPath: rootPath)
        XCTAssertEqual(Set(refs.map(\.relativePath)), [
            "Notes/Today.md", "Notes/Meeting.md", "Journal/2026-07-17.md", "README.md",
        ])
        // Assets are excluded.
        XCTAssertFalse(refs.contains { $0.relativePath.hasSuffix(".png") })
    }

    func testRelativePathContainment() {
        XCTAssertEqual(LibraryQuery.relativePath(forPath: "/lib/Notes/Today.md", rootPath: "/lib"), "Notes/Today.md")
        // The root folder itself is not a document.
        XCTAssertNil(LibraryQuery.relativePath(forPath: "/lib", rootPath: "/lib"))
        // A sibling whose name merely starts with the root does not match.
        XCTAssertNil(LibraryQuery.relativePath(forPath: "/libOther/x.md", rootPath: "/lib"))
        // Outside the root entirely.
        XCTAssertNil(LibraryQuery.relativePath(forPath: "/etc/passwd", rootPath: "/lib"))
    }

    func testResolveByRelativePathIdentity() {
        let refs = LibraryQuery.documents(
            withRelativePaths: ["Notes/Today.md", "README.md", "does/not/exist.md"],
            in: makeTree(), rootPath: rootPath)
        XCTAssertEqual(Set(refs.map(\.relativePath)), ["Notes/Today.md", "README.md"])
    }

    func testRankExactFilenameWins() {
        let refs = LibraryQuery.rank(query: "Today", in: makeTree(), rootPath: rootPath)
        XCTAssertEqual(refs.first?.relativePath, "Notes/Today.md")
    }

    func testRankExactRelativePath() {
        let refs = LibraryQuery.rank(query: "Notes/Meeting.md", in: makeTree(), rootPath: rootPath)
        XCTAssertEqual(refs.first?.relativePath, "Notes/Meeting.md")
    }

    func testRankIsCaseAndExtensionInsensitiveForFilenames() {
        let lower = LibraryQuery.rank(query: "readme", in: makeTree(), rootPath: rootPath)
        XCTAssertEqual(lower.first?.relativePath, "README.md")
        let withExt = LibraryQuery.rank(query: "readme.md", in: makeTree(), rootPath: rootPath)
        XCTAssertEqual(withExt.first?.relativePath, "README.md")
    }

    func testRankEmptyQueryReturnsAllUpToLimit() {
        let refs = LibraryQuery.rank(query: "  ", in: makeTree(), rootPath: rootPath, limit: 2)
        XCTAssertEqual(refs.count, 2)
    }

    func testRankFuzzyFallback() {
        // "mtg" is a subsequence of "Meeting".
        let refs = LibraryQuery.rank(query: "mtg", in: makeTree(), rootPath: rootPath)
        XCTAssertEqual(refs.first?.relativePath, "Notes/Meeting.md")
    }
}
