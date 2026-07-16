import XCTest
@testable import QuoinCore

/// The Linux word-count fallback must agree with Darwin's `.byWords` on
/// prose (docs/design/platforms.md Phase 0). This runs on BOTH platforms:
/// on Darwin it pins fallback == ICU for the corpus; on Linux it pins the
/// fallback's absolute counts, so a divergence on either side fails CI.
final class WordCountingParityTests: XCTestCase {

    private let corpus: [(String, Int)] = [
        ("", 0),
        ("word", 1),
        ("two words", 2),
        ("Don't count contractions twice.", 4),
        ("byte-safe round-trip editing", 5),
        ("A -- dash is punctuation", 4),
        ("Numbers 42 and 3.14 count", 5),
        ("  leading and trailing  ", 3),
        ("line\nbreaks\nseparate", 3),
        ("Curly don\u{2019}t apostrophe", 3),
        ("hyphen-chain-of-many parts", 5),
        ("(parenthesised words) matter", 3),
    ]

    func testFallbackMatchesExpectedCounts() {
        for (text, expected) in corpus {
            XCTAssertEqual(WordCounting.fallbackCount(in: text), expected,
                           "fallback drifted for: \(text.debugDescription)")
        }
    }

    #if canImport(Darwin)
    func testFallbackAgreesWithByWordsOnTheCorpus() {
        for (text, _) in corpus {
            XCTAssertEqual(WordCounting.fallbackCount(in: text),
                           WordCounting.count(in: text),
                           "fallback ≠ .byWords for: \(text.debugDescription)")
        }
    }

    func testFallbackAgreesWithByWordsOnRealProse() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/renderer/01-headings-and-paragraphs.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("fixture moved")
        }
        XCTAssertEqual(WordCounting.fallbackCount(in: text), WordCounting.count(in: text),
                       "fallback ≠ .byWords on real prose fixture")
    }
    #endif
}
