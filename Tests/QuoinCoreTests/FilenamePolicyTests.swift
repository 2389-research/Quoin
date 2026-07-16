import XCTest
@testable import QuoinCore

final class FilenamePolicyTests: XCTestCase {

    func testPreservesInternationalTitles() {
        XCTAssertEqual(FilenamePolicy.sanitize("会議メモ"), "会議メモ")
        XCTAssertEqual(FilenamePolicy.sanitize("ملاحظات"), "ملاحظات")
        XCTAssertEqual(FilenamePolicy.sanitize("Café résumé"), "Café résumé")
        XCTAssertEqual(FilenamePolicy.sanitize("Roadmap 🚀 2026"), "Roadmap 🚀 2026")
    }

    func testReplacesPathAndVolumeSeparators() {
        XCTAssertEqual(FilenamePolicy.sanitize("a/b:c\\d"), "a-b-c-d")
    }

    func testStripsControlCharactersAndCollapsesWhitespace() {
        XCTAssertEqual(FilenamePolicy.sanitize("Line1\nLine2"), "Line1 Line2")
        XCTAssertEqual(FilenamePolicy.sanitize("a\tb"), "a b")
        XCTAssertEqual(FilenamePolicy.sanitize("has\u{0000}nul"), "has nul")
        XCTAssertEqual(FilenamePolicy.sanitize("spread   out"), "spread out")
    }

    func testTrimsLeadingDotsSoFilesAreNotHidden() {
        XCTAssertEqual(FilenamePolicy.sanitize(".hidden"), "hidden")
        XCTAssertEqual(FilenamePolicy.sanitize("...ellipsis lead"), "ellipsis lead")
        XCTAssertEqual(FilenamePolicy.sanitize("trailing..."), "trailing")
        XCTAssertEqual(FilenamePolicy.sanitize("  spaced  "), "spaced")
    }

    func testEmptyOrStrippedToNothingFallsBack() {
        XCTAssertEqual(FilenamePolicy.sanitize(""), FilenamePolicy.fallback)
        XCTAssertEqual(FilenamePolicy.sanitize("   "), FilenamePolicy.fallback)
        XCTAssertEqual(FilenamePolicy.sanitize("."), FilenamePolicy.fallback)
        XCTAssertEqual(FilenamePolicy.sanitize("\n\t\u{0000}"), FilenamePolicy.fallback)
        // Separators map to dashes, so "///" is the valid name "---", not empty.
        XCTAssertEqual(FilenamePolicy.sanitize("///"), "---")
    }

    func testTruncatesByUTF8BytesNotCharacterCount() {
        // 300 CJK characters = 900 UTF-8 bytes, far over any real limit.
        let long = String(repeating: "ん", count: 300)
        let result = FilenamePolicy.sanitize(long)
        XCTAssertLessThanOrEqual(result.utf8.count, FilenamePolicy.maxBaseNameUTF8Bytes)
        XCTAssertGreaterThan(result.count, 0)
        // Never splits a scalar: the truncated name is still valid, round-trips.
        XCTAssertEqual(String(decoding: Array(result.utf8), as: UTF8.self), result)
    }

    func testTruncationDoesNotSplitEmoji() {
        // Budget lands mid-emoji; the whole grapheme must be dropped, not halved.
        let title = String(repeating: "😀", count: 100)   // 400 bytes
        let result = FilenamePolicy.sanitize(title)
        XCTAssertLessThanOrEqual(result.utf8.count, FilenamePolicy.maxBaseNameUTF8Bytes)
        XCTAssertFalse(result.utf8.contains(0xFF), "no replacement-character bytes")
        // Every remaining character is a full emoji (4 bytes), so byte count is /4.
        XCTAssertEqual(result.utf8.count % 4, 0)
    }

    func testIdempotent() {
        for title in ["a/b:c", ".hidden", "Café", "Line1\nLine2", "///"] {
            let once = FilenamePolicy.sanitize(title)
            XCTAssertEqual(FilenamePolicy.sanitize(once), once, "not idempotent for \(title)")
        }
    }
}
