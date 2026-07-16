import XCTest
@testable import QuoinCore

/// Accept/reject byte semantics + RDFM endmatter metadata (suggestions
/// design, S2). Resolution is exact bytes — no whitespace normalization —
/// verified against the CriticMarkup toolkit consensus table.
final class SuggestionResolutionTests: XCTestCase {

    private func resolved(_ source: String, action: SuggestionResolver.Action) -> String {
        let document = MarkdownConverter.parse(source)
        let marks = SuggestionResolver.marks(in: document)
        var result = source
        // Right-to-left so earlier offsets stay valid.
        for mark in marks.reversed() {
            guard let edit = SuggestionResolver.edit(
                resolving: mark.range, in: result, action: action) else { continue }
            var bytes = Array(result.utf8)
            bytes.replaceSubrange(
                edit.range.offset..<(edit.range.offset + edit.range.length),
                with: Array(edit.replacement.utf8))
            result = String(decoding: bytes, as: UTF8.self)
        }
        return result
    }

    // MARK: - Byte semantics (the consensus table)

    func testAcceptSemantics() {
        XCTAssertEqual(resolved("A{++ new++} text.\n", action: .accept), "A new text.\n")
        XCTAssertEqual(resolved("A{-- old--} text.\n", action: .accept), "A text.\n")
        XCTAssertEqual(resolved("We {~~cannot~>can~~} go.\n", action: .accept), "We can go.\n")
        XCTAssertEqual(resolved("X {>>note<<} y.\n", action: .accept), "X  y.\n",
                       "comments are annotations: removed, bytes otherwise exact")
        XCTAssertEqual(resolved("X {==flag==} y.\n", action: .accept), "X flag y.\n",
                       "highlights unwrap — the text was never in question")
    }

    func testRejectSemantics() {
        XCTAssertEqual(resolved("A{++ new++} text.\n", action: .reject), "A text.\n")
        XCTAssertEqual(resolved("A{-- old--} text.\n", action: .reject), "A old text.\n")
        XCTAssertEqual(resolved("We {~~cannot~>can~~} go.\n", action: .reject), "We cannot go.\n")
        XCTAssertEqual(resolved("X {>>note<<} y.\n", action: .reject), "X  y.\n")
        XCTAssertEqual(resolved("X {==flag==} y.\n", action: .reject), "X flag y.\n")
    }

    func testResolutionRemovesTheIdReference() {
        XCTAssertEqual(resolved("A {++change++}{#s1} here.\n", action: .accept),
                       "A change here.\n",
                       "the {#id} is part of the mark's range and goes with it")
    }

    func testStaleRangeRefusesInsteadOfSplicingBlind() {
        let source = "A {++change++} here.\n"
        let document = MarkdownConverter.parse(source)
        let mark = SuggestionResolver.marks(in: document)[0]
        // The document changed since the projection: bytes at that range are
        // no longer exactly one whole mark.
        let drifted = "AB {++change++} here.\n"
        XCTAssertNil(SuggestionResolver.edit(resolving: mark.range, in: drifted, action: .accept))
    }

    func testMarksWalkFindsNestedContainers() {
        let source = "> Quoted {++insert++} text.\n\n- item with {--strike--}\n"
        let document = MarkdownConverter.parse(source)
        XCTAssertEqual(SuggestionResolver.marks(in: document).count, 2)
    }

    // MARK: - RDFM endmatter

    private let endmatterDoc = """
    # Doc

    Please revisit {==this==}{>>Needs a source.<<}{#c1} soon.

    A tracked {++change++}{#s1} too.

    ---
    comments:
      c1: { by: user, at: "2026-04-28T12:00:00Z" }
      c2:
        body: "I can add one from the intro."
        by: AI
        at: "2026-04-28T12:05:00Z"
        re: c1
    suggestions:
      s1: { by: AI, at: "2026-04-28T12:01:00Z" }

    """

    func testEndmatterParsesAndAttachesMetadata() throws {
        let document = MarkdownConverter.parse(endmatterDoc)
        let metadata = try XCTUnwrap(document.reviewMetadata)
        XCTAssertEqual(metadata.comments["c1"]?.by, "user")
        XCTAssertEqual(metadata.comments["c2"]?.re, "c1")
        XCTAssertEqual(metadata.comments["c2"]?.body, "I can add one from the intro.")
        XCTAssertEqual(metadata.suggestions["s1"]?.by, "AI")
        XCTAssertEqual(metadata.suggestions["s1"]?.at, "2026-04-28T12:01:00Z")

        // The endmatter renders as its own chip block, and the body's marks
        // still parse (the endmatter never reaches cmark).
        XCTAssertTrue(document.blocks.contains {
            if case .reviewEndmatter = $0.kind { return true }
            return false
        })
        XCTAssertEqual(document.stats.suggestionCount, 3)
        // Byte-lossless: the source is untouched.
        XCTAssertEqual(document.source, endmatterDoc)
    }

