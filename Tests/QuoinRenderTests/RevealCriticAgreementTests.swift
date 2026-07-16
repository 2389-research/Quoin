import XCTest
@testable import QuoinRender
import QuoinCore

/// CLAUDE.md warns that two recognizers for one grammar WILL diverge, and the
/// CriticMarkup grammar shipped a bug when the reveal styler's regexes and the
/// parser's `CriticScanner` disagreed. This pins them: on a code-free corpus,
/// the marks the reveal styler recognizes must be byte-for-byte the marks
/// `CriticScanner` recognizes (same spans, including the `{#id}` tail).
final class RevealCriticAgreementTests: XCTestCase {

    private let styler = MarkdownSourceStyler(theme: Theme())

    /// Corpus is ASCII, so a UTF-8 byte offset equals its UTF-16 offset and the
    /// two range conventions compare directly.
    private func scannerRanges(_ input: String) -> [NSRange] {
        CriticScanner.scan(input).compactMap { segment -> NSRange? in
            guard case .mark(let mark) = segment else { return nil }
            return NSRange(location: mark.range.offset, length: mark.range.length)
        }.sorted { $0.location < $1.location }
    }

    func testStylerAndScannerAgreeOnCorpus() {
        let corpus = [
            "plain prose with no marks at all",
            "an {++inserted++} word",
            "a {--deleted--} word",
            "a {~~old~>new~~} substitution",
            "a {>>a review comment<<} here",
            "a {==highlighted==} span",
            "two marks {++a++} then {--b--} in a line",
            "adjacent {++a++}{--b--} marks touching",
            "with an id {++x++}{#note-1} tail",
            "substitution with id {~~a~>b~~}{#s2} end",
            // Shipped-bug shapes: neither recognizer should treat these as a
            // substitution spanning a LATER `~~}`.
            "not a sub {~~just delete~~} really",
            "sub then delete {~~a~>b~~} and {~~c~~} tail",
            "empty-ish {++++} and {----} edges",
            "comment with arrow {>>see a~>b idea<<} inside",
        ]
        for input in corpus {
            XCTAssertEqual(
                styler.criticMarkRanges(in: input),
                scannerRanges(input),
                "reveal styler and CriticScanner disagree on: \(input)")
        }
    }

    /// The `{#id}` grammar is DIGIT-rejecting first char (a `{#1x}` tail is
    /// literal prose both must keep out of the mark range).
    func testIdTailGrammarAgrees() {
        for input in ["mark {++x++}{#1bad} tail", "mark {++x++}{#good-1} tail", "mark {++x++}{#} tail"] {
            XCTAssertEqual(
                styler.criticMarkRanges(in: input),
                scannerRanges(input),
                "id-tail handling diverges on: \(input)")
        }
    }
}
