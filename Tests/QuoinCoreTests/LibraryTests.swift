import XCTest
@testable import QuoinCore

final class LibraryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# Alpha doc\ncontent about quoins".utf8).write(to: root.appendingPathComponent("Alpha.md"))
        try Data("beta".utf8).write(to: root.appendingPathComponent("Beta.markdown"))
        try Data([0xFF, 0x00]).write(to: root.appendingPathComponent("photo.png"))
        let sub = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("# Gamma\nletterpress notes".utf8).write(to: sub.appendingPathComponent("Gamma.md"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testScanOrdersFoldersDocumentsAssets() {
        let tree = Library.scan(root: root)
        let names = (tree.children ?? []).map(\.name)
        XCTAssertEqual(names, ["Projects", "Alpha", "Beta", "photo.png"])
        XCTAssertEqual(tree.children?[0].kind, .folder)
        XCTAssertEqual(tree.children?[1].kind, .document)
        XCTAssertEqual(tree.children?[3].kind, .asset)
        XCTAssertEqual(tree.documentCount, 3)
    }

    func testMoveIntoFolder() throws {
        let alpha = root.appendingPathComponent("Alpha.md")
        let projects = root.appendingPathComponent("Projects")
        let moved = try Library.move(alpha, into: projects)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: alpha.path))
    }

    func testMoveRefusesOverwrite() throws {
        let projects = root.appendingPathComponent("Projects")
        try Data("existing".utf8).write(to: projects.appendingPathComponent("Alpha.md"))
        XCTAssertThrowsError(try Library.move(root.appendingPathComponent("Alpha.md"), into: projects))
    }

    func testMoveRefusesFolderIntoItself() throws {
        let projects = root.appendingPathComponent("Projects")
        XCTAssertThrowsError(try Library.move(projects, into: projects)) { error in
            guard case Library.LibraryError.selfContainment = error else {
                return XCTFail("expected selfContainment, got \(error)")
            }
        }
        // The subtree is untouched — nothing orphaned.
        XCTAssertTrue(FileManager.default.fileExists(atPath: projects.appendingPathComponent("Gamma.md").path))
    }

    func testMoveRefusesFolderIntoOwnDescendant() throws {
        let projects = root.appendingPathComponent("Projects")
        let descendant = projects.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: descendant, withIntermediateDirectories: true)
        XCTAssertThrowsError(try Library.move(projects, into: descendant)) { error in
            guard case Library.LibraryError.selfContainment = error else {
                return XCTFail("expected selfContainment, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: projects.appendingPathComponent("Gamma.md").path))
    }

    func testMoveAllowsSharedPrefixSibling() throws {
        // "Projects2" is not a descendant of "Projects" despite the string
        // prefix — the path-segment boundary keeps it a legal target.
        let projects = root.appendingPathComponent("Projects")
        let lookalike = root.appendingPathComponent("Projects2")
        try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: true)
        let moved = try Library.move(projects, into: lookalike)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("Gamma.md").path))
    }

    func testRenameWithSilentSuffix() throws {
        let alpha = root.appendingPathComponent("Alpha.md")
        // "Beta" collides with Beta.markdown? No — extension differs (md), so plain rename.
        let renamed = try Library.rename(alpha, to: "Beta")
        XCTAssertEqual(renamed.lastPathComponent, "Beta.md")

        // Now collide with itself: another Alpha.md, rename to Beta → "Beta 2.md".
        let second = root.appendingPathComponent("Alpha.md")
        try Data("again".utf8).write(to: second)
        let suffixed = try Library.rename(second, to: "Beta")
        XCTAssertEqual(suffixed.lastPathComponent, "Beta 2.md")
    }

    func testDuplicateCreatesSuffixedSiblingAndKeepsOriginal() throws {
        let alpha = root.appendingPathComponent("Alpha.md")
        let copy = try Library.duplicate(alpha)
        XCTAssertEqual(copy.lastPathComponent, "Alpha 2.md")
        // Original survives; the copy carries the same bytes.
        XCTAssertTrue(FileManager.default.fileExists(atPath: alpha.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(
            try Data(contentsOf: copy),
            try Data(contentsOf: alpha))
    }

    func testDuplicateWalksPastExistingSuffixes() throws {
        let alpha = root.appendingPathComponent("Alpha.md")
        try Data("dup".utf8).write(to: root.appendingPathComponent("Alpha 2.md"))
        // "Alpha 2.md" is taken, so the next duplicate lands on "Alpha 3.md".
        let copy = try Library.duplicate(alpha)
        XCTAssertEqual(copy.lastPathComponent, "Alpha 3.md")
    }

    func testDuplicateOfACopyChainsSuffixes() throws {
        let alpha = root.appendingPathComponent("Alpha.md")
        let first = try Library.duplicate(alpha)
        XCTAssertEqual(first.lastPathComponent, "Alpha 2.md")
        // Duplicating the copy uses "Alpha 2" as the base → "Alpha 2 2.md",
        // never overwriting the original or the first copy.
        let second = try Library.duplicate(first)
        XCTAssertEqual(second.lastPathComponent, "Alpha 2 2.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testDuplicateFolderCopiesSubtree() throws {
        let projects = root.appendingPathComponent("Projects")
        let copy = try Library.duplicate(projects)
        XCTAssertEqual(copy.lastPathComponent, "Projects 2")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: copy.appendingPathComponent("Gamma.md").path))
    }

    func testUniqueURLAppendsIncrementingSuffix() throws {
        // No collision → the base name is used as-is.
        let free = Library.uniqueURL(baseName: "Notes", extension: "md", in: root)
        XCTAssertEqual(free.lastPathComponent, "Notes.md")

        // With Notes.md and Notes 2.md present, the next free name is "Notes 3".
        try Data("a".utf8).write(to: root.appendingPathComponent("Notes.md"))
        try Data("b".utf8).write(to: root.appendingPathComponent("Notes 2.md"))
        let next = Library.uniqueURL(baseName: "Notes", extension: "md", in: root)
        XCTAssertEqual(next.lastPathComponent, "Notes 3.md")
    }

    func testUniqueURLTreatsExcludedURLAsFree() throws {
        let notes = root.appendingPathComponent("Notes.md")
        try Data("a".utf8).write(to: notes)
        // Excluding the file itself: its own name doesn't count as a collision.
        let same = Library.uniqueURL(baseName: "Notes", extension: "md", in: root, excluding: notes)
        XCTAssertEqual(same, notes)
        // Without the exclusion, the same name collides and gets suffixed.
        let suffixed = Library.uniqueURL(baseName: "Notes", extension: "md", in: root)
        XCTAssertEqual(suffixed.lastPathComponent, "Notes 2.md")
    }

    func testFuzzyScoring() {
        XCTAssertNotNil(QuickOpen.fuzzyScore(query: "gam", candidate: "Gamma"))
        XCTAssertNil(QuickOpen.fuzzyScore(query: "xyz", candidate: "Gamma"))
        // Word-boundary + consecutive beats scattered.
        let strong = QuickOpen.fuzzyScore(query: "al", candidate: "Alpha")!
        let weak = QuickOpen.fuzzyScore(query: "al", candidate: "Gambling hall")!
        XCTAssertGreaterThan(strong, weak)
    }

    func testFuzzyScoringIsDiacriticAndCaseInsensitive() {
        // Titles must match the diacritic-insensitive behavior of content search:
        // "cafe" finds "Café", regardless of case or accent spelling.
        XCTAssertNotNil(QuickOpen.fuzzyScore(query: "cafe", candidate: "Café Notes"))
        XCTAssertNotNil(QuickOpen.fuzzyScore(query: "CAFE", candidate: "café"))
        XCTAssertNotNil(QuickOpen.fuzzyScore(query: "resume", candidate: "Résumé"))
        // Composed (NFC) vs decomposed (NFD) spelling of the same accented name.
        let nfd = "Cafe\u{0301}"                               // Cafe + combining acute
        XCTAssertNotNil(QuickOpen.fuzzyScore(query: "cafe", candidate: nfd))
    }

    func testUniqueURLKeepsNameOnCaseOnlyRename() throws {
        // On a case-insensitive volume, renaming "Bar" to "bar" must not
        // produce "bar 2" — it's the same file. `excluding` identifies it by a
        // case/normalization-folded key, so the original name is returned.
        let bar = root.appendingPathComponent("Bar.md")
        try Data("x".utf8).write(to: bar)
        let renamed = Library.uniqueURL(
            baseName: "bar", extension: "md", in: root, excluding: bar
        )
        XCTAssertEqual(renamed.lastPathComponent, "bar.md")
    }

    func testRenameSanitizesUnsafeTitles() throws {
        let alpha = root.appendingPathComponent("Alpha.md")
        // Path separators and a leading dot would otherwise create an
        // inaccessible or mis-nested file.
        let renamed = try Library.rename(alpha, to: ".a/b:c")
        XCTAssertEqual(renamed.lastPathComponent, "a-b-c.md")
    }

    func testQuickOpenTitleAndContentSearch() {
        let tree = Library.scan(root: root)
        let byTitle = QuickOpen.search(query: "alpha", in: tree)
        XCTAssertEqual(byTitle.first?.title, "Alpha")

        let byContent = QuickOpen.search(query: "letterpress", in: tree)
        XCTAssertEqual(byContent.first?.title, "Gamma")
        XCTAssertTrue(byContent.first?.snippet.contains("letterpress") ?? false)
    }
}
