import XCTest
@testable import QuoinCore

/// Exercises the pure Core Spotlight logic (#6): the stable identifier that
/// round-trips through the `quoin://` open path, title/heading/keyword
/// derivation, grapheme-safe snippet truncation, and the stale-set diff that
/// keeps moved/removed files from leaving orphaned index items.
final class SpotlightIndexingTests: XCTestCase {

    private func parse(_ source: String) -> QuoinDocument {
        MarkdownConverter.parse(source)
    }

    // MARK: - Stable identifier ⇄ deep link

    func testIdentifierIsLibraryRelativePath() {
        let id = SpotlightIndexing.identifier(
            forDocumentPath: "/Lib/Notes/Today.md", relativeTo: "/Lib")
        XCTAssertEqual(id, "Notes/Today.md")
    }

    func testIdentifierRoundTripsBackToAbsolutePath() {
        let root = "/Users/me/Library"
        let path = "/Users/me/Library/Deep/Sub/Note.md"
        guard let id = SpotlightIndexing.identifier(forDocumentPath: path, relativeTo: root) else {
            return XCTFail("expected an identifier")
        }
        XCTAssertEqual(id, "Deep/Sub/Note.md")
        XCTAssertEqual(
            SpotlightIndexing.documentPath(forIdentifier: id, relativeTo: root), path)
    }

    func testIdentifierRoundTripSurvivesSpacesAndUnicode() {
        let root = "/Lib"
        let path = "/Lib/My Notes/Café Ideas.md"
        guard let id = SpotlightIndexing.identifier(forDocumentPath: path, relativeTo: root) else {
            return XCTFail("expected an identifier")
        }
        XCTAssertEqual(id, "My Notes/Café Ideas.md")
        XCTAssertEqual(
            SpotlightIndexing.documentPath(forIdentifier: id, relativeTo: root), path)
    }

    func testIdentifierRefusesDocumentOutsideRoot() {
        XCTAssertNil(SpotlightIndexing.identifier(
            forDocumentPath: "/Elsewhere/a.md", relativeTo: "/Lib"))
    }

    func testIdentifierRefusesRootItself() {
        XCTAssertNil(SpotlightIndexing.identifier(
            forDocumentPath: "/Lib", relativeTo: "/Lib"))
    }

    func testDocumentPathRefusesTraversalIdentifier() {
        // A hostile identifier that climbs above the root is refused by the
        // same lexical confinement quoin:// links use.
        XCTAssertNil(SpotlightIndexing.documentPath(
            forIdentifier: "../secrets.md", relativeTo: "/Lib"))
    }

    // MARK: - Title extraction

    func testTitlePrefersFrontMatter() {
        let doc = parse("""
        ---
        title: My Real Title
        ---
        # A Different Heading

        Body text.
        """)
        XCTAssertEqual(SpotlightIndexing.title(for: doc, filenameStem: "file"), "My Real Title")
    }

    func testTitleFallsBackToFirstHeading() {
        let doc = parse("""
        # First Heading

        Body.

        ## Second
        """)
        XCTAssertEqual(SpotlightIndexing.title(for: doc, filenameStem: "file"), "First Heading")
    }

    func testTitleFallsBackToFilenameStem() {
        let doc = parse("Just a paragraph with no heading.")
        XCTAssertEqual(SpotlightIndexing.title(for: doc, filenameStem: "Untitled Note"), "Untitled Note")
    }

    func testTitleUsesFirstHeadingEvenIfNotH1() {
        let doc = parse("""
        ## Only a level two

        Body.
        """)
        XCTAssertEqual(SpotlightIndexing.title(for: doc, filenameStem: "file"), "Only a level two")
    }

    // MARK: - Heading list

    func testHeadingListInDocumentOrder() {
        let doc = parse("""
        # Alpha

        text

        ## Beta

        more

        ### Gamma
        """)
        XCTAssertEqual(SpotlightIndexing.headings(for: doc), ["Alpha", "Beta", "Gamma"])
    }

    func testHeadingListEmptyWhenNoHeadings() {
        let doc = parse("Just prose, no headings at all.")
        XCTAssertTrue(SpotlightIndexing.headings(for: doc).isEmpty)
    }

    // MARK: - Keywords from front matter

    func testKeywordsFromScalarFields() {
        let doc = parse("""
        ---
        title: Note
        status: draft
        ---
        Body.
        """)
        let keywords = SpotlightIndexing.keywords(for: doc)
        XCTAssertTrue(keywords.contains("Note"))
        XCTAssertTrue(keywords.contains("draft"))
    }

