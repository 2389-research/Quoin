import XCTest
@testable import QuoinCore

/// Typed front-matter values (Properties inspector, #79): type inference,
/// precision-preserving date round trips, flow-list ⇄ CSV projection, and
/// the verbatim typed writer. Byte conservatism is the law throughout — a
/// value that doesn't parse CLEANLY stays a string, and a typed write-back
/// keeps the exact serialization shape the value had.
final class FrontMatterTypingTests: XCTestCase {

    private func inferred(_ key: String, _ raw: String) -> FrontMatterEditing.FieldType {
        FrontMatterEditing.inferredType(key: key, rawValue: raw)
    }

    // MARK: - Inference matrix

    func testDateInferenceByPrecision() {
        XCTAssertEqual(inferred("x", "2026-07-14"), .date(.init(
            hasTime: false, hasSeconds: false, zoneSuffix: "")))
        XCTAssertEqual(inferred("x", "2026-07-15T09:30"), .date(.init(
            hasTime: true, hasSeconds: false, zoneSuffix: "")))
        XCTAssertEqual(inferred("x", "2026-07-15T09:30:00Z"), .date(.init(
            hasTime: true, hasSeconds: true, zoneSuffix: "Z")))
        XCTAssertEqual(inferred("x", "2026-07-15T09:30+05:30"), .date(.init(
            hasTime: true, hasSeconds: false, zoneSuffix: "+05:30")))
        XCTAssertEqual(inferred("x", "2026-07-15T23:59:59-07:00"), .date(.init(
            hasTime: true, hasSeconds: true, zoneSuffix: "-07:00")))
    }

    func testUncleanDatesStayStrings() {
        // Wrong shapes, impossible calendar days, and out-of-range clocks
        // all refuse — a typed editor could not round-trip them.
        for raw in ["2026-7-4", "2026-13-01", "2026-02-30", "2026-07-15T25:00",
                    "2026-07-15T09:60", "2026-07-15 09:30", "2026-07-15T09",
                    "2026-07-15T09:30:00X", "2026-07-15T09:30:00+5:30"] {
            XCTAssertEqual(inferred("x", raw), .string, "\(raw) must stay a string")
        }
        // Undashed digits are a NUMBER, not a botched date.
        XCTAssertEqual(inferred("x", "20260715"), .number)
    }

    func testBoolInferenceIsLowercaseOnly() {
        XCTAssertEqual(inferred("x", "true"), .bool)
        XCTAssertEqual(inferred("x", "false"), .bool)
        for raw in ["True", "FALSE", "yes", "no", "on", "off"] {
            XCTAssertEqual(inferred("draft", raw), .string,
                           "\(raw) must stay a string even under a bool-hinted key")
        }
    }

    func testNumberInference() {
        for raw in ["0", "42", "-3", "3.14", "-0.5", "007"] {
            XCTAssertEqual(inferred("x", raw), .number, "\(raw) must infer as number")
        }
        for raw in ["1.2.3", "1e5", "42abc", ".", "-", "3.", ".5", "0x1F", "1,000"] {
            XCTAssertEqual(inferred("x", raw), .string, "\(raw) must stay a string")
        }
    }

    func testFlowArrayInference() {
        XCTAssertEqual(inferred("x", "[a, b]"), .list)
        XCTAssertEqual(inferred("x", "[]"), .list)
        XCTAssertEqual(inferred("x", "[\"a b\", c]"), .list)
        // Nested collections and quoted commas refuse the list editor.
        XCTAssertEqual(inferred("x", "[a, [b, c]]"), .string)
        XCTAssertEqual(inferred("x", "[\"a, b\", c]"), .string,
                       "a comma inside quotes could never round-trip through CSV")
        XCTAssertEqual(inferred("x", "{a: 1}"), .string)
    }

    func testQuotedScalarsAreDeliberateStrings() {
        // A typed write-back would drop the quotes and change the YAML type.
        XCTAssertEqual(inferred("date", "\"2026-07-14\""), .string)
        XCTAssertEqual(inferred("draft", "'true'"), .string)
        XCTAssertEqual(inferred("count", "\"42\""), .string)
    }

