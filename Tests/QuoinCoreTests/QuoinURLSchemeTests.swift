import XCTest
@testable import QuoinCore

/// Exercises the `quoin://` deep-link parser and — the security-critical part —
/// the lexical path resolver that keeps a deep link from escaping the library
/// root (path traversal, absolute paths elsewhere, symlink-name tricks).
final class QuoinURLSchemeTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("bad test URL: \(string)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    // MARK: - Parsing

    func testParsesRelativeOpen() {
        let link = QuoinURLScheme.parse(url("quoin://open?path=Notes/Today.md"))
        XCTAssertEqual(link, .init(action: .open, rawPath: "Notes/Today.md"))
    }

    func testParsesPercentEncodedPath() {
        // Spaces and slashes arrive encoded from a shared link.
        let link = QuoinURLScheme.parse(url("quoin://open?path=My%20Notes%2FDay%20One.md"))
        XCTAssertEqual(link, .init(action: .open, rawPath: "My Notes/Day One.md"))
    }

    func testParsesEncodedAbsolutePath() {
        let link = QuoinURLScheme.parse(url("quoin://open?path=%2FUsers%2Fme%2FLib%2Fa.md"))
        XCTAssertEqual(link?.rawPath, "/Users/me/Lib/a.md")
    }

    func testActionIsCaseInsensitive() {
        XCTAssertEqual(QuoinURLScheme.parse(url("QUOIN://OPEN?path=a.md"))?.action, .open)
    }

    func testRejectsWrongScheme() {
        XCTAssertNil(QuoinURLScheme.parse(url("https://open?path=a.md")))
        XCTAssertNil(QuoinURLScheme.parse(url("file:///Users/me/a.md")))
    }

    func testRejectsUnknownAction() {
        XCTAssertNil(QuoinURLScheme.parse(url("quoin://delete?path=a.md")))
        XCTAssertNil(QuoinURLScheme.parse(url("quoin://?path=a.md")))
    }

    func testRejectsMissingOrEmptyPath() {
        XCTAssertNil(QuoinURLScheme.parse(url("quoin://open")))
        XCTAssertNil(QuoinURLScheme.parse(url("quoin://open?path=")))
        XCTAssertNil(QuoinURLScheme.parse(url("quoin://open?other=x")))
    }

    func testRejectsNulByte() {
        // %00 decodes to a NUL byte — a classic C-string truncation vector.
        XCTAssertNil(QuoinURLScheme.parse(url("quoin://open?path=a%00.md")))
    }

    func testIsDeepLink() {
        XCTAssertTrue(QuoinURLScheme.isDeepLink(url("quoin://open?path=a.md")))
        XCTAssertFalse(QuoinURLScheme.isDeepLink(url("file:///a.md")))
    }

    // MARK: - Resolution: the happy path

    func testResolvesRelativePathIntoRoot() {
        let resolved = QuoinURLScheme.resolvedPath(forRawPath: "Notes/Today.md", relativeTo: "/Lib")
        XCTAssertEqual(resolved, "/Lib/Notes/Today.md")
    }

    func testResolvesAbsolutePathInsideRoot() {
        let resolved = QuoinURLScheme.resolvedPath(forRawPath: "/Lib/Notes/a.md", relativeTo: "/Lib")
        XCTAssertEqual(resolved, "/Lib/Notes/a.md")
    }

    func testResolvesHarmlessDotSegments() {
        let resolved = QuoinURLScheme.resolvedPath(forRawPath: "./Notes/./a.md", relativeTo: "/Lib")
        XCTAssertEqual(resolved, "/Lib/Notes/a.md")
    }

    func testResolvesInteriorParentThatStaysInside() {
        // Notes/../Other stays under the root — allowed.
        let resolved = QuoinURLScheme.resolvedPath(forRawPath: "Notes/../Other/a.md", relativeTo: "/Lib")
        XCTAssertEqual(resolved, "/Lib/Other/a.md")
    }

    func testCollapsesDuplicateSlashes() {
        let resolved = QuoinURLScheme.resolvedPath(forRawPath: "Notes//a.md", relativeTo: "/Lib//")
        XCTAssertEqual(resolved, "/Lib/Notes/a.md")
    }

    // MARK: - Resolution: traversal defenses

    func testRejectsRelativeTraversalOutOfRoot() {
        XCTAssertNil(QuoinURLScheme.resolvedPath(forRawPath: "../secrets.md", relativeTo: "/Lib"))
        XCTAssertNil(QuoinURLScheme.resolvedPath(forRawPath: "../../etc/passwd", relativeTo: "/Lib"))
        XCTAssertNil(QuoinURLScheme.resolvedPath(forRawPath: "Notes/../../escape.md", relativeTo: "/Lib"))
    }

    func testRejectsAbsolutePathOutsideRoot() {
        XCTAssertNil(QuoinURLScheme.resolvedPath(forRawPath: "/etc/passwd", relativeTo: "/Lib"))
        XCTAssertNil(QuoinURLScheme.resolvedPath(forRawPath: "/Users/me/other/a.md", relativeTo: "/Lib"))
    }

    func testRejectsSiblingWithRootAsNamePrefix() {
        // "/Library" must not admit "/LibraryOther/a.md" — the trailing-slash
        // boundary check is what stops the prefix collision.
        XCTAssertNil(QuoinURLScheme.resolvedPath(forRawPath: "/LibraryOther/a.md", relativeTo: "/Library"))
    }

    func testRejectsRootItself() {
        XCTAssertNil(QuoinURLScheme.resolvedPath(forRawPath: ".", relativeTo: "/Lib"))
        XCTAssertNil(QuoinURLScheme.resolvedPath(forRawPath: "/Lib", relativeTo: "/Lib"))
        XCTAssertNil(QuoinURLScheme.resolvedPath(forRawPath: "Notes/..", relativeTo: "/Lib"))
    }

    func testRejectsEmptyOrDegenerateRoot() {
        XCTAssertNil(QuoinURLScheme.resolvedPath(forRawPath: "a.md", relativeTo: ""))
        XCTAssertNil(QuoinURLScheme.resolvedPath(forRawPath: "a.md", relativeTo: "/"))
        XCTAssertNil(QuoinURLScheme.resolvedPath(forRawPath: "a.md", relativeTo: "relative/root"))
    }

    func testRejectsEmptyPath() {
        XCTAssertNil(QuoinURLScheme.resolvedPath(forRawPath: "", relativeTo: "/Lib"))
    }

    // MARK: - Activity payload (#36): building a quoin:// link from a document

    func testBuildsRelativeDeepLinkForDocumentInRoot() {
        let link = QuoinURLScheme.deepLink(forDocumentPath: "/Lib/Notes/Today.md", relativeTo: "/Lib")
        XCTAssertEqual(link?.absoluteString, "quoin://open?path=Notes/Today.md")
    }

    func testBuiltDeepLinkPercentEncodesSpaces() {
        let link = QuoinURLScheme.deepLink(forDocumentPath: "/Lib/My Notes/Day One.md", relativeTo: "/Lib")
        // The query value is percent-encoded so the URL is well-formed…
        XCTAssertEqual(link?.absoluteString, "quoin://open?path=My%20Notes/Day%20One.md")
        // …and parse() decodes it straight back to the relative path.
        XCTAssertEqual(QuoinURLScheme.parse(link!)?.rawPath, "My Notes/Day One.md")
    }

    func testBuiltDeepLinkRoundTripsThroughResolvedPath() {
        // The inverse property: build → resolve returns the original document.
        let doc = "/Lib/A/B/C.md"
        let link = QuoinURLScheme.deepLink(forDocumentPath: doc, relativeTo: "/Lib/")
        let parsed = QuoinURLScheme.parse(link!)!
        let resolved = QuoinURLScheme.resolvedPath(forRawPath: parsed.rawPath, relativeTo: "/Lib")
        XCTAssertEqual(resolved, doc)
    }

    func testNoDeepLinkForDocumentOutsideRoot() {
        // The acceptance case: a document outside the granted library yields NO
        // link, so #36 publishes no activity for it.
        XCTAssertNil(QuoinURLScheme.deepLink(forDocumentPath: "/Other/a.md", relativeTo: "/Lib"))
        XCTAssertNil(QuoinURLScheme.deepLink(forDocumentPath: "/Lib/../escape.md", relativeTo: "/Lib"))
    }

    func testNoDeepLinkForSiblingWithRootAsNamePrefix() {
        // "/Library" must not admit "/LibraryOther/a.md" (prefix-collision guard).
        XCTAssertNil(QuoinURLScheme.deepLink(forDocumentPath: "/LibraryOther/a.md", relativeTo: "/Library"))
    }

    func testNoDeepLinkForRootItself() {
        XCTAssertNil(QuoinURLScheme.deepLink(forDocumentPath: "/Lib", relativeTo: "/Lib"))
        XCTAssertNil(QuoinURLScheme.deepLink(forDocumentPath: "/Lib/", relativeTo: "/Lib"))
    }

    func testNoDeepLinkForDegenerateRoot() {
        XCTAssertNil(QuoinURLScheme.deepLink(forDocumentPath: "/Lib/a.md", relativeTo: ""))
        XCTAssertNil(QuoinURLScheme.deepLink(forDocumentPath: "/a.md", relativeTo: "/"))
        XCTAssertNil(QuoinURLScheme.deepLink(forDocumentPath: "/Lib/a.md", relativeTo: "relative/root"))
    }

    func testNoDeepLinkForNulByteInDocumentPath() {
        XCTAssertNil(QuoinURLScheme.deepLink(forDocumentPath: "/Lib/a\0.md", relativeTo: "/Lib"))
    }

    // MARK: - normalize()

    func testNormalizeCollapsesLexically() {
        XCTAssertEqual(QuoinURLScheme.normalize("/a/b/../c"), "/a/c")
        XCTAssertEqual(QuoinURLScheme.normalize("/a/./b/"), "/a/b")
        XCTAssertEqual(QuoinURLScheme.normalize("/a//b"), "/a/b")
        XCTAssertEqual(QuoinURLScheme.normalize("/.."), "/")
        XCTAssertEqual(QuoinURLScheme.normalize("a/../../b"), "../b")
    }
}
