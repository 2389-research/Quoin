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
}