    func testKnownKeyHintsNeverCoerceUncleanValues() {
        XCTAssertEqual(inferred("date", "tomorrow"), .string)
        XCTAssertEqual(inferred("updated", "July 4"), .string)
        XCTAssertEqual(inferred("draft", "maybe"), .string)
        XCTAssertEqual(inferred("tags", "a, b"), .string,
                       "bare CSV without brackets is a plain scalar, not a flow list")
        // Clean values under hinted keys infer like anywhere else.
        XCTAssertEqual(inferred("created", "2026-07-14"), .date(.init(
            hasTime: false, hasSeconds: false, zoneSuffix: "")))
        XCTAssertEqual(inferred("published", "false"), .bool)
        XCTAssertEqual(inferred("tags", "[x]"), .list)
    }

    func testEmptyValueUnderListHintedKeyEditsAsEmptyList() {
        // The one hint with residual effect: an empty tags line edits as
        // an empty CSV list; empty dates/bools would have to fabricate a
        // value the file doesn't contain.
        XCTAssertEqual(inferred("tags", ""), .list)
        XCTAssertEqual(inferred("aliases", ""), .list)
        XCTAssertEqual(inferred("date", ""), .string)
        XCTAssertEqual(inferred("draft", ""), .string)
        XCTAssertEqual(inferred("anything", ""), .string)
    }

    // MARK: - Date round-trip precision

    func testSerializationKeepsExactPrecision() throws {
        for raw in ["2026-07-14", "2026-07-15T09:30", "2026-07-15T09:30:00Z",
                    "2026-07-15T09:30:05+05:30", "0001-01-01"] {
            let parsed = try XCTUnwrap(FrontMatterEditing.parseDate(raw))
            XCTAssertEqual(parsed.serialized, raw, "parse → serialize must be identity")
        }
    }

    func testReplacingWallClockKeepsPrecisionAndSuffix() throws {
        let dateOnly = try XCTUnwrap(FrontMatterEditing.parseDate("2026-07-14"))
        let laterDay = try XCTUnwrap(FrontMatterEditing.parseDate("2026-08-02T10:45:12Z"))
        let laterDate = try XCTUnwrap(laterDay.dateValue)
        XCTAssertEqual(dateOnly.replacingWallClock(laterDate).serialized, "2026-08-02",
                       "a date-only value never gains a time component")

        let zoned = try XCTUnwrap(FrontMatterEditing.parseDate("2026-07-15T09:30:00Z"))
        XCTAssertEqual(zoned.replacingWallClock(laterDate).serialized, "2026-08-02T10:45:12Z",
                       "seconds and the Z suffix ride through a picker change")

        let minutes = try XCTUnwrap(FrontMatterEditing.parseDate("2026-07-15T09:30+02:00"))
        XCTAssertEqual(minutes.replacingWallClock(laterDate).serialized, "2026-08-02T10:45+02:00",
                       "minute precision and the offset suffix are preserved")
    }

    // MARK: - Flow lists ⇄ CSV

    func testFlowListItemsSplitAndUnquote() {
        XCTAssertEqual(FrontMatterEditing.flowListItems("[a, b]"), ["a", "b"])
        XCTAssertEqual(FrontMatterEditing.flowListItems("[ a , b c ]"), ["a", "b c"])
        XCTAssertEqual(FrontMatterEditing.flowListItems("[]"), [])
        XCTAssertEqual(FrontMatterEditing.flowListItems("[ ]"), [])
        XCTAssertEqual(FrontMatterEditing.flowListItems("[\"a b\", 'c d']"), ["a b", "c d"])
        XCTAssertEqual(FrontMatterEditing.flowListItems("[\"quo\\\"te\"]"), ["quo\"te"])
        XCTAssertEqual(FrontMatterEditing.flowListItems("['it''s']"), ["it's"])
    }

    func testFlowListItemsRefusals() {
        for raw in ["[a, [b]]", "[{a: 1}]", "[a,,b]", "[a,]", "[\"a, b\"]",
                    "[\"a\"b]", "[a: b]", "[a#b]", "[\"open]", "not a list", "[a\nb]"] {
            XCTAssertNil(FrontMatterEditing.flowListItems(raw), "\(raw) must refuse")
        }
    }

