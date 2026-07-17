import XCTest
@testable import QuoinCore

/// Tests the pure "seed a new document from a selection" seam (#35). The live
/// `NSPasteboard` handler in the app shell is a thin wrapper over this — it
/// pulls `.string`, guards emptiness, and forwards here — so the naming/content
/// rules are verified headlessly, on Linux CI included. The pasteboard handler
/// itself can't be exercised without AppKit + a real pasteboard, so this pins
/// the seam directly beneath it.
final class NewDocumentSeedTests: XCTestCase {

    func testNameComesFromFirstNonEmptyLine() {
        let seed = NewDocumentSeed.make(fromSelection: "Meeting notes\nmore text\n")
        XCTAssertEqual(seed.baseName, "Meeting notes")
    }

    func testLeadingBlankLinesAreSkippedForTheName() {
        let seed = NewDocumentSeed.make(fromSelection: "\n\n   \nReal title\nbody")
        XCTAssertEqual(seed.baseName, "Real title")
    }

    func testHeadingMarkerIsStrippedFromTheName() {
        XCTAssertEqual(NewDocumentSeed.make(fromSelection: "# My Note\n\nbody").baseName, "My Note")
        XCTAssertEqual(NewDocumentSeed.make(fromSelection: "### Deep heading").baseName, "Deep heading")
        // Seven hashes is not a heading (ATX caps at 6) — kept verbatim (the
        // '#' run then sanitizes through as-is).
        XCTAssertEqual(NewDocumentSeed.make(fromSelection: "####### not a heading").baseName, "####### not a heading")
        // A '#' with no following space is a fragment, not a heading marker.
        XCTAssertEqual(NewDocumentSeed.make(fromSelection: "#hashtag").baseName, "#hashtag")
    }

    func testListMarkersAreStrippedFromTheName() {
        XCTAssertEqual(NewDocumentSeed.make(fromSelection: "- bullet item").baseName, "bullet item")
        XCTAssertEqual(NewDocumentSeed.make(fromSelection: "* star item").baseName, "star item")
        XCTAssertEqual(NewDocumentSeed.make(fromSelection: "+ plus item").baseName, "plus item")
        XCTAssertEqual(NewDocumentSeed.make(fromSelection: "1. first item").baseName, "first item")
        XCTAssertEqual(NewDocumentSeed.make(fromSelection: "12) numbered").baseName, "numbered")
        // A dash with no space is a word (or an em-dash-y title), not a bullet.
        XCTAssertEqual(NewDocumentSeed.make(fromSelection: "-notabullet").baseName, "-notabullet")
    }

    func testContentIsTheSelectionWithATrailingNewline() {
        XCTAssertEqual(
            NewDocumentSeed.make(fromSelection: "line one\nline two").content,
            "line one\nline two\n"
        )
        // Already newline-terminated selections are not double-terminated.
        XCTAssertEqual(
            NewDocumentSeed.make(fromSelection: "already ends\n").content,
            "already ends\n"
        )
    }

    func testCRLFAndCRAreNormalizedInBodyAndName() {
        let seed = NewDocumentSeed.make(fromSelection: "Title here\r\nwindows line\rmac line")
        XCTAssertEqual(seed.baseName, "Title here")
        XCTAssertEqual(seed.content, "Title here\nwindows line\nmac line\n")
        XCTAssertFalse(seed.content.contains("\r"))
    }

    func testEmptySelectionFallsBackToUntitledWithEmptyBody() {
        let seed = NewDocumentSeed.make(fromSelection: "")
        XCTAssertEqual(seed.baseName, FilenamePolicy.fallback)
        XCTAssertEqual(seed.content, "")
    }

    func testWhitespaceOnlySelectionFallsBackToUntitled() {
        // Whitespace-only body still normalizes/terminates, but the name has no
        // usable title line, so it falls back to "Untitled".
        let seed = NewDocumentSeed.make(fromSelection: "   \n\t\n")
        XCTAssertEqual(seed.baseName, FilenamePolicy.fallback)
    }

    func testNameIsSanitizedForTheFilesystem() {
        // Path/volume separators become dashes via FilenamePolicy — the seam
        // never emits a name that could escape its directory.
        XCTAssertEqual(NewDocumentSeed.make(fromSelection: "a/b:c").baseName, "a-b-c")
        // International titles survive intact.
        XCTAssertEqual(NewDocumentSeed.make(fromSelection: "会議メモ\n本文").baseName, "会議メモ")
    }

    func testLongFirstLineIsCappedToATidyTitleLength() {
        let long = String(repeating: "x", count: 200)
        let seed = NewDocumentSeed.make(fromSelection: long)
        XCTAssertEqual(seed.baseName.count, NewDocumentSeed.maxTitleCharacters)
        // The full text still lands in the body — only the name is capped.
        XCTAssertEqual(seed.content, long + "\n")
    }

    func testTitleCapDoesNotSplitGraphemeClusters() {
        // A run of emoji past the cap must truncate on a cluster boundary, never
        // mid-scalar.
        let seed = NewDocumentSeed.make(fromSelection: String(repeating: "👨‍👩‍👧‍👦", count: 40))
        XCTAssertLessThanOrEqual(seed.baseName.count, NewDocumentSeed.maxTitleCharacters)
        XCTAssertFalse(seed.baseName.unicodeScalars.contains("\u{FFFD}"))
    }
}