    func testEndmatterBlockRangeCoversTheTail() throws {
        let document = MarkdownConverter.parse(endmatterDoc)
        let block = try XCTUnwrap(document.blocks.first {
            if case .reviewEndmatter = $0.kind { return true }
            return false
        })
        let bytes = Array(endmatterDoc.utf8)
        let slice = String(decoding: bytes[block.range.offset...], as: UTF8.self)
        XCTAssertTrue(slice.hasPrefix("\n---\n"), "the range includes the delimiter")
        XCTAssertEqual(block.range.offset + block.range.length, bytes.count)
    }

    func testOrdinaryTrailingHRuleIsNotEndmatter() {
        // No {#id} in the body, no document-level comment → a plain hrule +
        // list stays ordinary content.
        let document = MarkdownConverter.parse("Body text.\n\n---\ncomments below are prose\n")
        XCTAssertNil(document.reviewMetadata)
        // And a document that merely ENDS with a thematic break.
        XCTAssertNil(MarkdownConverter.parse("Text.\n\n---\n").reviewMetadata)
    }

    func testDocumentLevelCommentNeedsNoBodyReference() throws {
        let source = "Just prose.\n\n---\ncomments:\n  c1:\n    body: \"Overall: tighten the intro.\"\n    by: AI\n"
        let metadata = try XCTUnwrap(MarkdownConverter.parse(source).reviewMetadata)
        XCTAssertEqual(metadata.comments["c1"]?.body, "Overall: tighten the intro.")
    }
}

// MARK: - Endmatter maintenance (redlined 2026-07-14: the YAML-leak bug)

extension SuggestionResolutionTests {

    private var maintained: String {
        """
        Body {++alpha++}{#s1} and {>>note<<}{#c1} here.

        ---
        comments:
          c1: { by: user, at: "2026-04-28T12:00:00Z" }
          c2:
            body: "A reply."
            by: AI
            re: c1
        suggestions:
          s1: { by: AI, at: "2026-04-28T12:01:00Z" }

        """
    }

    private func applying(_ edit: SourceEdit, to source: String) -> String {
        var bytes = Array(source.utf8)
        bytes.replaceSubrange(
            edit.range.offset..<(edit.range.offset + edit.range.length),
            with: Array(edit.replacement.utf8))
        return String(decoding: bytes, as: UTF8.self)
    }

    func testResolvingRemovesTheEntryAndKeepsOthersByteExact() throws {
        let edit = try XCTUnwrap(ReviewEndmatter.maintenanceEdit(afterResolving: "s1", in: maintained))
        let after = applying(edit, to: maintained)
        XCTAssertFalse(after.contains("s1:"))
        XCTAssertFalse(after.contains("suggestions:"), "emptied section header goes too")
        XCTAssertTrue(after.contains("c1: { by: user, at: \"2026-04-28T12:00:00Z\" }"),
                      "surviving entries keep their original lines byte-exactly")
        XCTAssertTrue(after.contains("body: \"A reply.\""))
        // The endmatter still detects afterward (c1's ref remains in body).
        XCTAssertNotNil(MarkdownConverter.parse(after).reviewMetadata)
    }

    func testResolvingRemovesReplyThreadTransitively() throws {
        let edit = try XCTUnwrap(ReviewEndmatter.maintenanceEdit(afterResolving: "c1", in: maintained))
        let after = applying(edit, to: maintained)
        XCTAssertFalse(after.contains("c1:"))
        XCTAssertFalse(after.contains("A reply."), "re: c1 goes with its parent")
        XCTAssertTrue(after.contains("s1:"), "unrelated entries survive")
    }

    func testResolvingTheLastEntryRemovesTheWholeEndmatter() throws {
        // The live bug: after dismissing the only referenced comment, the
        // orphaned endmatter leaked into the prose as a YAML paragraph.
        let source = """
        Body {>>only note<<}{#c1} here.

        ---
        comments:
          c1: { by: user, at: "2026-04-28T12:00:00Z" }

        """
        let edit = try XCTUnwrap(ReviewEndmatter.maintenanceEdit(afterResolving: "c1", in: source))
        let after = applying(edit, to: source)
        XCTAssertFalse(after.contains("---"))
        XCTAssertFalse(after.contains("comments:"), "no YAML soup left behind")
        XCTAssertTrue(after.hasPrefix("Body"))
    }

