import XCTest
@testable import QuoinCore

/// Front-matter field surgery (Properties inspector, #70): byte-exact
/// reads, one-line writers with self-calibration, and the session-level
/// apply path. Untouched lines must survive every edit byte-identically.
final class FrontMatterEditingTests: XCTestCase {

    private let doc = """
    ---
    title: Test Doc
    tags:
      - alpha
      - beta
    date: 2026-07-14
    quoted: "a: b"
    ---

    # Heading

    Body text.
    """

    private func applying(_ edit: SourceEdit, to source: String) -> String {
        (try! edit.apply(to: source)).result
    }

    // MARK: - Reading

    func testFieldsParseKeysValuesAndRanges() throws {
        let fields = FrontMatterEditing.fields(in: doc)
        XCTAssertEqual(fields.map(\.key), ["title", "tags", "date", "quoted"])

        let title = fields[0]
        XCTAssertEqual(title.value, "Test Doc")
        XCTAssertFalse(title.isComplex)
        XCTAssertEqual(doc.substring(in: title.byteRange), "title: Test Doc\n",
                       "a field's range is exactly its line, newline included")

        let quoted = fields[3]
        XCTAssertEqual(quoted.value, "a: b", "double-quoted scalars read back unquoted")
    }

    func testNestedFieldIsComplexAndCoversItsContinuationLines() throws {
        let tags = try XCTUnwrap(FrontMatterEditing.fields(in: doc).first { $0.key == "tags" })
        XCTAssertTrue(tags.isComplex)
        XCTAssertEqual(doc.substring(in: tags.byteRange), "tags:\n  - alpha\n  - beta\n")
        XCTAssertEqual(tags.rawPreview, "- alpha\n- beta")
    }

    func testFlowCollectionsAndBlockScalarsAreComplex() {
        let source = "---\ntags: [a, b]\nnotes: |\n  first\n  second\n---\nBody.\n"
        let fields = FrontMatterEditing.fields(in: source)
        XCTAssertEqual(fields.count, 2)
        XCTAssertTrue(fields.allSatisfy(\.isComplex),
                      "one-line flow collections are not one-line SCALARS")
    }

    func testNoFrontMatterMeansNoFields() {
        XCTAssertTrue(FrontMatterEditing.fields(in: "# Just a doc\n").isEmpty)
        XCTAssertTrue(FrontMatterEditing.fields(in: "---\nunterminated\n").isEmpty)
        XCTAssertTrue(FrontMatterEditing.fields(in: "").isEmpty)
    }

    func testCRLFFrontMatterReadsIdentically() throws {
        let crlf = "---\r\ntitle: CRLF Doc\r\ndraft: true\r\n---\r\nBody.\r\n"
        let fields = FrontMatterEditing.fields(in: crlf)
        XCTAssertEqual(fields.map(\.key), ["title", "draft"])
        XCTAssertEqual(fields[0].value, "CRLF Doc")
        XCTAssertEqual(crlf.substring(in: fields[0].byteRange), "title: CRLF Doc\r\n")
    }

    // MARK: - setFieldEdit

    func testReplaceExistingKeyTouchesOnlyItsLine() throws {
        let edit = try XCTUnwrap(FrontMatterEditing.setFieldEdit(
            key: "title", value: "New Title", in: doc))
        let result = applying(edit, to: doc)
        XCTAssertEqual(result, doc.replacingOccurrences(
            of: "title: Test Doc\n", with: "title: New Title\n"),
            "every other byte survives")
    }

    func testAppendNewKeyBeforeClosingDelimiter() throws {
        let edit = try XCTUnwrap(FrontMatterEditing.setFieldEdit(
            key: "author", value: "Clint", in: doc))
        let result = applying(edit, to: doc)
        XCTAssertTrue(result.contains("quoted: \"a: b\"\nauthor: Clint\n---\n"),
                      "new keys land just above the closing ---")
        XCTAssertEqual(FrontMatterEditing.fields(in: result).last?.key, "author")
    }

    func testCreateWholeBlockWhenDocumentHasNone() throws {
        let body = "# Heading\n\nBody.\n"
        let edit = try XCTUnwrap(FrontMatterEditing.setFieldEdit(
            key: "title", value: "Fresh", in: body))
        XCTAssertEqual(edit.range, ByteRange(offset: 0, length: 0))
        let result = applying(edit, to: body)
        XCTAssertEqual(result, "---\ntitle: Fresh\n---\n" + body,
                       "the body is byte-identical below the new block")
        let parsed = MarkdownConverter.parse(result)
        guard case .frontMatter(let yaml) = parsed.blocks.first?.kind else {
            return XCTFail("the created block must parse as front matter")
        }
        XCTAssertEqual(yaml, "title: Fresh")
    }

