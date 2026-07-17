import XCTest
@testable import QuoinCore

/// Find & replace over the raw source, byte-exact (#85). Replace changes
/// what the file says, so it operates on the source of truth.
final class SourceReplaceTests: XCTestCase {

    private func applying(_ edit: SourceEdit, to source: String) -> String {
        var b = Array(source.utf8)
        b.replaceSubrange(edit.range.offset..<(edit.range.offset + edit.range.length),
                          with: Array(edit.replacement.utf8))
        return String(decoding: b, as: UTF8.self)
    }

    func testMatchesAreCaseInsensitiveByteRanges() {
        let source = "The cat sat. A CAT ran. cat.\n"
        let m = SourceReplace.matches(of: "cat", in: source)
        XCTAssertEqual(m.count, 3)
        for r in m {
            let slice = String(decoding: Array(source.utf8)[r.offset..<(r.offset + r.length)], as: UTF8.self)
            XCTAssertEqual(slice.lowercased(), "cat")
        }
    }

    func testReplaceAllIsOneSpanningEdit() {
        let source = "a cat, a CAT, a cat.\n"
        let edit = try! XCTUnwrap(SourceReplace.replaceAllEdit(of: "cat", with: "dog", in: source))
        XCTAssertEqual(applying(edit, to: source), "a dog, a dog, a dog.\n")
        // The edit spans only first-match → last-match; the leading "a "
        // and trailing ".\n" are outside the replaced range.
        XCTAssertEqual(edit.range.offset, 2, "span starts at the first match")
        XCTAssertEqual(edit.range.offset + edit.range.length, 19, "span ends at the last match")
    }

    func testReplaceAllPreservesUntouchedBytes() {
        let source = "# Title\n\nkeep me exactly, replace foo here, keep me too.\n"
        let edit = try! XCTUnwrap(SourceReplace.replaceAllEdit(of: "foo", with: "bar", in: source))
        let after = applying(edit, to: source)
        XCTAssertEqual(after, "# Title\n\nkeep me exactly, replace bar here, keep me too.\n")
        XCTAssertTrue(after.hasPrefix("# Title\n\n"), "prefix byte-identical")
    }

    func testReplaceNextFromOffsetWraps() {
        let source = "one two one two\n"
        // From offset 5 (after first "one"), next "one" is at 8.
        let (edit, next) = try! XCTUnwrap(SourceReplace.replaceNextEdit(
            of: "one", with: "X", in: source, fromByteOffset: 5))
        XCTAssertEqual(edit.range.offset, 8)
        XCTAssertEqual(next, 8 + 1)
        // From past the last match, it wraps to the first.
        let (wrap, _) = try! XCTUnwrap(SourceReplace.replaceNextEdit(
            of: "one", with: "X", in: source, fromByteOffset: 99))
        XCTAssertEqual(wrap.range.offset, 0)
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(SourceReplace.replaceAllEdit(of: "zzz", with: "x", in: "abc\n"))
        XCTAssertNil(SourceReplace.replaceNextEdit(of: "zzz", with: "x", in: "abc\n", fromByteOffset: 0))
        XCTAssertTrue(SourceReplace.matches(of: "", in: "abc").isEmpty, "empty query never matches")
    }

    func testUnicodeByteRangesAreCorrect() {
        let source = "café résumé café\n"
        let edit = try! XCTUnwrap(SourceReplace.replaceAllEdit(of: "café", with: "COFFEE", in: source))
        XCTAssertEqual(applying(edit, to: source), "COFFEE résumé COFFEE\n")
    }

    func testReplacementCanContainTheQueryWithoutInfiniteMatch() {
        // Replace-all is computed against the ORIGINAL source once, so a
        // replacement containing the query does not re-match.
        let source = "x x x\n"
        let edit = try! XCTUnwrap(SourceReplace.replaceAllEdit(of: "x", with: "xx", in: source))
        XCTAssertEqual(applying(edit, to: source), "xx xx xx\n")
    }

    // MARK: - Options (#23)