    func testMarkWithoutIdLeavesEndmatterAlone() throws {
        let source = "Body {++plain++} here.\n\n---\ncomments:\n  c1: { by: user }\n"
        XCTAssertNil(ReviewEndmatter.maintenanceEdit(afterResolving: "nope", in: source))
    }
}

// MARK: - Resolution records (history — "acted-on things just disappear")

extension SuggestionResolutionTests {

    func testResolutionRecordKeepsTheEntryWithStatusAndSummary() throws {
        let edit = try XCTUnwrap(ReviewEndmatter.resolutionRecordEdit(
            resolving: "s1", summary: "accepted · alpha", in: maintained))
        let after = applying(edit, to: maintained)
        // The flow-form entry normalizes to block form and gains the record.
        XCTAssertTrue(after.contains("  s1:"))
        XCTAssertTrue(after.contains("    by: AI"))
        XCTAssertTrue(after.contains("    status: resolved"))
        XCTAssertTrue(after.contains("    resolved: \"accepted · alpha\""))
        // Other entries keep their original lines byte-exactly.
        XCTAssertTrue(after.contains("c1: { by: user, at: \"2026-04-28T12:00:00Z\" }"))
        XCTAssertTrue(after.contains("body: \"A reply.\""))
        // The entry reads back with the record fields. (It does NOT show
        // as history yet — the mark is still live in this test, and the
        // mark wins; combinedResolutionEdit's test covers the full flow.)
        let metadata = try XCTUnwrap(MarkdownConverter.parse(after).reviewMetadata)
        XCTAssertEqual(metadata.suggestions["s1"]?.status, "resolved")
        XCTAssertEqual(metadata.suggestions["s1"]?.resolved, "accepted · alpha")
        XCTAssertEqual(metadata.suggestions["s1"]?.by, "AI")
        XCTAssertTrue(ReviewEndmatter.resolvedRecords(in: MarkdownConverter.parse(after)).isEmpty)
    }

    func testEndmatterSurvivesResolvingTheLastReferencedMark() throws {
        // The history version of the YAML-leak scenario: record the only
        // comment's resolution, remove its mark — the endmatter must STAY
        // recognized (records keep it alive) instead of leaking into prose.
        let source = """
        Body {>>only note<<}{#c1} here.

        ---
        comments:
          c1: { by: user, at: "2026-04-28T12:00:00Z" }

        """
        let record = try XCTUnwrap(ReviewEndmatter.resolutionRecordEdit(
            resolving: "c1", summary: "dismissed · only note", in: source))
        var after = applying(record, to: source)
        // Now remove the mark itself (what resolveSuggestion does second).
        let document = MarkdownConverter.parse(after)
        let mark = SuggestionResolver.marks(in: document)[0]
        let markEdit = try XCTUnwrap(SuggestionResolver.edit(
            resolving: mark.range, in: after, action: .accept))
        after = applying(markEdit, to: after)

        let final = MarkdownConverter.parse(after)
        XCTAssertNotNil(final.reviewMetadata, "records keep the endmatter recognized")
        XCTAssertEqual(ReviewEndmatter.resolvedRecords(in: final).count, 1)
        XCTAssertFalse(after.contains("{>>"), "the mark itself is gone")
        XCTAssertEqual(SuggestionResolver.marks(in: final).count, 0)
    }

    func testReResolutionReplacesAStaleRecord() throws {
        let source = """
        Body {++x++}{#s1}.

        ---
        suggestions:
          s1:
            by: AI
            status: resolved
            resolved: "stale"

        """
        let edit = try XCTUnwrap(ReviewEndmatter.resolutionRecordEdit(
            resolving: "s1", summary: "accepted · x", in: source))
        let after = applying(edit, to: source)
        XCTAssertFalse(after.contains("stale"))
        XCTAssertTrue(after.contains("resolved: \"accepted · x\""))
        XCTAssertEqual(after.components(separatedBy: "status: resolved").count - 1, 1,
                       "exactly one status line")
    }

