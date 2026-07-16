import XCTest
@testable import QuoinCore

final class MathScannerTests: XCTestCase {

    func testPlainTextPassesThrough() {
        XCTAssertEqual(MathScanner.scan("no math here"), [.text("no math here")])
    }

    func testSimpleInlineMath() {
        XCTAssertEqual(
            MathScanner.scan("a $x+y$ b"),
            [.text("a "), .inlineMath("x+y"), .text(" b")]
        )
    }

    func testOpenerFollowedBySpaceIsNotMath() {
        XCTAssertEqual(MathScanner.scan("5 $ and 6 $ total"), [.text("5 $ and 6 $ total")])
    }

    func testCloserFollowedByDigitIsNotMath() {
        // "$5 and $10" — the second $ is followed by a digit, so no span.
        XCTAssertEqual(MathScanner.scan("costs $5 and $10"), [.text("costs $5 and $10")])
    }

    func testDisplayMath() {
        XCTAssertEqual(
            MathScanner.scan("$$E = mc^2$$"),
            [.displayMath("E = mc^2")]
        )
    }

    func testDisplayMathMultiline() {
        XCTAssertEqual(
            MathScanner.scan("$$\n\\sum_i x_i\n$$"),
            [.displayMath("\\sum_i x_i")]
        )
    }

    func testEscapedDollarsAreLiteral() {
        XCTAssertEqual(MathScanner.scan("\\$5 plus \\$6"), [.text("\\$5 plus \\$6")])
    }

    func testBackslashBracketDisplayMath() {
        XCTAssertEqual(
            MathScanner.scan("\\[\n\\begin{matrix} a & b \\end{matrix}\n\\]"),
            [.displayMath("\\begin{matrix} a & b \\end{matrix}")]
        )
    }

    func testBackslashParenInlineMath() {
        XCTAssertEqual(
            MathScanner.scan("energy \\(E = mc^2\\) done"),
            [.text("energy "), .inlineMath("E = mc^2"), .text(" done")]
        )
    }

    func testBackslashBracketDelimiterDetected() {
        XCTAssertTrue(MathScanner.containsMathDelimiter("see \\(x\\)"))
        XCTAssertTrue(MathScanner.containsMathDelimiter("\\[ y \\]"))
    }

    func testUnderscoresInsideMath() {
        XCTAssertEqual(
            MathScanner.scan("see $a_b + c_d$ ok"),
            [.text("see "), .inlineMath("a_b + c_d"), .text(" ok")]
        )
    }
}

final class TaskTogglerTests: XCTestCase {

    func testToggleUncheckedToChecked() throws {
        let source = "- [ ] task one\n- [x] task two\n"
        let result = try TaskToggler.toggle(source: source, markerRange: ByteRange(offset: 2, length: 3))
        XCTAssertEqual(result, "- [x] task one\n- [x] task two\n")
    }

    func testToggleCheckedToUnchecked() throws {
        let source = "- [x] done\n"
        let result = try TaskToggler.toggle(source: source, markerRange: ByteRange(offset: 2, length: 3))
        XCTAssertEqual(result, "- [ ] done\n")
    }

    func testOnlyMarkerByteChanges() throws {
        // Byte-precision guarantee: everything but the one marker byte
        // survives untouched, including odd whitespace and unicode.
        let source = "  - [ ]   spaced ☕️ content\t\n\nother — line\n"
        let doc = MarkdownConverter.parse(source)
        guard case .list(let items, _, _) = doc.blocks[0].kind,
              let marker = items[0].taskMarkerRange else {
            return XCTFail("expected task item with marker")
        }
        let result = try TaskToggler.toggle(source: source, markerRange: marker)
        XCTAssertEqual(Array(result.utf8).count, Array(source.utf8).count)
        XCTAssertEqual(result.replacingOccurrences(of: "[x]", with: "[ ]"), source)
    }

    func testMismatchedMarkerRefused() {
        XCTAssertThrowsError(try TaskToggler.toggle(source: "hello world", markerRange: ByteRange(offset: 0, length: 3))) { error in
            XCTAssertEqual(error as? TaskToggleError, .markerMismatch)
        }
    }

    func testOutOfBoundsRefused() {
        XCTAssertThrowsError(try TaskToggler.toggle(source: "- [ ] x", markerRange: ByteRange(offset: 100, length: 3))) { error in
            XCTAssertEqual(error as? TaskToggleError, .invalidRange)
        }
    }

    func testRoundTripThroughParser() throws {
        // Toggle every task in a document; the parser must agree afterwards.
        let source = """
        # Tasks

        - [ ] alpha
        - [x] beta
        - [ ] gamma
        """
        var current = source
        let doc = MarkdownConverter.parse(current)
        guard case .list(let items, _, _) = doc.blocks[1].kind else {
            return XCTFail("expected list")
        }
        for item in items {
            let marker = try XCTUnwrap(item.taskMarkerRange)
            current = try TaskToggler.toggle(source: current, markerRange: marker)
        }
        let after = MarkdownConverter.parse(current)
        XCTAssertEqual(after.stats.taskTotal, 3)
        XCTAssertEqual(after.stats.taskDone, 2) // was 1 done of 3 → toggled all → 2 done
    }
}

final class DocumentSearchTests: XCTestCase {

    func testBasicSearch() {
        let doc = MarkdownConverter.parse("# Alpha\n\nThe alpha and the omega. ALPHA again.")
        let search = DocumentSearch(document: doc)
        let matches = search.matches(for: "alpha")
        XCTAssertEqual(matches.count, 3)
    }