    func testCSVSplitJoinEdgeCases() {
        XCTAssertEqual(FrontMatterEditing.csvItems("a, b"), ["a", "b"])
        XCTAssertEqual(FrontMatterEditing.csvItems("a,b,  c "), ["a", "b", "c"])
        XCTAssertEqual(FrontMatterEditing.csvItems("a, , b,"), ["a", "b"],
                       "empty entries drop — a trailing comma is not an empty tag")
        XCTAssertEqual(FrontMatterEditing.csvItems(""), [])
        XCTAssertEqual(FrontMatterEditing.csv(fromItems: ["a", "b c"]), "a, b c")
    }

    func testFlowListWriteBackQuotesOnlyUnsafeItems() {
        XCTAssertEqual(FrontMatterEditing.flowList(fromItems: ["a", "b c"]), "[a, b c]")
        XCTAssertEqual(FrontMatterEditing.flowList(fromItems: []), "[]")
        XCTAssertEqual(FrontMatterEditing.flowList(fromItems: ["a:b"]), "[\"a:b\"]",
                       "a bare colon would change YAML meaning — quote it")
        XCTAssertEqual(FrontMatterEditing.flowList(fromItems: ["quo\"te"]), "[\"quo\\\"te\"]")
    }

    func testFlowListCSVRoundTripIsIdentityForCleanLists() throws {
        for raw in ["[a, b]", "[alpha, beta gamma, delta]", "[]"] {
            let items = try XCTUnwrap(FrontMatterEditing.flowListItems(raw))
            let csv = FrontMatterEditing.csv(fromItems: items)
            XCTAssertEqual(
                FrontMatterEditing.flowList(fromItems: FrontMatterEditing.csvItems(csv)), raw,
                "\(raw) must survive the CSV projection unchanged")
        }
    }

    // MARK: - Typed writer

    private let doc = """
    ---
    title: Test Doc
    date: 2026-07-14
    draft: false
    tags: [a, b]
    ---

    Body text.
    """

    private func applying(_ edit: SourceEdit, to source: String) -> String {
        (try! edit.apply(to: source)).result
    }

    func testTypedDateWriteTouchesOnlyItsLine() throws {
        let edit = try XCTUnwrap(FrontMatterEditing.setTypedFieldEdit(
            key: "date", rawValue: "2026-08-01", in: doc))
        XCTAssertEqual(applying(edit, to: doc), doc.replacingOccurrences(
            of: "date: 2026-07-14\n", with: "date: 2026-08-01\n"),
            "every other byte survives")
    }

    func testTypedDatetimeStaysBareWhereTheScalarWriterWouldQuote() throws {
        let edit = try XCTUnwrap(FrontMatterEditing.setTypedFieldEdit(
            key: "updated", rawValue: "2026-07-15T09:30:00Z", in: doc))
        let result = applying(edit, to: doc)
        XCTAssertTrue(result.contains("updated: 2026-07-15T09:30:00Z\n"),
                      "the datetime's `:`s must not attract quotes")
        let read = FrontMatterEditing.fields(in: result).first { $0.key == "updated" }
        XCTAssertEqual(read?.value, "2026-07-15T09:30:00Z")
    }

    func testTypedBoolWrite() throws {
        let edit = try XCTUnwrap(FrontMatterEditing.setTypedFieldEdit(
            key: "draft", rawValue: "true", in: doc))
        XCTAssertEqual(applying(edit, to: doc), doc.replacingOccurrences(
            of: "draft: false\n", with: "draft: true\n"))
    }

    func testTypedListWriteReplacesAFlowListInFlowForm() throws {
        let edit = try XCTUnwrap(FrontMatterEditing.setTypedFieldEdit(
            key: "tags", rawValue: "[a, b, c]", in: doc))
        XCTAssertEqual(applying(edit, to: doc), doc.replacingOccurrences(
            of: "tags: [a, b]\n", with: "tags: [a, b, c]\n"),
            "a flow array keeps flow form")
    }