    func testResolutionSummaries() throws {
        let source = "A {~~old~>new~~} b {>>note<<} c.\n"
        let document = MarkdownConverter.parse(source)
        let marks = SuggestionResolver.marks(in: document)
        XCTAssertEqual(SuggestionResolver.resolutionSummary(
            at: marks[0].range, in: source, action: .accept), "accepted · old → new")
        XCTAssertEqual(SuggestionResolver.resolutionSummary(
            at: marks[0].range, in: source, action: .reject), "rejected · kept old over new")
        XCTAssertEqual(SuggestionResolver.resolutionSummary(
            at: marks[1].range, in: source, action: .accept), "dismissed · note")
    }
}

// MARK: - Atomic resolution (the one-undo chimera, live screenshot 2026-07-14)

extension SuggestionResolutionTests {

    func testCombinedResolutionIsOneEditAndOneUndoRestoresEverything() throws {
        let source = maintained
        let document = MarkdownConverter.parse(source)
        let mark = SuggestionResolver.marks(in: document).first {
            if case .insertion = $0.kind { return true }
            return false
        }!
        let edit = try XCTUnwrap(SuggestionResolver.combinedResolutionEdit(
            resolving: mark.range, in: source, action: .accept))

        // Applying the ONE edit does both things…
        let after = applying(edit, to: source)
        XCTAssertFalse(after.contains("{++alpha++}"), "mark resolved")
        XCTAssertTrue(after.contains("alpha"), "accepted text stays")
        XCTAssertTrue(after.contains("status: resolved"), "…and the record landed")
        XCTAssertEqual(ReviewEndmatter.resolvedRecords(in: MarkdownConverter.parse(after)).count, 1)

        // …and the inverse single splice restores the original byte-exactly
        // (what the session's undo stack stores).
        let bytes = Array(source.utf8)
        let original = String(decoding: bytes[
            edit.range.offset..<(edit.range.offset + edit.range.length)], as: UTF8.self)
        let inverse = SourceEdit(
            range: ByteRange(offset: edit.range.offset, length: edit.replacement.utf8.count),
            replacement: original)
        XCTAssertEqual(applying(inverse, to: after), source, "one ⌘Z = full restore")
    }

    func testMarkWinsOverStaleResolvedMetadata() throws {
        // The chimera state (mark present + record says resolved): the mark
        // must stay actionable and its record must NOT show as history.
        let chimera = """
        Body {++alpha++}{#s1} here.

        ---
        suggestions:
          s1:
            by: AI
            status: resolved
            resolved: "accepted · alpha"

        """
        let document = MarkdownConverter.parse(chimera)
        let items = SuggestionResolver.reviewItems(in: document)
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].isResolved, "live mark is actionable — mark wins")
        XCTAssertTrue(ReviewEndmatter.resolvedRecords(in: document).isEmpty,
                      "a record whose mark still lives isn't history yet")
    }
}

// MARK: - Session-level atomicity (reported: two undos per resolution)

extension SuggestionResolutionTests {
    func testOneUndoRestoresAResolutionThroughTheRealSession() async throws {
        let source = maintained
        let session = DocumentSession(source: source, fileURL: nil)
        let document = MarkdownConverter.parse(source)
        let mark = SuggestionResolver.marks(in: document).first {
            if case .insertion = $0.kind { return true }
            return false
        }!
        let edit = try XCTUnwrap(SuggestionResolver.combinedResolutionEdit(
            resolving: mark.range, in: source, action: .accept))

        let resolved = try await session.applyEdit(edit, baseRevision: nil)
        XCTAssertFalse(resolved.source.contains("{++alpha++}"))
        XCTAssertTrue(resolved.source.contains("status: resolved"))

        let restored = try await session.undo()
        XCTAssertEqual(restored?.source, source,
                       "ONE undo must restore prose AND metadata — they are one edit")
        // And nothing further to undo: it was ONE stack entry.
        let empty = try await session.undo()
        XCTAssertNil(empty, "exactly one undo entry per resolution")
    }
}

// MARK: - LOW-severity panel findings (grammar, escaping, collisions)

extension SuggestionResolutionTests {

    func testIdMustStartWithALetter() {
        // Spec grammar: ALPHA *( ALPHA / DIGIT / "_" / "-" ). `{#1abc}` is
        // literal prose a reference reader keeps — absorbing it into the
        // mark made resolution delete those bytes.
        let source = "A {++y++}{#1abc} here.\n"
        let mark = SuggestionResolver.marks(in: MarkdownConverter.parse(source))[0]
        XCTAssertNil(mark.id)
        let edit = SuggestionResolver.edit(resolving: mark.range, in: source, action: .accept)!
        XCTAssertEqual(applying(edit, to: source), "A y{#1abc} here.\n",
                       "the invalid ref stays as prose, exactly as a reference reader sees it")
        // And a valid one still binds.
        XCTAssertEqual(
            SuggestionResolver.marks(in: MarkdownConverter.parse("A {++y++}{#s1} x.\n"))[0].id, "s1")
    }

