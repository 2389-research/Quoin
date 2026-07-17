import XCTest
@testable import QuoinCore

/// The ONE matcher behind both find-highlighting and replace (#23). If these
/// rules drift, "1 of 3" and Replace-All disagree — the shipped bug class.
final class TextMatcherTests: XCTestCase {

    private func substrings(_ query: String, _ haystack: String, _ o: SearchOptions,
                            within: NSRange? = nil) -> [String]? {
        let ns = haystack as NSString
        guard let ranges = TextMatcher.matches(of: query, in: ns, options: o, within: within)
        else { return nil }
        return ranges.map { ns.substring(with: $0) }
    }

    // MARK: Match Case

    func testCaseInsensitiveByDefault() {
        XCTAssertEqual(
            substrings("cat", "cat CAT Cat", SearchOptions()),
            ["cat", "CAT", "Cat"])
    }

    func testMatchCaseIsExact() {
        XCTAssertEqual(
            substrings("Cat", "cat CAT Cat", SearchOptions(matchCase: true)),
            ["Cat"])
    }

    // MARK: Whole Word

    func testWholeWordBoundaries() {
        XCTAssertEqual(
            substrings("cat", "cat category cats scat cat.", SearchOptions(wholeWord: true)),
            ["cat", "cat"], "only standalone 'cat' words match")
    }

    func testWholeWordWithNonWordQueryEdges() {
        // A query bounded by punctuation still matches — the boundary is
        // "not a word character on the outside", robust to `\b`'s edge cases.
        XCTAssertEqual(
            substrings("c++", "c++ code, c++.", SearchOptions(wholeWord: true)),
            ["c++", "c++"])
    }

    func testWholeWordRespectsCase() {
        XCTAssertEqual(
            substrings("cat", "Cat cat", SearchOptions(matchCase: true, wholeWord: true)),
            ["cat"])
    }

    // MARK: Regex

    func testRegexMatches() {
        XCTAssertEqual(
            substrings("c.t", "cat cot cut cart", SearchOptions(regex: true)),
            ["cat", "cot", "cut"])
    }

    func testRegexIsCaseInsensitiveByDefault() {
        XCTAssertEqual(
            substrings("c.t", "CAT cot", SearchOptions(regex: true)),
            ["CAT", "cot"])
    }

    func testRegexMatchCase() {
        XCTAssertEqual(
            substrings("C.T", "CAT cot", SearchOptions(matchCase: true, regex: true)),
            ["CAT"])
    }

    func testRegexPlusWholeWord() {
        // \d+ as a whole word: "12" and "3" match, the "45" inside "a45b" does not.
        XCTAssertEqual(
            substrings("\\d+", "12 and 3, a45b", SearchOptions(wholeWord: true, regex: true)),
            ["12", "3"])
    }

    func testInvalidRegexReturnsNil() {
        XCTAssertNil(substrings("(unclosed", "text", SearchOptions(regex: true)))
        XCTAssertFalse(TextMatcher.isValidQuery("(unclosed", options: SearchOptions(regex: true)))
        XCTAssertTrue(TextMatcher.isValidQuery("(closed)", options: SearchOptions(regex: true)))
        XCTAssertTrue(TextMatcher.isValidQuery("(", options: SearchOptions()),
                      "a literal '(' is always a valid query")
    }

    func testRegexZeroWidthMatchesAreDropped() {
        // `x*` can match the empty string between characters — those must not
        // become highlights or replace targets; only non-empty runs survive.
        XCTAssertEqual(
            substrings("x*", "axxbxc", SearchOptions(regex: true)),
            ["xx", "x"])
    }

    // MARK: Diacritics + empty

    func testDiacriticSensitiveAlways() {
        XCTAssertEqual(substrings("cafe", "cafe café", SearchOptions()), ["cafe"])
        XCTAssertEqual(substrings("cafe", "cafe café", SearchOptions(regex: true)), ["cafe"])
    }

    func testEmptyQueryNeverMatches() {
        XCTAssertEqual(substrings("", "anything", SearchOptions()), [])
        XCTAssertEqual(substrings("", "anything", SearchOptions(regex: true)), [])
    }

    // MARK: In-Selection scope

    func testWithinScopeRestrictsMatches() {
        // "cat cat cat" — scope only the middle occurrence (chars 4..<7).
        XCTAssertEqual(
            substrings("cat", "cat cat cat", SearchOptions(), within: NSRange(location: 4, length: 3)),
            ["cat"])
    }

    func testScopeClampsOutOfBounds() {
        // A stale selection range past the end must not crash or over-read.
        XCTAssertEqual(
            substrings("cat", "cat", SearchOptions(), within: NSRange(location: 0, length: 999)),
            ["cat"])
    }
}