    func testTypedWriterRefusesBlockCollectionsAndNonTypedValues() {
        let block = "---\ntags:\n  - a\n  - b\n---\nBody.\n"
        XCTAssertNil(FrontMatterEditing.setTypedFieldEdit(
            key: "tags", rawValue: "[a, b]", in: block),
            "a block list is not a flow list — stay read-only")
        XCTAssertNil(FrontMatterEditing.setTypedFieldEdit(
            key: "note", rawValue: "hello", in: doc),
            "plain strings go through the escaping scalar writer")
        XCTAssertNil(FrontMatterEditing.setTypedFieldEdit(
            key: "note", rawValue: "42\nevil: x", in: doc),
            "an embedded newline can never be a typed form")
        XCTAssertNil(FrontMatterEditing.setTypedFieldEdit(
            key: "bad key", rawValue: "42", in: doc))
    }

    func testTypedWriterAppendsAndCreatesBlocks() throws {
        let append = try XCTUnwrap(FrontMatterEditing.setTypedFieldEdit(
            key: "priority", rawValue: "3", in: doc))
        XCTAssertTrue(applying(append, to: doc).contains("tags: [a, b]\npriority: 3\n---\n"),
                      "new keys land just above the closing ---")

        let create = try XCTUnwrap(FrontMatterEditing.setTypedFieldEdit(
            key: "draft", rawValue: "true", in: "Just prose.\n"))
        XCTAssertEqual(applying(create, to: "Just prose.\n"),
                       "---\ndraft: true\n---\nJust prose.\n")
    }

    func testTypedWriteThroughTheRealSessionIsOneUndo() async throws {
        let session = DocumentSession(source: doc, fileURL: nil)
        let set = try await session.applyTypedFrontMatterEdit(
            key: "tags", rawValue: "[a, b, c]")
        XCTAssertTrue(try XCTUnwrap(set).source.contains("tags: [a, b, c]\n"))
        let restored = try await session.undo()
        XCTAssertEqual(restored?.source, doc,
                       "ONE undo restores the whole commit — it was one edit")
        let refused = try await session.applyTypedFrontMatterEdit(
            key: "note", rawValue: "not typed")
        XCTAssertNil(refused)
        let document = await session.document
        XCTAssertEqual(document.source, doc, "a refusal must not touch the document")
    }

    // MARK: - String editor must not coerce YAML type (review MEDIUM)

    func testStringEditorQuotesReservedWordsAndTypedForms() throws {
        let source = "---\nnote: hello\n---\nBody.\n"
        for (typed, _) in [("true", "bool"), ("false", "bool"), ("123", "number"),
                           ("2026-07-15", "date"), ("[a, b]", "list")] {
            let edit = try XCTUnwrap(FrontMatterEditing.setFieldEdit(
                key: "note", value: typed, in: source), "no edit for \(typed)")
            var bytes = Array(source.utf8)
            bytes.replaceSubrange(edit.range.offset..<(edit.range.offset + edit.range.length),
                                  with: Array(edit.replacement.utf8))
            let after = String(decoding: bytes, as: UTF8.self)
            XCTAssertTrue(after.contains("note: \"\(typed)\""),
                          "\(typed) must be quoted to stay a string: \(after.debugDescription)")
            // And it reads back as a STRING, not the coerced type.
            let field = try XCTUnwrap(
                FrontMatterEditing.fields(in: after).first { $0.key == "note" })
            XCTAssertEqual(FrontMatterEditing.inferredType(key: "note", rawValue: field.rawPreview),
                           .string, "\(typed) reads back as a string")
            XCTAssertEqual(field.value, typed, "resolved value is preserved")
        }
    }

    func testStringEditorLeavesOrdinaryStringsBare() throws {
        let source = "---\nnote: hello\n---\nBody.\n"
        let edit = try XCTUnwrap(FrontMatterEditing.setFieldEdit(
            key: "note", value: "a plain sentence", in: source))
        XCTAssertTrue(edit.replacement.contains("note: a plain sentence"),
                      "ordinary strings stay bare: \(edit.replacement)")
    }


    func testQuotedEmptyFlowListItemRefusesTheListEditor() {
        XCTAssertNil(FrontMatterEditing.flowListItems("[\"\", \"a\"]"),
                     "a quoted empty item can't round-trip through CSV — refuse")
        XCTAssertNotNil(FrontMatterEditing.flowListItems("[\"x\", \"a\"]"),
                        "non-empty quoted items are fine")
    }

}