    func testFlowValueEndingInEscapedBackslashDoesNotSwallowTheNextField() throws {
        let source = "Body {>>x<<}{#c1} here.\n\n---\ncomments:\n  c1: { by: \"C:\\\\\", at: \"2026-01-01T00:00:00Z\" }\n"
        let metadata = try XCTUnwrap(MarkdownConverter.parse(source).reviewMetadata)
        XCTAssertEqual(metadata.comments["c1"]?.by, "C:\\")
        XCTAssertEqual(metadata.comments["c1"]?.at, "2026-01-01T00:00:00Z",
                       "the field after the escaped backslash survives")
    }

    func testReResolvingAFlowEntryWithStaleRecordWritesNoDuplicateKeys() throws {
        // Flow-form entry already carrying status/resolved (a chimera from
        // an undo): re-resolving must strip the stale pair, not write a
        // second status:/resolved: under the same entry.
        let source = """
        Body {++alpha++}{#s1} here.

        ---
        suggestions:
          s1: { by: AI, status: resolved, resolved: "accepted · old" }

        """
        let mark = SuggestionResolver.marks(in: MarkdownConverter.parse(source))[0]
        let edit = try XCTUnwrap(SuggestionResolver.combinedResolutionEdit(
            resolving: mark.range, in: source, action: .reject))
        let after = applying(edit, to: source)
        XCTAssertEqual(after.components(separatedBy: "status:").count - 1, 1,
                       "exactly one status key: \(after)")
        XCTAssertEqual(after.components(separatedBy: "resolved:").count - 1, 1)
        XCTAssertTrue(after.contains("rejected · alpha"), "the FRESH record wins")
    }

    func testSectionHeaderInsertionIgnoresEntryFieldsNamedLikeSections() throws {
        // An entry with an unknown indent-4 `suggestions:` field must not
        // become the insertion anchor for a synthesized record.
        let source = """
        Body {--x--} here {>>keep<<}{#c1}.

        ---
        comments:
          c1:
            by: user
            suggestions:

        """
        let mark = SuggestionResolver.marks(in: MarkdownConverter.parse(source)).first {
            if case .deletion = $0.kind { return true }
            return false
        }!
        let edit = try XCTUnwrap(SuggestionResolver.combinedResolutionEdit(
            resolving: mark.range, in: source, action: .accept))
        let after = applying(edit, to: source)
        let metadata = try XCTUnwrap(MarkdownConverter.parse(after).reviewMetadata)
        XCTAssertEqual(metadata.comments["c1"]?.by, "user", "c1 not reparented: \(after)")
        XCTAssertEqual(ReviewEndmatter.resolvedRecords(in: MarkdownConverter.parse(after)).count, 1)
    }

    func testIdCollisionAcrossSectionsAttributesEachCardToItsOwnMap() throws {
        let source = """
        See {>>note<<}{#z1} and {++add++}{#z1}.

        ---
        comments:
          z1: { by: alice }
        suggestions:
          z1: { by: bob }

        """
        let items = SuggestionResolver.reviewItems(in: MarkdownConverter.parse(source))
        XCTAssertEqual(items.count, 2)
        let comment = items.first { !$0.isSuggestion }
        let suggestion = items.first { $0.isSuggestion }
        XCTAssertEqual(comment?.by, "alice")
        XCTAssertEqual(suggestion?.by, "bob", "the suggestion card is bob's, not alice's")
    }
}

// MARK: - CRLF documents (panel review MEDIUM)

extension SuggestionResolutionTests {