    func testKeywordsSplitInlineArray() {
        let doc = parse("""
        ---
        tags: [swift, macos, spotlight]
        ---
        Body.
        """)
        let keywords = SpotlightIndexing.keywords(for: doc)
        XCTAssertTrue(keywords.contains("swift"))
        XCTAssertTrue(keywords.contains("macos"))
        XCTAssertTrue(keywords.contains("spotlight"))
    }

    func testKeywordsDedupeCaseInsensitively() {
        let doc = parse("""
        ---
        a: Draft
        b: draft
        ---
        Body.
        """)
        let keywords = SpotlightIndexing.keywords(for: doc)
        XCTAssertEqual(keywords.filter { $0.lowercased() == "draft" }.count, 1)
    }

    // MARK: - Snippet / body text

    func testSnippetIsProseWithoutFrontMatter() {
        let doc = parse("""
        ---
        title: Secret Meta
        ---
        # Heading

        The quick brown fox.
        """)
        let snippet = SpotlightIndexing.snippet(for: doc, limit: 300)
        XCTAssertTrue(snippet.contains("The quick brown fox."))
        XCTAssertFalse(snippet.contains("Secret Meta"))
        XCTAssertFalse(snippet.contains("---"))
    }

    func testSnippetCollapsesWhitespace() {
        let doc = parse("""
        Line one.

        Line two.
        """)
        XCTAssertEqual(SpotlightIndexing.snippet(for: doc, limit: 300), "Line one. Line two.")
    }

    func testTruncateAddsEllipsisWhenCut() {
        let text = String(repeating: "a", count: 50)
        let result = SpotlightIndexing.truncate(text, limit: 10)
        XCTAssertEqual(result, String(repeating: "a", count: 10) + "…")
    }

    func testTruncateLeavesShortTextUnchanged() {
        XCTAssertEqual(SpotlightIndexing.truncate("short", limit: 10), "short")
    }

    func testTruncateZeroLimitIsEmpty() {
        XCTAssertEqual(SpotlightIndexing.truncate("anything", limit: 0), "")
    }

    func testTruncateNeverSplitsAGrapheme() {
        // A ZWJ family emoji is ONE grapheme cluster made of many scalars.
        // Truncating to 3 must yield exactly 3 whole clusters + ellipsis —
        // never a torn cluster / replacement character.
        let family = "👨‍👩‍👧‍👦"
        let text = String(repeating: family, count: 10)
        let result = SpotlightIndexing.truncate(text, limit: 3)
        XCTAssertEqual(result, String(repeating: family, count: 3) + "…")
        // The prefix (sans ellipsis) is exactly 3 graphemes and, re-expanded,
        // is byte-identical to three families — proof nothing was split.
        XCTAssertEqual(result.dropLast().count, 3)
        XCTAssertEqual(String(result.dropLast()), String(repeating: family, count: 3))
    }

    // MARK: - Full snapshot

    func testIndexedDocumentSnapshot() {
        let doc = parse("""
        ---
        title: Snapshot
        tags: [alpha, beta]
        ---
        # Snapshot

        Some body prose here.
        """)
        let derived = SpotlightIndexing.indexedDocument(
            for: doc, identifier: "Folder/Snapshot.md", filenameStem: "Snapshot", snippetLimit: 300)
        XCTAssertEqual(derived.identifier, "Folder/Snapshot.md")
        XCTAssertEqual(derived.relativePath, "Folder/Snapshot.md")
        XCTAssertEqual(derived.title, "Snapshot")
        XCTAssertEqual(derived.headings, ["Snapshot"])
        XCTAssertTrue(derived.keywords.contains("alpha"))
        XCTAssertTrue(derived.keywords.contains("beta"))
        XCTAssertTrue(derived.snippet.contains("Some body prose here."))
        XCTAssertTrue(derived.textContent.contains("Some body prose here."))
    }

    // MARK: - Stale-set diff

    func testStaleIdentifiersAreThoseNoLongerPresent() {
        let stale = SpotlightIndexing.staleIdentifiers(
            previouslyIndexed: ["a.md", "b.md", "c.md"],
            current: ["b.md", "c.md", "d.md"])
        XCTAssertEqual(stale, ["a.md"])
    }

    func testStaleIdentifiersEmptyWhenNothingRemoved() {
        let stale = SpotlightIndexing.staleIdentifiers(
            previouslyIndexed: ["a.md", "b.md"],
            current: ["a.md", "b.md", "c.md"])
        XCTAssertTrue(stale.isEmpty)
    }

    func testStaleIdentifiersDetectAMove() {
        // A move looks like: old relative path gone, new one present.
        let stale = SpotlightIndexing.staleIdentifiers(
            previouslyIndexed: ["Old/Note.md"],
            current: ["New/Note.md"])
        XCTAssertEqual(stale, ["Old/Note.md"])
    }
}