    func testDiacriticInsensitive() {
        let doc = MarkdownConverter.parse("Café culture in Zürich.")
        let search = DocumentSearch(document: doc)
        XCTAssertEqual(search.matches(for: "cafe").count, 1)
        XCTAssertEqual(search.matches(for: "zurich").count, 1)
    }

    func testSearchReachesTablesListsAndCode() {
        let doc = MarkdownConverter.parse("""
        | key | needle |
        |-----|--------|
        | a   | 1      |

        - list needle

        ```
        code needle
        ```
        """)
        let search = DocumentSearch(document: doc)
        XCTAssertEqual(search.matches(for: "needle").count, 3)
    }

    func testEmptyQueryReturnsNothing() {
        let doc = MarkdownConverter.parse("anything")
        XCTAssertTrue(DocumentSearch(document: doc).matches(for: "  ").isEmpty)
    }
}

final class ExporterTests: XCTestCase {

    func testPlainTextExportStripsSyntax() {
        let doc = MarkdownConverter.parse("""
        # Title

        Some **bold** text with [a link](https://x.y).

        - [x] done thing
        - item
        """)
        let text = PlainTextExporter.export(doc)
        XCTAssertTrue(text.contains("Title"))
        XCTAssertTrue(text.contains("Some bold text with a link."))
        XCTAssertTrue(text.contains("[✓] done thing"))
        XCTAssertFalse(text.contains("**"))
        XCTAssertFalse(text.contains("]("))
    }

    func testMarkdownExportNormalizes() {
        let doc = MarkdownConverter.parse("*  messy   list\n*  spacing")
        let md = MarkdownExporter.export(doc)
        XCTAssertTrue(md.contains("- messy   list") || md.contains("* messy"))
    }
}

final class SHA256Tests: XCTestCase {

    func testKnownVectors() {
        // FIPS 180-4 test vectors.
        XCTAssertEqual(
            SHA256Hex.hash(of: ""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            SHA256Hex.hash(of: "abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            SHA256Hex.hash(of: "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    func testPureSwiftFallbackMatchesVectors() {
        // On Apple platforms `hash(of:)` dispatches to CryptoKit, so the
        // Linux fallback needs its own pin against the same FIPS vectors.
        XCTAssertEqual(
            SHA256Hex.pureSwiftHash(of: Array("".utf8)),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            SHA256Hex.pureSwiftHash(of: Array("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}

final class DocumentSessionTests: XCTestCase {

    func testApplyPublishesNewSnapshot() async {
        let session = DocumentSession(source: "# One")
        await session.apply(source: "# Two")
        let doc = await session.document
        XCTAssertEqual(doc.outline.first?.title, "Two")
    }

    func testToggleTaskWritesFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tasks.md")
        try Data("- [ ] pending\n".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        let doc = await session.document
        guard case .list(let items, _, _) = doc.blocks[0].kind,
              let marker = items[0].taskMarkerRange else {
            return XCTFail("expected task item")
        }
        try await session.toggleTask(markerRange: marker)

        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(onDisk, "- [x] pending\n")
        let updated = await session.document
        XCTAssertEqual(updated.stats.taskDone, 1)
    }

    // MARK: - Task toggle re-anchoring after external source shifts (issue #2)

    /// A task inserted *before* the intended one shifts its byte offset. The
    /// toggle must follow the intended task by identity, not flip whatever
    /// marker now sits at the stale offset.
    func testToggleRelocatesAfterInsertionAbove() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tasks.md")
        try Data("- [ ] first\n- [ ] second\n".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        let doc = await session.document
        guard case .list(let items, _, _) = doc.blocks[0].kind,
              let firstMarker = items[0].taskMarkerRange else {
            return XCTFail("expected task list")
        }

        // Another editor inserts a new task ahead of "first"; offsets shift.
        try Data("- [ ] zero\n- [ ] first\n- [ ] second\n".utf8).write(to: file)

        // Toggle using the ORIGINAL offset for "first".
        try await session.toggleTask(markerRange: firstMarker)

        let onDisk = try String(contentsOf: file, encoding: .utf8)
        // "first" is checked; the inserted "zero" and "second" are untouched.
        XCTAssertEqual(onDisk, "- [ ] zero\n- [x] first\n- [ ] second\n")
    }

    /// When the intended task can't be proven present, the toggle is refused
    /// (no wrong-box flip) and the session republishes the fresh disk state.
    func testToggleRefusesWhenIntendedTaskDeleted() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tasks.md")
        try Data("- [ ] first\n- [ ] second\n".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        let doc = await session.document
        guard case .list(let items, _, _) = doc.blocks[0].kind,
              let firstMarker = items[0].taskMarkerRange else {
            return XCTFail("expected task list")
        }

        // "first" is deleted externally; "second" now occupies the old offset.
        try Data("- [ ] second\n".utf8).write(to: file)

        do {
            try await session.toggleTask(markerRange: firstMarker)
            XCTFail("expected taskNotTogglable")
        } catch SessionError.taskNotTogglable {
            // Refused, as intended.
        }

        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(onDisk, "- [ ] second\n", "no marker should have been flipped")
        let updated = await session.document
        XCTAssertEqual(updated.stats.taskTotal, 1, "session republished fresh disk state")
    }

    func testReloadFromDiskPicksUpExternalChange() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("# Before".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        try Data("# After".utf8).write(to: file)
        await session.reloadFromDisk()
        let doc = await session.document
        XCTAssertEqual(doc.outline.first?.title, "After")
    }
}