    func testCRLFEndmatterIsDetectedAndResolvable() throws {
        // CRLF delimiter + CRLF YAML lines: detection and parsing must
        // both tolerate \r — a pure-LF search rendered the metadata as
        // prose and stacked a second endmatter per resolution.
        let source = "Body {++x++}{#s1} here.\r\n\r\n---\r\nsuggestions:\r\n  s1: { by: AI }\r\n"
        let detected = try XCTUnwrap(ReviewEndmatter.detect(in: source))
        XCTAssertEqual(detected.metadata.suggestions.count, 1)

        let document = MarkdownConverter.parse(source)
        XCTAssertNotNil(document.reviewMetadata, "metadata attached, not prose")
        let mark = try XCTUnwrap(SuggestionResolver.marks(in: document).first)
        let edit = try XCTUnwrap(SuggestionResolver.combinedResolutionEdit(
            resolving: mark.range, in: source, action: .accept))
        let after = applying(edit, to: source)
        XCTAssertFalse(after.contains("{++"))
        XCTAssertEqual(ReviewEndmatter.resolvedRecords(in: MarkdownConverter.parse(after)).count, 1,
                       "one endmatter, one record — no stacking: \(after.debugDescription)")

        // BYTE OUTPUT, not just detection (panel review BLOCKER: the
        // writers normalized CRLF→LF across the whole block, downgrading
        // the untouched delimiter and sibling entries to LF — mixed line
        // endings from a resolution that touched only s1). The endmatter
        // must stay entirely CRLF.
        XCTAssertTrue(after.contains("\r\n---\r\n"), "delimiter stays CRLF")
        XCTAssertTrue(after.contains("\r\n    status: resolved\r\n"), "record lines are CRLF")
        // Every LF in the result is part of a CRLF pair (no lone LF).
        let bytes = Array(after.utf8)
        for (i, b) in bytes.enumerated() where b == UInt8(ascii: "\n") {
            XCTAssertTrue(i > 0 && bytes[i - 1] == UInt8(ascii: "\r"),
                          "lone LF at byte \(i): \(after.debugDescription)")
        }
    }

    func testResolutionPreservesUntouchedCRLFSiblingEntries() throws {
        // The exact blocker repro: resolving s1 must not touch s2's bytes
        // or the delimiter.
        let source = "# T\r\n\r\nA {++a++}{#s1} and {++b++}{#s2}.\r\n\r\n---\r\nsuggestions:\r\n  s1: { by: AI }\r\n  s2: { by: AI }\r\n"
        let mark = try XCTUnwrap(SuggestionResolver.marks(in: MarkdownConverter.parse(source)).first)
        let edit = try XCTUnwrap(SuggestionResolver.combinedResolutionEdit(
            resolving: mark.range, in: source, action: .accept))
        let after = applying(edit, to: source)
        XCTAssertTrue(after.contains("\r\n  s2: { by: AI }\r\n"),
                      "untouched s2 entry keeps its CRLF bytes: \(after.debugDescription)")
        XCTAssertTrue(after.hasPrefix("# T\r\n"), "body stays CRLF")
    }
}

// MARK: - Multi-line mark bodies (panel review HIGH: newline in summary)

extension SuggestionResolutionTests {

    /// A mark body spanning a soft line break is intra-block and fully
    /// supported — its resolution summary must not carry the raw newline
    /// into the quoted YAML scalar, or the strict parser rejects the WHOLE
    /// endmatter and it re-renders as prose (then the next resolution
    /// appends a SECOND endmatter on top).
    func testMultiLineMarkBodyResolvesToDetectableEndmatter() throws {
        let source = "Hello {--old\ntext--} world.\n"
        let document = MarkdownConverter.parse(source)
        let mark = try XCTUnwrap(SuggestionResolver.marks(in: document).first)
        let edit = try XCTUnwrap(SuggestionResolver.combinedResolutionEdit(
            resolving: mark.range, in: source, action: .accept))
        let after = applying(edit, to: source)

        XCTAssertNotNil(ReviewEndmatter.detect(in: after),
                        "endmatter must stay detectable: \(after)")
        let records = ReviewEndmatter.resolvedRecords(in: MarkdownConverter.parse(after))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].summary, "accepted · removed old text",
                       "newline flattened to a space in the summary")

        // And the SECOND resolution appends to the SAME endmatter — no
        // stacked `---` blocks.
        let source2 = after.replacingOccurrences(of: "world.", with: "world {++and\nmore++}.")
        let doc2 = MarkdownConverter.parse(source2)
        let mark2 = try XCTUnwrap(SuggestionResolver.marks(in: doc2).first)
        let edit2 = try XCTUnwrap(SuggestionResolver.combinedResolutionEdit(
            resolving: mark2.range, in: source2, action: .accept))
        let after2 = applying(edit2, to: source2)
        XCTAssertEqual(after2.components(separatedBy: "\n---\n").count, 2,
                       "exactly one endmatter block: \(after2)")
        XCTAssertEqual(ReviewEndmatter.resolvedRecords(in: MarkdownConverter.parse(after2)).count, 2)
    }

    func testMultiLineCommentDismissalStaysDetectable() throws {
        let source = "Body {>>first line\nsecond line<<} here.\n"
        let document = MarkdownConverter.parse(source)
        let mark = try XCTUnwrap(SuggestionResolver.marks(in: document).first)
        let edit = try XCTUnwrap(SuggestionResolver.combinedResolutionEdit(
            resolving: mark.range, in: source, action: .accept))
        let after = applying(edit, to: source)
        XCTAssertNotNil(ReviewEndmatter.detect(in: after))
        XCTAssertEqual(
            ReviewEndmatter.resolvedRecords(in: MarkdownConverter.parse(after)).first?.summary,
            "dismissed · first line second line")
    }
}