    func testValuesNeedingEscapesRoundTrip() throws {
        for value in ["a: b", "quote \" inside", "back\\slash", "#not-a-comment", "[not, a, list]"] {
            let edit = try XCTUnwrap(FrontMatterEditing.setFieldEdit(
                key: "status", value: value, in: doc), "writer refused \(value)")
            let result = applying(edit, to: doc)
            let read = FrontMatterEditing.fields(in: result).first { $0.key == "status" }
            XCTAssertEqual(read?.value, value, "read-back must equal what was set")
            XCTAssertFalse(read?.isComplex ?? true)
        }
    }

    func testMultiLineValueFlattensToOneLine() throws {
        let edit = try XCTUnwrap(FrontMatterEditing.setFieldEdit(
            key: "description", value: "line one\nline two", in: doc))
        let read = FrontMatterEditing.fields(in: applying(edit, to: doc))
            .first { $0.key == "description" }
        XCTAssertEqual(read?.value, "line one line two",
                       "values are one-line scalars by contract")
    }

    func testSetRefusesComplexFieldsAndBadKeys() {
        XCTAssertNil(FrontMatterEditing.setFieldEdit(key: "tags", value: "x", in: doc),
                     "a nested value must not be flattened into a scalar")
        XCTAssertNil(FrontMatterEditing.setFieldEdit(key: "bad key", value: "x", in: doc))
        XCTAssertNil(FrontMatterEditing.setFieldEdit(key: "a:b", value: "x", in: doc))
        XCTAssertNil(FrontMatterEditing.setFieldEdit(key: "", value: "x", in: doc))
    }

    func testSetRefusesDuplicatedKeys() {
        let dup = "---\ntitle: one\ntitle: two\n---\nBody.\n"
        XCTAssertNil(FrontMatterEditing.setFieldEdit(key: "title", value: "x", in: dup),
                     "one contiguous edit can't fix both lines — refuse, don't shadow")
        XCTAssertNil(FrontMatterEditing.removeFieldEdit(key: "title", in: dup))
    }

    func testCRLFWritesKeepTheBlockFlavor() throws {
        let crlf = "---\r\ntitle: Old\r\n---\r\nBody.\r\n"
        let replace = try XCTUnwrap(FrontMatterEditing.setFieldEdit(
            key: "title", value: "New", in: crlf))
        XCTAssertEqual(applying(replace, to: crlf), "---\r\ntitle: New\r\n---\r\nBody.\r\n")
        let append = try XCTUnwrap(FrontMatterEditing.setFieldEdit(
            key: "draft", value: "yes", in: crlf))
        XCTAssertEqual(applying(append, to: crlf),
                       "---\r\ntitle: Old\r\ndraft: yes\r\n---\r\nBody.\r\n")
    }

    // MARK: - removeFieldEdit

    func testRemoveScalarFieldRemovesExactlyItsLine() throws {
        let edit = try XCTUnwrap(FrontMatterEditing.removeFieldEdit(key: "date", in: doc))
        XCTAssertEqual(applying(edit, to: doc),
                       doc.replacingOccurrences(of: "date: 2026-07-14\n", with: ""))
    }

    func testRemoveNestedFieldTakesItsContinuationLines() throws {
        let edit = try XCTUnwrap(FrontMatterEditing.removeFieldEdit(key: "tags", in: doc))
        let result = applying(edit, to: doc)
        XCTAssertFalse(result.contains("- alpha"))
        XCTAssertEqual(FrontMatterEditing.fields(in: result).map(\.key),
                       ["title", "date", "quoted"])
    }

    func testRemovingTheLastFieldRemovesTheWholeBlock() throws {
        let source = "---\ntitle: Solo\n---\n\n# Heading\n"
        let edit = try XCTUnwrap(FrontMatterEditing.removeFieldEdit(key: "title", in: source))
        XCTAssertEqual(applying(edit, to: source), "\n# Heading\n",
                       "an empty --- --- chip is noise; the block goes with its last field")
    }

    func testLastFieldRemovalRefusesWhenBodyWouldBecomeFrontMatter() {
        // The body OPENS with a `---` section of its own: dropping the real
        // block would silently promote that section into metadata.
        let source = "---\ntitle: Solo\n---\n---\nnot: metadata\n---\nBody.\n"
        XCTAssertNil(FrontMatterEditing.removeFieldEdit(key: "title", in: source))
    }

