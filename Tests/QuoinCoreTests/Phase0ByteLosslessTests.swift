import XCTest
@testable import QuoinCore

/// PHASE 0 — the byte-lossless foundation experiment for the tree-as-truth
/// re-architecture (docs/design/wysiwyg-architecture-comparison.md).
///
/// The crux the architecture debate identified: *can a structured tree
/// losslessly decompose and reproduce real markdown, byte-for-byte?* This is
/// the make-or-break question, answered cheaply BEFORE building an editing
/// model on top.
///
/// The experiment: parse each corpus document, decompose the source into an
/// ordered span tree — top-level block spans plus the trivia (whitespace, blank
/// lines, and any content the block model does not own) between and around them
/// — and re-emit it. The re-emission MUST be byte-identical to the input. It
/// also measures WHAT non-whitespace content falls into trivia (footnote
/// definitions, front matter, etc.) — the semantic bytes a real node tree must
/// learn to own, surfaced now rather than discovered mid-migration.
final class Phase0ByteLosslessTests: XCTestCase {

    // MARK: - Corpus

    /// Rich real documents shipped as fixtures.
    private func fixtureCorpus() -> [(name: String, source: String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // QuoinCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Fixtures")
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) }
            }
    }

    /// Pathological / edge-case inputs — the CommonMark & GFM corners that break
    /// naive round-trips.
    private func edgeCorpus() -> [(name: String, source: String)] {
        [
            ("empty", ""),
            ("blank-only", "\n\n\n"),
            ("crlf", "# Heading\r\n\r\nA paragraph.\r\n"),
            ("mixed-endings", "A\nB\r\nC\n"),
            ("no-trailing-newline", "# Heading"),
            ("many-trailing", "text\n\n\n\n\n"),
            ("leading-blank", "\n\n# Heading\n\nbody\n"),
            ("front-matter", "---\ntitle: Hi\ntags: [a, b]\n---\n\n# Body\n"),
            ("footnote", "A claim.[^1]\n\n[^1]: The footnote definition.\n"),
            ("setext-h1", "Title\n=====\n\nbody\n"),
            ("nested-list", "- a\n  - b\n    - c\n- d\n"),
            ("loose-list", "- a\n\n- b\n\n- c\n"),
            ("table", "| a | b |\n| - | - |\n| 1 | 2 |\n"),
            ("fenced-code", "```swift\nlet x = 1\n// unclosed\n"),
            ("indented-code", "    let x = 1\n    let y = 2\n"),
            ("blockquote", "> line one\n> line two\n>\n> after gap\n"),
            ("hard-wrap", "one two three  \nsecond line\n"),
            ("tabs", "\ttabbed\n\n- \titem\n"),
            ("unicode", "# café ☕️ — naïve “quotes”\n\nrésumé\n"),
            ("html-block", "<div class=\"x\">\n  raw\n</div>\n\ntext\n"),
            ("thematic-breaks", "a\n\n---\n\nb\n\n***\n\nc\n"),
            ("trailing-spaces-line", "text   \n\nmore\n"),
        ]
    }

    private func corpus() -> [(name: String, source: String)] {
        fixtureCorpus() + edgeCorpus()
    }

    // MARK: - The span decomposition (the Phase-0 tree, minimal form)

    private enum Span { case block(Int), trivia }

    /// Ordered spans covering [0, source.utf8.count) exactly. Trivia = the bytes
    /// between/around top-level blocks that the block model does not own.
    private func decompose(_ doc: QuoinDocument) -> [(kind: Span, bytes: ByteRange)]? {
        let total = doc.source.utf8.count
        let blocks = doc.blocks.enumerated()
            .map { (i: $0.offset, r: $0.element.range) }
            .sorted { $0.r.offset < $1.r.offset }
        var spans: [(Span, ByteRange)] = []
        var cursor = 0
        for b in blocks {
            // Well-formedness: ordered, non-overlapping, in-bounds.
            guard b.r.offset >= cursor, b.r.offset + b.r.length <= total else { return nil }
            if b.r.offset > cursor {
                spans.append((.trivia, ByteRange(offset: cursor, length: b.r.offset - cursor)))
            }
            spans.append((.block(b.i), b.r))
            cursor = b.r.offset + b.r.length
        }
        if cursor < total {
            spans.append((.trivia, ByteRange(offset: cursor, length: total - cursor)))
        }
        return spans
    }

    private func serialize(_ doc: QuoinDocument, _ spans: [(kind: Span, bytes: ByteRange)]) -> String? {
        var out = ""
        for span in spans {
            guard let s = doc.source.substring(in: span.bytes) else { return nil }
            out += s
        }
        return out
    }

    // MARK: - The experiment

    func testByteLosslessRoundTripOverCorpus() {
        var checked = 0
        var triviaWithContent: [(String, String)] = []
        for (name, source) in corpus() {
            let doc = MarkdownConverter.parse(source)

            guard let spans = decompose(doc) else {
                XCTFail("\(name): block ranges are not a clean tiling (overlap/out-of-order/oob)")
                continue
            }
            guard let rebuilt = serialize(doc, spans) else {
                XCTFail("\(name): a span could not be sliced from the source")
                continue
            }
            XCTAssertEqual(
                Array(rebuilt.utf8), Array(source.utf8),
                "\(name): parse → decompose → serialize is NOT byte-identical")
            checked += 1

            // Surface non-whitespace content that fell into trivia — the bytes a
            // real node tree must own (footnote defs, etc.). Not a failure here;
            // an inventory for the migration.
            for span in spans where { if case .trivia = span.kind { return true }; return false }() {
                if let s = doc.source.substring(in: span.bytes),
                   !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    triviaWithContent.append((name, s.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
        XCTAssertGreaterThan(checked, 20, "corpus should be non-trivial")
        print("PHASE0 ▸ byte-lossless round-trip PASSED for \(checked) documents")
        if triviaWithContent.isEmpty {
            print("PHASE0 ▸ every non-whitespace byte is owned by a top-level block — clean basis")
        } else {
            print("PHASE0 ▸ \(triviaWithContent.count) non-whitespace trivia spans (content the node tree must own):")
            for (name, s) in triviaWithContent.prefix(20) {
                print("PHASE0 ▸   [\(name)] \(s.prefix(60).debugDescription)")
            }
        }
    }
}