// MARK: - Rapid successive resolutions (panel review BLOCKER)

extension SuggestionResolutionTests {

    /// The corruption scenario the panel reproduced: two Accept clicks in
    /// quick succession, both cards' ranges computed from the SAME
    /// pre-resolution projection. The second must REFUSE (mark bytes
    /// drifted), never splice — the old path yielded "A x B {++yy+yy C."
    /// plus a torn, duplicated endmatter, and autosave persisted it.
    func testRapidDoubleResolutionRefusesTheStaleSecondClick() async throws {
        let source = "A {++x++} B {++yy++} C.\n"
        let session = DocumentSession(source: source, fileURL: nil)
        let marks = SuggestionResolver.marks(in: MarkdownConverter.parse(source))
        XCTAssertEqual(marks.count, 2)

        // Both ranges captured from the same stale base — exactly what two
        // quick panel clicks deliver.
        let first = try await session.applyResolution(
            markRange: marks[0].range, action: .accept)
        XCTAssertNotNil(first)
        let second = try await session.applyResolution(
            markRange: marks[1].range, action: .accept)
        XCTAssertNil(second, "stale range must refuse, not splice")

        let after = await session.document.source
        XCTAssertFalse(after.contains("{++yy+yy"), "no mid-mark tearing")
        XCTAssertTrue(after.contains("{++yy++}"), "second mark still intact and actionable")

        // The recovery path: ranges recomputed from the CURRENT document
        // resolve cleanly (the re-rendered panel carries fresh ranges).
        let freshMarks = SuggestionResolver.marks(in: MarkdownConverter.parse(after))
        XCTAssertEqual(freshMarks.count, 1)
        let third = try await session.applyResolution(
            markRange: freshMarks[0].range, action: .accept)
        XCTAssertNotNil(third)
        let final = await session.document.source
        XCTAssertTrue(final.contains("A x B yy C."), "both accepted in the end: \(final)")
    }

    func testBulkResolutionIsNilOnAnnotationOnlyDocuments() async throws {
        let session = DocumentSession(source: "Just {>>a note<<} here.\n", fileURL: nil)
        let result = try await session.applyBulkResolution(action: .accept)
        XCTAssertNil(result, "nothing to resolve — no edit, no undo entry")
        let canUndo = await session.canUndo
        XCTAssertFalse(canUndo)
    }
}

// MARK: - Accept All / Reject All (one atomic edit, panel review)

extension SuggestionResolutionTests {

    private var batch: String {
        """
        One {++alpha++}{#s1} two {--beta--}{#s2} three {~~old~>new~~}{#s3} \
        and {>>a comment<<}{#c1} stays.

        ---
        comments:
          c1: { by: user }
        suggestions:
          s1: { by: AI }
          s2: { by: AI }
          s3: { by: AI }

        """
    }

    func testResolveAllAcceptsEverySuggestionButLeavesComments() throws {
        let edit = try XCTUnwrap(SuggestionResolver.resolveAllEdit(in: batch, action: .accept))
        let after = applying(edit, to: batch)
        XCTAssertTrue(after.contains("One alpha two  three new"),
                      "all three suggestions accepted: \(after)")
        XCTAssertTrue(after.contains("{>>a comment<<}{#c1}"),
                      "comments are annotations — bulk actions leave them")
        let records = ReviewEndmatter.resolvedRecords(in: MarkdownConverter.parse(after))
        XCTAssertEqual(records.count, 3, "every resolution left history")
        XCTAssertTrue(records.allSatisfy { $0.summary.hasPrefix("accepted") })
    }

    func testResolveAllRejectRestoresTheOriginalProse() throws {
        let edit = try XCTUnwrap(SuggestionResolver.resolveAllEdit(in: batch, action: .reject))
        let after = applying(edit, to: batch)
        XCTAssertTrue(after.contains("One  two beta three old"),
                      "all three suggestions rejected: \(after)")
        XCTAssertEqual(
            ReviewEndmatter.resolvedRecords(in: MarkdownConverter.parse(after)).count, 3)
    }

