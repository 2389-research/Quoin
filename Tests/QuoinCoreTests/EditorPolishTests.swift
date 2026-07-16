import XCTest
@testable import QuoinCore

final class SmartPairsTests: XCTestCase {

    func testAsteriskPairsAtWordStart() {
        let completion = SmartPairs.completion(typing: "*", inText: "hello ", caretUTF16: 6)
        XCTAssertEqual(completion, SmartPairs.Completion(insert: "**", caretOffset: 1))
    }

    func testBacktickPairs() {
        let completion = SmartPairs.completion(typing: "`", inText: "run ", caretUTF16: 4)
        XCTAssertEqual(completion, SmartPairs.Completion(insert: "``", caretOffset: 1))
    }

    func testTypeOverExistingCloser() {
        // Caret sits before the closer that pairing previously inserted.
        let completion = SmartPairs.completion(typing: "*", inText: "**bold**", caretUTF16: 6)
        XCTAssertEqual(completion, SmartPairs.Completion(insert: "", caretOffset: 1))
    }

    func testNoPairGluedOntoWord() {
        // Typing * directly before letters (e.g. fixing emphasis manually).
        XCTAssertNil(SmartPairs.completion(typing: "*", inText: "hello", caretUTF16: 0))
    }

    func testSingleEqualsIsPlainText() {
        XCTAssertNil(SmartPairs.completion(typing: "=", inText: "x ", caretUTF16: 2))
    }

    func testDoubleEqualsCompletes() {
        // First = typed as text; second = completes the pair.
        let completion = SmartPairs.completion(typing: "=", inText: "note =", caretUTF16: 6)
        XCTAssertEqual(completion, SmartPairs.Completion(insert: "===", caretOffset: 1))
    }

    func testSuspendedInsideInlineCode() {
        // Caret inside `code span`
        let text = "see `let x "
        XCTAssertNil(SmartPairs.completion(typing: "*", inText: text, caretUTF16: text.utf16.count))
    }

    func testSuspendedInsideFence() {
        let text = "```swift\nlet a "
        XCTAssertNil(SmartPairs.completion(typing: "$", inText: text, caretUTF16: text.utf16.count))
    }

    func testDollarPairs() {
        let completion = SmartPairs.completion(typing: "$", inText: "math ", caretUTF16: 5)
        XCTAssertEqual(completion, SmartPairs.Completion(insert: "$$", caretOffset: 1))
    }

    // MARK: Wrap-selection

    func testWrapSelectionAsterisk() {
        // "hello world" with "world" selected (offsets 6..<11), type *.
        let wrap = SmartPairs.wrap(typing: "*", selection: "world", inText: "hello world", selectionStartUTF16: 6)
        // *world* — caret parks just before the closing * (offset 6).
        XCTAssertEqual(wrap, SmartPairs.Completion(insert: "*world*", caretOffset: 6))
    }

    func testWrapSelectionEqualsUsesHighlightPair() {
        let wrap = SmartPairs.wrap(typing: "=", selection: "key", inText: "a key b", selectionStartUTF16: 2)
        XCTAssertEqual(wrap, SmartPairs.Completion(insert: "==key==", caretOffset: 5))
    }

    func testWrapSelectionBacktick() {
        let wrap = SmartPairs.wrap(typing: "`", selection: "ls -la", inText: "run ls -la now", selectionStartUTF16: 4)
        XCTAssertEqual(wrap?.insert, "`ls -la`")
    }

    func testWrapSelectionEmptyIsNil() {
        XCTAssertNil(SmartPairs.wrap(typing: "*", selection: "", inText: "hi", selectionStartUTF16: 0))
    }

    func testWrapSelectionAcrossNewlineIsNil() {
        XCTAssertNil(SmartPairs.wrap(typing: "*", selection: "a\nb", inText: "a\nb", selectionStartUTF16: 0))
    }

    func testWrapSelectionNonPairCharIsNil() {
        XCTAssertNil(SmartPairs.wrap(typing: "x", selection: "word", inText: "word", selectionStartUTF16: 0))
    }

    func testWrapSelectionSuspendedInCode() {
        let text = "`let word "
        XCTAssertNil(SmartPairs.wrap(typing: "*", selection: "word", inText: text, selectionStartUTF16: 5))
    }
}

final class FormattingTests: XCTestCase {

    func testWrapBold() {
        let change = Formatting.toggleWrap(selection: "word", delimiter: "**")
        XCTAssertEqual(change.replacement, "**word**")
        XCTAssertEqual(change.selectionOffset, 2)
        XCTAssertEqual(change.selectionLength, 4)
    }

    func testUnwrapBold() {
        let change = Formatting.toggleWrap(selection: "**word**", delimiter: "**")
        XCTAssertEqual(change.replacement, "word")
        XCTAssertEqual(change.selectionLength, 4)
    }

    func testWrapEmptySelection() {
        let change = Formatting.toggleWrap(selection: "", delimiter: "**")
        XCTAssertEqual(change.replacement, "****")
        XCTAssertEqual(change.selectionOffset, 2)
        XCTAssertEqual(change.selectionLength, 0)
    }

    func testHighlightWrap() {
        let change = Formatting.toggleWrap(selection: "key point", delimiter: "==")
        XCTAssertEqual(change.replacement, "==key point==")
    }

