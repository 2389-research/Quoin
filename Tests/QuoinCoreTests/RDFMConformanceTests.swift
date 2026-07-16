import XCTest
@testable import QuoinCore

/// Conformance against the VENDORED RDFM 0.2 spec + review-index schema
/// (Fixtures/rdfm/, fetched from roughdraft.md 2026-07-14). Three layers:
/// the spec document itself as a torture golden (every marker example lives
/// in a fenced code block — the code-opacity MUST holds on the spec's own
/// text), the spec's canonical examples verbatim, and structural alignment
/// with the review-index schema.
final class RDFMConformanceTests: XCTestCase {

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // QuoinCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Fixtures/rdfm")
    }

    // MARK: - The spec document as a golden

    func testTheSpecItselfParsesWithZeroMarks() throws {
        let url = fixturesDir.appendingPathComponent("roughdraft-flavored-markdown.md")
        let source = try String(contentsOf: url, encoding: .utf8)
        let document = MarkdownConverter.parse(source)

        // Every marker in the spec is an EXAMPLE inside a fenced block; the
        // normative code-opacity rule means parsing the spec must find
        // nothing. (This is the strongest single test of the opacity guards:
        // dozens of realistic marks, all of which must stay literal.)
        XCTAssertEqual(document.stats.suggestionCount, 0,
                       "spec examples are fenced — the opacity MUST holds on the spec itself")
        XCTAssertNil(document.reviewMetadata,
                     "the spec's endmatter examples are fenced too")
        XCTAssertGreaterThan(document.blocks.count, 10)
        XCTAssertEqual(document.source, source, "parse never rewrites")
    }

    // MARK: - Canonical examples, verbatim from the spec

    func testStandaloneCommentExample() throws {
        let source = """
        Add one concrete launch example here.{>>This should come from the customer story.<<}{#c1}

        ---
        comments:
          c1:
            by: user
            at: "2026-04-28T12:00:00.000Z"

        """
        let document = MarkdownConverter.parse(source)
        let marks = SuggestionResolver.marks(in: document)
        XCTAssertEqual(marks.count, 1)
        guard case .comment(let text) = marks[0].kind else { return XCTFail("comment") }
        XCTAssertEqual(text, "This should come from the customer story.")
        XCTAssertEqual(marks[0].id, "c1")
        XCTAssertEqual(document.reviewMetadata?.comments["c1"]?.by, "user")
        XCTAssertEqual(document.reviewMetadata?.comments["c1"]?.at, "2026-04-28T12:00:00.000Z")
    }

    func testAnchoredCommentExample() throws {
        let source = """
        Please revisit {==this sentence==}{>>Needs a source.<<}{#c1}.

        ---
        comments:
          c1:
            by: user
            at: "2026-04-28T12:00:00.000Z"

        """
        let document = MarkdownConverter.parse(source)
        let marks = SuggestionResolver.marks(in: document)
        XCTAssertEqual(marks.count, 2, "highlight anchor + its comment")
        guard case .highlight(let anchor) = marks[0].kind else { return XCTFail("anchor first") }
        XCTAssertEqual(anchor.plainText, "this sentence")
        guard case .comment = marks[1].kind else { return XCTFail("comment second") }
        XCTAssertEqual(marks[1].id, "c1")
    }

    func testSuggestionExamplesWithReplyThreading() throws {
        let source = """
        Add {++one concrete example++}{#s1}.

        ---
        comments:
          c2:
            body: Use the launch story.
            by: user
            at: "2026-04-28T12:08:00.000Z"
            re: s1
        suggestions:
          s1:
            by: AI
            at: "2026-04-28T12:05:00.000Z"

        """
        let document = MarkdownConverter.parse(source)
        let marks = SuggestionResolver.marks(in: document)
        XCTAssertEqual(marks.count, 1)
        guard case .insertion(let body) = marks[0].kind else { return XCTFail() }
        XCTAssertEqual(body.plainText, "one concrete example")
        XCTAssertEqual(marks[0].id, "s1")
        let metadata = try XCTUnwrap(document.reviewMetadata)
        XCTAssertEqual(metadata.suggestions["s1"]?.by, "AI",
                       "the literal AI marks agent authorship")
        // The reply threads to the SUGGESTION (re: may point at either kind).
        XCTAssertEqual(metadata.comments["c2"]?.re, "s1")
        XCTAssertEqual(metadata.comments["c2"]?.body, "Use the launch story.")
    }

    func testSubstitutionExampleResolvesPerSpec() throws {
        let source = "Use {~~rough~>specific~~}{#s3} wording.\n"
        let document = MarkdownConverter.parse(source)
        let mark = SuggestionResolver.marks(in: document)[0]
        let accepted = try XCTUnwrap(SuggestionResolver.edit(
            resolving: mark.range, in: source, action: .accept))
        XCTAssertEqual(accepted.replacement, "specific")
        let rejected = try XCTUnwrap(SuggestionResolver.edit(
            resolving: mark.range, in: source, action: .reject))
        XCTAssertEqual(rejected.replacement, "rough")
    }

    /// The spec's id grammar: ALPHA *( ALPHA / DIGIT / "_" / "-" ).
    func testIdGrammar() throws {
        let ok = MarkdownConverter.parse("X {++y++}{#a1_b-c} z.\n")
        XCTAssertEqual(SuggestionResolver.marks(in: ok)[0].id, "a1_b-c")
        // A malformed reference is NOT part of the mark (stays literal text).
        let bad = MarkdownConverter.parse("X {++y++}{#has space} z.\n")
        XCTAssertNil(SuggestionResolver.marks(in: bad)[0].id)
        XCTAssertTrue(bad.source.contains("{#has space}"))
    }

    /// KNOWN GAP (documented, spec compat-level "readers also accept"): the
    /// older inline attribute block `{id="c3" by="user" …}` is not parsed as
    /// metadata yet — it degrades to literal text after the mark, which is
    /// safe (lossless) but not reader-compatible. Tracked for S4.
    func testInlineAttributeBlockGapIsLosslesslyLiteral() throws {
        let source = "X {>>note<<}{id=\"c3\" by=\"user\"} y.\n"
        let document = MarkdownConverter.parse(source)
        let marks = SuggestionResolver.marks(in: document)
        XCTAssertEqual(marks.count, 1)
        XCTAssertNil(marks[0].id, "attribute-block metadata not yet read (S4)")
        XCTAssertEqual(document.source, source, "but nothing is eaten")
    }

    // MARK: - Review-index schema alignment

    func testSchemaKindsMatchOurModel() throws {
        let url = fixturesDir.appendingPathComponent("roughdraft-flavored-markdown.schema.json")
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let defs = try XCTUnwrap(json["$defs"] as? [String: Any])
        let suggestion = try XCTUnwrap(defs["suggestion"] as? [String: Any])
        let properties = try XCTUnwrap(suggestion["properties"] as? [String: Any])
        let kind = try XCTUnwrap(properties["kind"] as? [String: Any])
        let kinds = try XCTUnwrap(kind["enum"] as? [String])
        XCTAssertEqual(Set(kinds), ["addition", "deletion", "substitution"],
                       "the schema's suggestion kinds are exactly our resolvable set")

        // Required metadata fields all exist on ReviewEntry.
        let comment = try XCTUnwrap(defs["comment"] as? [String: Any])
        let required = try XCTUnwrap(comment["required"] as? [String])
        XCTAssertEqual(Set(required), ["id", "body", "by", "at"])
        var entry = ReviewEntry()
        entry.by = "user"; entry.at = "2026-04-28T12:00:00Z"; entry.body = "b"; entry.re = "c1"
        XCTAssertNotNil(entry.by); XCTAssertNotNil(entry.at); XCTAssertNotNil(entry.body)

        // The index's version const matches the spec we vendored.
        let props = try XCTUnwrap(json["properties"] as? [String: Any])
        let version = try XCTUnwrap(props["version"] as? [String: Any])
        XCTAssertEqual(version["const"] as? String, "0.2")
    }
}