    func testRemoveMissingKeyIsNil() {
        XCTAssertNil(FrontMatterEditing.removeFieldEdit(key: "nope", in: doc))
        XCTAssertNil(FrontMatterEditing.removeFieldEdit(key: "title", in: "# No front matter\n"))
    }

    // MARK: - Converter agreement (one recognizer for the grammar)

    func testCRLFFrontMatterNowParsesAsAFrontMatterBlock() {
        // The old Character-based split never split CRLF lines (`\r\n` is
        // ONE grapheme), so CRLF front matter rendered as a thematic break
        // plus prose — and the editing writers would have disagreed with
        // the converter about where the body starts.
        let crlf = "---\r\ntitle: CRLF\r\n---\r\n\r\n# Heading\r\n"
        let parsed = MarkdownConverter.parse(crlf)
        guard case .frontMatter(let yaml) = parsed.blocks.first?.kind else {
            return XCTFail("CRLF front matter must parse like LF front matter")
        }
        XCTAssertEqual(yaml, "title: CRLF", "yaml reads CRLF-normalized")
        XCTAssertEqual(parsed.outline.first?.title, "Heading")
        XCTAssertEqual(parsed.source, crlf, "round-trip stays byte-lossless")
    }

    func testFieldRangesAgreeWithTheConverterBlockRange() throws {
        let parsed = MarkdownConverter.parse(doc)
        let block = try XCTUnwrap(parsed.blocks.first {
            if case .frontMatter = $0.kind { return true }
            return false
        })
        for field in FrontMatterEditing.fields(in: doc) {
            XCTAssertTrue(field.byteRange.offset >= block.range.offset
                          && field.byteRange.upperBound <= block.range.upperBound,
                          "\(field.key) must sit inside the converter's block range")
        }
    }
}

// MARK: - Session-level apply (one undo per commit, in-actor computation)

final class FrontMatterSessionTests: XCTestCase {

    private let doc = """
    ---
    title: Test Doc
    date: 2026-07-14
    ---

    Body text.
    """

    func testSetReplaceRemoveThroughTheRealSession() async throws {
        let session = DocumentSession(source: doc, fileURL: nil)

        let set = try await session.applyFrontMatterEdit(key: "author", value: "Clint")
        XCTAssertTrue(try XCTUnwrap(set).source.contains("author: Clint\n---"))

        let replaced = try await session.applyFrontMatterEdit(key: "title", value: "Renamed")
        XCTAssertTrue(try XCTUnwrap(replaced).source.contains("title: Renamed\n"))

        let removed = try await session.removeFrontMatterField(key: "date")
        let removedSource = try XCTUnwrap(removed).source
        XCTAssertFalse(removedSource.contains("date:"))
        XCTAssertTrue(removedSource.hasSuffix("\nBody text."),
                      "the body never moves")
    }

    func testCreateBlockThroughTheSession() async throws {
        let session = DocumentSession(source: "Just prose.\n", fileURL: nil)
        let created = try await session.applyFrontMatterEdit(key: "title", value: "Fresh")
        XCTAssertEqual(try XCTUnwrap(created).source, "---\ntitle: Fresh\n---\nJust prose.\n")
        guard case .frontMatter = try XCTUnwrap(created).blocks.first?.kind else {
            return XCTFail("the created block must project as front matter")
        }
    }

    func testOneUndoRestoresAFieldCommit() async throws {
        let session = DocumentSession(source: doc, fileURL: nil)
        _ = try await session.applyFrontMatterEdit(key: "title", value: "Changed")
        let restored = try await session.undo()
        XCTAssertEqual(restored?.source, doc,
                       "ONE undo restores the whole commit — it was one edit")
        let empty = try await session.undo()
        XCTAssertNil(empty, "exactly one undo entry per field commit")
    }

    func testRefusalsReturnNilWithoutTouchingTheDocument() async throws {
        let nested = "---\ntags:\n  - a\n---\nBody.\n"
        let session = DocumentSession(source: nested, fileURL: nil)
        let refusedSet = try await session.applyFrontMatterEdit(key: "tags", value: "x")
        XCTAssertNil(refusedSet, "complex values are read-only")
        let refusedRemove = try await session.removeFrontMatterField(key: "missing")
        XCTAssertNil(refusedRemove)
        let document = await session.document
        XCTAssertEqual(document.source, nested)
        let canUndo = await session.canUndo
        XCTAssertFalse(canUndo, "a refusal must not leave an undo entry")
    }
}