    private func slices(_ ranges: [ByteRange], in source: String) -> [String] {
        let bytes = Array(source.utf8)
        return ranges.map { String(decoding: bytes[$0.offset..<($0.offset + $0.length)], as: UTF8.self) }
    }

    func testMatchCaseOption() {
        let source = "Cat cat CAT\n"
        XCTAssertEqual(
            slices(SourceReplace.matches(of: "cat", in: source, options: SearchOptions(matchCase: true)), in: source),
            ["cat"])
    }

    func testWholeWordOption() {
        let source = "cat cats scatter cat.\n"
        XCTAssertEqual(
            slices(SourceReplace.matches(of: "cat", in: source, options: SearchOptions(wholeWord: true)), in: source),
            ["cat", "cat"])
    }

    func testRegexOption() {
        let source = "cat cot cut cart\n"
        XCTAssertEqual(
            slices(SourceReplace.matches(of: "c.t", in: source, options: SearchOptions(regex: true)), in: source),
            ["cat", "cot", "cut"])
    }

    func testInvalidRegexReplacesNothing() {
        let source = "abc\n"
        XCTAssertTrue(SourceReplace.matches(of: "(", in: source, options: SearchOptions(regex: true)).isEmpty)
        XCTAssertNil(SourceReplace.replaceAllEdit(of: "(", with: "x", in: source, options: SearchOptions(regex: true)))
    }

    func testRegexReplaceAllRewritesEveryMatch() {
        let source = "cat cot cut\n"
        let edit = try! XCTUnwrap(SourceReplace.replaceAllEdit(
            of: "c.t", with: "dog", in: source, options: SearchOptions(regex: true)))
        XCTAssertEqual(applying(edit, to: source), "dog dog dog\n")
    }

    func testWithinScopeRestrictsReplace() {
        // "cat cat cat\n" — scope only the middle occurrence (bytes 4..<7).
        let source = "cat cat cat\n"
        let edit = try! XCTUnwrap(SourceReplace.replaceAllEdit(
            of: "cat", with: "dog", in: source, within: ByteRange(offset: 4, length: 3)))
        XCTAssertEqual(applying(edit, to: source), "cat dog cat\n")
    }

    func testWithinScopeAcrossMultibyteBytesStaysExact() {
        // A scope that begins after a multibyte character maps correctly.
        let source = "café cat café cat\n"  // 'é' is two UTF-8 bytes
        // Scope from after the first "café " — replace only in the tail.
        let head = "café cat café ".utf8.count
        let edit = try! XCTUnwrap(SourceReplace.replaceAllEdit(
            of: "cat", with: "dog", in: source,
            within: ByteRange(offset: head, length: "cat".utf8.count)))
        XCTAssertEqual(applying(edit, to: source), "café cat café dog\n")
    }

    /// The find scan (`TextMatcher` on the projection NSString) and replace
    /// (`SourceReplace` on the source) MUST recognize the same occurrences
    /// when handed the same string — otherwise "1 of N" replaces a different
    /// count. This pins agreement across every option combination.
    func testFindAndReplaceAgreeOnEveryOptionCombination() {
        let haystack = "Cat cat CAT category cats café c.t scat CAT.\n"
        let queries = ["cat", "Cat", "c.t", "café", "\\bcat\\b", "CAT"]
        let combos = [
            SearchOptions(),
            SearchOptions(matchCase: true),
            SearchOptions(wholeWord: true),
            SearchOptions(regex: true),
            SearchOptions(matchCase: true, wholeWord: true),
            SearchOptions(matchCase: true, regex: true),
            SearchOptions(wholeWord: true, regex: true),
            SearchOptions(matchCase: true, wholeWord: true, regex: true),
        ]
        let ns = haystack as NSString
        for query in queries {
            for options in combos {
                let matcherSlices = (TextMatcher.matches(of: query, in: ns, options: options) ?? [])
                    .map { ns.substring(with: $0) }
                let replaceSlices = slices(
                    SourceReplace.matches(of: query, in: haystack, options: options), in: haystack)
                XCTAssertEqual(
                    matcherSlices, replaceSlices,
                    "find vs replace diverged for query=\(query) options=\(options)")
            }
        }
    }
}
