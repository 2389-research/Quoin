import XCTest
@testable import QuoinCore

final class EditableSerializerTests: XCTestCase {

    /// The core invariant: build → serialize is byte-identical to the source,
    /// across the same corpus Phase 0 validated (fixtures + edge cases). This is
    /// the same proof, now through the real mutable model.
    func testSerializeRoundTripIsByteIdenticalOverCorpus() {
        // Guard: the corpus MUST include the on-disk fixtures, not just the
        // inline edges. A path typo that silently drops them would leave this
        // test green while proving nothing about real documents.
        XCTAssertFalse(Self.fixtureCorpus().isEmpty,
                       "corpus loaded zero repo fixtures — Fixtures/ path is wrong")
        for (name, source) in Self.corpus() {
            let rebuilt = EditableDocument.build(parsing: source).serialized()
            XCTAssertEqual(Array(rebuilt.utf8), Array(source.utf8),
                           "\(name): build → serialize is NOT byte-identical")
        }
    }

    /// A trivially small, explicit case.
    func testSerializeSmallDocument() {
        let s = "# H\n\nBody\n"
        XCTAssertEqual(EditableDocument.build(parsing: s).serialized(), s)
    }

    // The on-disk repo fixtures. From this file
    // (Tests/QuoinCoreTests/EditableDocument/…) up FOUR levels to the repo
    // root, then Fixtures/. (The brief's draft used three levels, which lands
    // at Tests/ and silently loads nothing — corrected here so the fuzz
    // actually exercises the fixtures.)
    static func fixtureCorpus() -> [(String, String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "md" }
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) } } ?? []
    }

    // Shared corpus: repo fixtures + the pathological edge cases from Phase 0.
    static func corpus() -> [(String, String)] {
        let fixtures = fixtureCorpus()
        let edges: [(String, String)] = [
            ("empty", ""), ("blank-only", "\n\n\n"), ("crlf", "# H\r\n\r\nA.\r\n"),
            ("no-trailing", "# H"), ("many-trailing", "x\n\n\n\n\n"),
            ("front-matter", "---\ntitle: Hi\n---\n\n# B\n"),
            ("footnote", "A.[^1]\n\n[^1]: def.\n"), ("nested-list", "- a\n  - b\n- c\n"),
            ("table", "| a | b |\n| - | - |\n| 1 | 2 |\n"),
            ("fenced", "```swift\nlet x = 1\n```\n"), ("quote", "> a\n> b\n"),
            ("unicode", "# café ☕️\n\nrésumé\n"), ("html", "<div>\n x\n</div>\n\nt\n"),
        ]
        return fixtures + edges
    }
}