    func testResolveAllIsNilWhenOnlyAnnotationsRemain() {
        XCTAssertNil(SuggestionResolver.resolveAllEdit(
            in: "Just {>>a note<<} and {==a highlight==} here.\n", action: .accept),
            "nothing to resolve → no edit, no phantom undo entry")
    }

    func testResolveAllIsOneUndoThroughTheRealSession() async throws {
        let source = batch
        let session = DocumentSession(source: source, fileURL: nil)
        let edit = try XCTUnwrap(SuggestionResolver.resolveAllEdit(in: source, action: .accept))
        let resolved = try await session.applyEdit(edit, baseRevision: nil)
        XCTAssertFalse(resolved.source.contains("{++"))
        let restored = try await session.undo()
        XCTAssertEqual(restored?.source, source, "ONE undo restores the whole batch")
        let empty = try await session.undo()
        XCTAssertNil(empty, "exactly one undo entry for Accept All")
    }
}

// MARK: - Universal history (the review tab must never vanish)

extension SuggestionResolutionTests {

    func testMarkWithIdButNoEntryStillGetsARecordUnderThatId() throws {
        // The id exists inline but the endmatter never declared it (agent
        // wrote the ref but not the entry, or it was hand-deleted). The
        // resolution must still be recorded — under the mark's OWN id.
        let source = """
        Body {++alpha++}{#s9} here.

        ---
        suggestions:
          s1: { by: AI, status: resolved, resolved: "accepted · old" }

        """
        let edit = try XCTUnwrap(SuggestionResolver.combinedResolutionEdit(
            resolving: ByteRange(offset: 5, length: 16), in: source, action: .accept))
        let after = applying(edit, to: source)
        XCTAssertTrue(after.contains("Body alpha here."))
        let records = ReviewEndmatter.resolvedRecords(in: MarkdownConverter.parse(after))
        XCTAssertEqual(records.count, 2, "history recorded, not skipped: \(after)")
        XCTAssertTrue(records.contains { $0.id == "s9" }, "under the mark's own id")
    }

    func testIdMarkWithNoEndmatterAtAllGetsARecordUnderItsId() throws {
        let source = "Body {++alpha++}{#s7} here.\n"
        let edit = try XCTUnwrap(SuggestionResolver.combinedResolutionEdit(
            resolving: ByteRange(offset: 5, length: 16), in: source, action: .reject))
        let after = applying(edit, to: source)
        let records = ReviewEndmatter.resolvedRecords(in: MarkdownConverter.parse(after))
        XCTAssertEqual(records.first?.id, "s7")
        XCTAssertEqual(records.first?.summary, "rejected · alpha")
    }

    func testIdlessMarkResolutionCreatesEndmatterAndRecord() throws {
        // Plain CriticMarkup, no ids, no endmatter — resolving must still
        // leave history (and thus keep the Review panel alive).
        let source = "We {~~cannot~>can~~} ship.\n"
        let document = MarkdownConverter.parse(source)
        let mark = SuggestionResolver.marks(in: document)[0]
        let edit = try XCTUnwrap(SuggestionResolver.combinedResolutionEdit(
            resolving: mark.range, in: source, action: .accept))
        let after = applying(edit, to: source)

        XCTAssertTrue(after.hasPrefix("We can ship."), "resolution applied")
        let final = MarkdownConverter.parse(after)
        let records = ReviewEndmatter.resolvedRecords(in: final)
        XCTAssertEqual(records.count, 1, "endmatter synthesized to carry the record")
        XCTAssertEqual(records[0].id, "s1")
        XCTAssertEqual(records[0].summary, "accepted · cannot → can")
    }

    func testIdlessMarkWithExistingEndmatterGetsAFreshId() throws {
        let source = """
        A {++x++} b {>>note<<}{#c1}.

        ---
        comments:
          c1: { by: user }

        """
        let document = MarkdownConverter.parse(source)
        let idless = SuggestionResolver.marks(in: document).first {
            if case .insertion = $0.kind { return true }
            return false
        }!
        let edit = try XCTUnwrap(SuggestionResolver.combinedResolutionEdit(
            resolving: idless.range, in: source, action: .reject))
        let after = applying(edit, to: source)
        let final = MarkdownConverter.parse(after)
        let records = ReviewEndmatter.resolvedRecords(in: final)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, "s1", "fresh suggestions counter")
        XCTAssertEqual(final.reviewMetadata?.comments["c1"]?.by, "user",
                       "existing entries untouched")
    }
}