    func testHighlightCycleWalksThePalette() {
        // plain → lime → pink → yellow → blue → orange → plain
        var selection = "note"
        var seen: [String] = []
        for _ in 0..<6 {
            let change = Formatting.cycleHighlight(selection: selection)
            seen.append(change.replacement)
            // The whole span stays selected so the next ⇧⌘H keeps cycling.
            XCTAssertEqual(change.selectionOffset, 0)
            XCTAssertEqual(change.selectionLength, change.replacement.utf16.count)
            selection = change.replacement
        }
        XCTAssertEqual(seen, [
            "==note==",
            "=={pink}note==",
            "=={yellow}note==",
            "=={blue}note==",
            "=={orange}note==",
            "note",
        ])
    }

    func testColorTagParsesToPaletteColor() {
        let doc = MarkdownConverter.parse("a =={pink}rosy== b and ==plain== c")
        guard case .paragraph(let inlines) = doc.blocks[0].kind else {
            return XCTFail("expected paragraph")
        }
        XCTAssertTrue(inlines.contains(.highlight([.text("rosy")], .pink)))
        XCTAssertTrue(inlines.contains(.highlight([.text("plain")], .lime)))
        XCTAssertEqual(doc.stats.highlightCount, 2)
    }

    func testUnknownColorTagStaysLiteral() {
        let doc = MarkdownConverter.parse("=={chartreuse}text==")
        guard case .paragraph(let inlines) = doc.blocks[0].kind else {
            return XCTFail("expected paragraph")
        }
        XCTAssertTrue(inlines.contains(.highlight([.text("{chartreuse}text")], .lime)))
    }

    func testMakeLinkSelectsURLPlaceholder() {
        let change = Formatting.makeLink(selection: "Apple")
        XCTAssertEqual(change.replacement, "[Apple](url)")
        // Selection covers "url" so typing replaces it immediately.
        let start = change.replacement.index(change.replacement.startIndex, offsetBy: change.selectionOffset)
        let end = change.replacement.index(start, offsetBy: change.selectionLength)
        XCTAssertEqual(String(change.replacement[start..<end]), "url")
    }

    func testMakeLinkEmptySelection() {
        let change = Formatting.makeLink(selection: "")
        XCTAssertEqual(change.replacement, "[link](url)")
    }

    // MARK: Word-under-caret (⌘B with no selection)

    func testWordRangeMidWord() {
        // "the quick fox", caret at offset 6 (inside "quick").
        let range = Formatting.wordRange(in: "the quick fox", around: 6)
        XCTAssertEqual(range?.offset, 4)
        XCTAssertEqual(range?.length, 5)
    }

    func testWordRangeAtWordEnd() {
        // caret right after "quick" (offset 9) selects "quick" to the left.
        let range = Formatting.wordRange(in: "the quick fox", around: 9)
        XCTAssertEqual(range?.offset, 4)
        XCTAssertEqual(range?.length, 5)
    }

    func testWordRangeOnWhitespaceIsNil() {
        // "a  b" — caret between the two spaces has no adjacent word char.
        XCTAssertNil(Formatting.wordRange(in: "a  b", around: 2))
    }

    func testWordRangeEmptyTextIsNil() {
        XCTAssertNil(Formatting.wordRange(in: "", around: 0))
    }

    func testWordRangeIncludesUnderscore() {
        let range = Formatting.wordRange(in: "call snake_case now", around: 8)
        XCTAssertEqual(range?.offset, 5)
        XCTAssertEqual(range?.length, 10)
    }
}

final class ConflictTests: XCTestCase {

    func testDirtySessionSurfacesConflictInsteadOfReplacing() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("original".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        let conflictArrived = expectation(description: "conflict")
        await session.setConflictHandler { disk in
            XCTAssertEqual(disk, "external change")
            conflictArrived.fulfill()
        }

        // Local unsaved edit (autosave debounce still pending)…
        try await session.applyEdit(SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "local "))
        // …then an external write lands.
        try Data("external change".utf8).write(to: file)
        await session.reloadFromDisk()

        await fulfillment(of: [conflictArrived], timeout: 2)
        // Local content is preserved, not clobbered.
        let current = await session.document
        XCTAssertEqual(current.source, "local original")

        // Taking the disk version adopts it.
        await session.resolveConflictTakingDisk("external change")
        let adopted = await session.document
        XCTAssertEqual(adopted.source, "external change")
    }

    func testKeepMineConflictResolutionKeepsDirtyStateWhenSaveFails() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try Data("original".utf8).write(to: file)

        let session = try DocumentSession.open(fileURL: file)
        try await session.applyEdit(SourceEdit(range: ByteRange(offset: 0, length: 0), replacement: "local "))

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)

        do {
            try await session.resolveConflictKeepingMine()
            XCTFail("conflict resolution should fail when the document URL is a directory")
        } catch SessionError.fileWriteFailed(let url, _) {
            XCTAssertEqual(url, file)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let isDirty = await session.hasUnsavedChanges
        let saveError = await session.lastSaveError
        let source = await session.document.source
        XCTAssertTrue(isDirty)
        XCTAssertNotNil(saveError)
        XCTAssertEqual(source, "local original")
    }
}
