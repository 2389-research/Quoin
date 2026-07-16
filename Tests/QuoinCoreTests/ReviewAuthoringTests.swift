import XCTest
@testable import QuoinCore

/// Creating a review without editing the prose (suggestions §3.6, S3a):
/// every gesture is ONE atomic edit, the prose survives byte-exactly
/// inside the mark, and impossible annotations REFUSE.
final class ReviewAuthoringTests: XCTestCase {

    private let stamp = "2026-07-14T18:00:00Z"

    private func applying(_ edit: SourceEdit, to source: String) -> String {
        var bytes = Array(source.utf8)
        bytes.replaceSubrange(
            edit.range.offset..<(edit.range.offset + edit.range.length),
            with: Array(edit.replacement.utf8))
        return String(decoding: bytes, as: UTF8.self)
    }

    private func range(of text: String, in source: String) -> ByteRange {
        let bytes = Array(source.utf8)
        let needle = Array(text.utf8)
        for start in 0...(bytes.count - needle.count)
        where Array(bytes[start..<(start + needle.count)]) == needle {
            return ByteRange(offset: start, length: needle.count)
        }
        XCTFail("\(text) not in source")
        return ByteRange(offset: 0, length: 0)
    }

    // MARK: - Shapes

    func testDeletionWrapsTheProseByteExactly() throws {
        let source = "The quick brown fox jumps.\n"
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .deletion, range: range(of: "quick ", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
        let after = applying(edit, to: source)
        XCTAssertTrue(after.hasPrefix("The {--quick --}{#s1}brown fox jumps.\n"),
                      "prose unchanged inside the mark: \(after)")
        XCTAssertTrue(after.contains("suggestions:\n  s1:\n    by: clint\n    at: \"\(stamp)\""))

        // The document still SAYS the same thing: rejecting restores bytes.
        let doc = MarkdownConverter.parse(after)
        let mark = try XCTUnwrap(SuggestionResolver.marks(in: doc).first)
        let reject = try XCTUnwrap(SuggestionResolver.edit(
            resolving: mark.range, in: after, action: .reject))
        XCTAssertTrue(applying(reject, to: after).hasPrefix(source.dropLast()),
                      "reject = the original prose, byte-exact")
    }

    func testReplacementAndHighlightAndInsertionShapes() throws {
        let source = "Alpha beta gamma.\n"
        let replace = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .replacement(new: "delta"), range: range(of: "beta", in: source),
            in: source, reviewer: "AI", timestamp: stamp))
        XCTAssertTrue(applying(replace, to: source).contains("{~~beta~>delta~~}{#s1}"))

        let highlight = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .highlight, range: range(of: "gamma", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
        XCTAssertTrue(applying(highlight, to: source).contains("{==gamma==}{#s1}"))

        let insert = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .insertion(text: "really "),
            range: ByteRange(offset: range(of: "beta", in: source).offset, length: 0),
            in: source, reviewer: "clint", timestamp: stamp))
        XCTAssertTrue(applying(insert, to: source).contains("Alpha {++really ++}{#s1}beta"))
    }

    func testAnchoredCommentIsOnePanelCard() throws {
        let source = "Check the numbers here.\n"
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .comment(body: "Source for these?"), range: range(of: "the numbers", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
        let after = applying(edit, to: source)
        XCTAssertTrue(after.contains("{==the numbers==}{>>Source for these?<<}{#c1}"))
        let items = SuggestionResolver.reviewItems(in: MarkdownConverter.parse(after))
        XCTAssertEqual(items.count, 1, "highlight + comment fuse into ONE card")
        guard case .comment(let text, let anchor) = items[0].body else {
            return XCTFail("expected comment card")
        }
        XCTAssertEqual(text, "Source for these?")
        XCTAssertEqual(anchor, "the numbers")
        XCTAssertEqual(items[0].by, "clint")
    }

    func testDocumentLevelCommentIsEndmatterOnly() throws {
        let source = "Just prose.\n"
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .comment(body: "Overall: tighten."), range: ByteRange(offset: 0, length: 0),
            in: source, reviewer: "AI", timestamp: stamp))
        let after = applying(edit, to: source)
        XCTAssertTrue(after.hasPrefix("Just prose.\n"), "prose untouched")
        let metadata = try XCTUnwrap(MarkdownConverter.parse(after).reviewMetadata)
        XCTAssertEqual(metadata.comments["c1"]?.body, "Overall: tighten.")
        XCTAssertEqual(metadata.comments["c1"]?.by, "AI")
    }

    // MARK: - Atomicity + id allocation

    func testAnnotationIsOneUndoThroughTheRealSession() async throws {
        let source = "Alpha beta gamma.\n"
        let session = DocumentSession(source: source, fileURL: nil)
        let result = try await session.applyAnnotation(
            kind: .deletion, range: range(of: "beta ", in: source),
            expectedSlice: "beta ", reviewer: "clint")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.source.contains("{--beta --}{#s1}"))
        let restored = try await session.undo()
        XCTAssertEqual(restored?.source, source, "one ⌘Z removes mark AND entry")
        let empty = try await session.undo()
        XCTAssertNil(empty)
    }

    func testIdsAllocateAcrossExistingMarksAndEntries() throws {
        let source = "One {++x++}{#s1} two three.\n\n---\nsuggestions:\n  s1: { by: AI }\n  s2: { by: AI, status: resolved, resolved: \"accepted · y\" }\n"
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .deletion, range: range(of: "two ", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
        let after = applying(edit, to: source)
        XCTAssertTrue(after.contains("{--two --}{#s3}"), "s1/s2 taken → s3: \(after)")
        XCTAssertEqual(MarkdownConverter.parse(after).reviewMetadata?.suggestions.count, 3)
    }

    // MARK: - Refusals (self-calibration)

    func testSelectionInsideACodeSpanRefuses() {
        let source = "Run `swift build now` first.\n"
        XCTAssertNil(ReviewAuthoring.annotationEdit(
            kind: .deletion, range: range(of: "build", in: source),
            in: source, reviewer: "clint", timestamp: stamp),
            "a mark inside a code span would be literal text — refuse")
    }

    func testBlockSpanningSelectionRefuses() {
        let source = "First paragraph.\n\nSecond paragraph.\n"
        let start = range(of: "paragraph.\n\nSecond", in: source)
        XCTAssertNil(ReviewAuthoring.annotationEdit(
            kind: .deletion, range: start,
            in: source, reviewer: "clint", timestamp: stamp),
            "marks are intra-block in v1 — refuse")
    }

    func testSelectionContainingAClosingSigilRefuses() {
        let source = "Odd text with a --} stray closer.\n"
        XCTAssertNil(ReviewAuthoring.annotationEdit(
            kind: .deletion, range: range(of: "a --} stray", in: source),
            in: source, reviewer: "clint", timestamp: stamp),
            "the early close would detach the id — refuse, never mangle")
    }

    func testSelectionOverAnExistingMarkRefuses() {
        let source = "Keep {++this++}{#s1} mark.\n"
        XCTAssertNil(ReviewAuthoring.annotationEdit(
            kind: .highlight, range: range(of: "{++this++}", in: source),
            in: source, reviewer: "clint", timestamp: stamp),
            "no nested marks in v1")
    }

    func testDriftRefusesThroughTheSession() async throws {
        let source = "Alpha beta gamma.\n"
        let session = DocumentSession(source: source, fileURL: nil)
        // The gesture was made against "beta" but the document changed.
        try await session.applyEdit(SourceEdit(
            range: ByteRange(offset: 0, length: 0), replacement: "X"))
        let result = try await session.applyAnnotation(
            kind: .deletion, range: range(of: "beta", in: source),
            expectedSlice: "beta", reviewer: "clint")
        XCTAssertNil(result, "bytes drifted under the gesture — refuse")
        let current = await session.document.source
        XCTAssertEqual(current, "XAlpha beta gamma.\n", "nothing spliced")
    }

    func testEmptyCommentBodyRefuses() {
        let source = "Some prose.\n"
        XCTAssertNil(ReviewAuthoring.annotationEdit(
            kind: .comment(body: "   \n  "), range: range(of: "prose", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
    }

    func testMultiLineBodyFlattensToOneLine() throws {
        let source = "Some prose here.\n"
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .comment(body: "line one\nline two"), range: range(of: "prose", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
        let after = applying(edit, to: source)
        XCTAssertTrue(after.contains("{>>line one line two<<}"))
        XCTAssertNotNil(ReviewEndmatter.detect(in: after))
    }

    // MARK: - Structure preservation (live report: list renumbered)

    func testCommentWrappingAListMarkerRefuses() throws {
        let source = """
        Intro.

        1. Name the player problem.
        2. Identify the rule IDs.
        3. Update Gameplay.

        Tail.
        """
        // The whole-item selection INCLUDING the "2. " marker: wrapping it
        // erased the marker and restructured the list (renumbering every
        // item) — an annotation must never change document structure.
        XCTAssertNil(ReviewAuthoring.annotationEdit(
            kind: .comment(body: "nice"), range: range(of: "2. Identify the rule IDs.", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
    }

    func testCommentOnItemContentSucceedsAndKeepsTheList() throws {
        let source = """
        Intro.

        1. Name the player problem.
        2. Identify the rule IDs.
        3. Update Gameplay.

        Tail.
        """
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .comment(body: "nice"), range: range(of: "Identify the rule IDs.", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
        let after = applying(edit, to: source)
        let document = MarkdownConverter.parse(after)
        let list = document.blocks.compactMap { block -> Int? in
            if case .list(let items, _, _) = block.kind { return items.count }
            return nil
        }
        XCTAssertEqual(list, [3], "the list survives intact: \(after)")
        XCTAssertEqual(SuggestionResolver.reviewItems(in: document).count, 1)
    }

    func testClampPastLinePrefix() {
        XCTAssertEqual(ReviewAuthoring.clampPastLinePrefix(0, in: "2. Item text"), 3)
        XCTAssertEqual(ReviewAuthoring.clampPastLinePrefix(0, in: "- item"), 2)
        XCTAssertEqual(ReviewAuthoring.clampPastLinePrefix(2, in: "  - [x] task item"), 8)
        XCTAssertEqual(ReviewAuthoring.clampPastLinePrefix(0, in: "> quoted text"), 2)
        XCTAssertEqual(ReviewAuthoring.clampPastLinePrefix(5, in: "plain prose"), 5,
                       "content positions pass through untouched")
        // Second line of a list slice: clamp is line-local.
        let slice = "- one\n- two"
        XCTAssertEqual(ReviewAuthoring.clampPastLinePrefix(6, in: slice), 8)
    }


    // MARK: - Opaque regions (user question: code / tables / diagrams / math)

    func testAnnotatingInsideOpaqueBlocksRefuses() {
        // CriticMarkup is a PROSE format: RDFM's opacity rule means a mark
        // inside code, a table cell, a diagram, or math is literal bytes,
        // not a mark — so creation must refuse, never inject junk into
        // runnable/renderable content.
        let cases: [(String, String)] = [
            ("```swift\nlet total = a + b\n```\n", "total"),
            ("| Name | Value |\n|------|-------|\n| alpha | 1 |\n", "alpha"),
            ("```mermaid\ngraph TD\n  Start --> End\n```\n", "Start"),
            ("$$\nE = mc^2\n$$\n", "mc"),
            ("# A heading with words\n\nBody.\n", "heading"),
        ]
        for (source, target) in cases {
            for kind in [ReviewAuthoring.Kind.deletion,
                         .comment(body: "note"), .highlight] {
                XCTAssertNil(ReviewAuthoring.annotationEdit(
                    kind: kind, range: range(of: target, in: source),
                    in: source, reviewer: "clint", timestamp: stamp),
                    "must refuse \(kind) inside: \(source.prefix(20))")
            }
        }
    }


    // MARK: - Styling survives replacement (live report: **bold** → strong)

    func testReplacingStyledTextKeepsItsDelimiters() throws {
        let source = "Some **bold** words.\n"
        // The model's snap hands annotationEdit the FULL **bold** range.
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .replacement(new: "strong"), range: range(of: "**bold**", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
        let after = applying(edit, to: source)
        XCTAssertTrue(after.contains("{~~**bold**~>**strong**~~}"),
                      "the new half inherits the emphasis: \(after)")

        // Accepting keeps the document bold.
        let mark = try XCTUnwrap(SuggestionResolver.marks(in: MarkdownConverter.parse(after)).first)
        let accept = try XCTUnwrap(SuggestionResolver.edit(
            resolving: mark.range, in: after, action: .accept))
        XCTAssertTrue(applying(accept, to: after).contains("Some **strong** words."))
    }

    func testUnstyledReplacementPassesThrough() {
        XCTAssertEqual(
            ReviewAuthoring.replacementPreservingDelimiters("new", around: "plain old"), "new")
        XCTAssertEqual(
            ReviewAuthoring.replacementPreservingDelimiters("new", around: "**wrapped**"), "**new**")
        XCTAssertEqual(
            ReviewAuthoring.replacementPreservingDelimiters("new", around: "~~struck~~"), "~~new~~")
        XCTAssertEqual(
            ReviewAuthoring.replacementPreservingDelimiters("new", around: "*lop**"), "new",
            "asymmetric wraps pass through")
        XCTAssertEqual(
            ReviewAuthoring.replacementPreservingDelimiters("**already**", around: "**old**"),
            "**already**", "user-typed styling is not double-wrapped")
    }


    // MARK: - Balanced delimiter snap (live report: word at span START tore the bold)

    /// UTF-16 offsets of `text` inside `slice` — the snap's currency.
    private func utf16Range(of text: String, in slice: String) -> (Int, Int) {
        let range = (slice as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, "\(text) not in slice")
        return (range.location, range.location + range.length)
    }

    func testBalancedDelimiterSnapMatrix() {
        let bold = "**Zigbee2MQTT → MQTT Service**"

        // Whole-span content: both delimiter runs captured — snap stands.
        var (start, end) = utf16Range(of: "Zigbee2MQTT → MQTT Service", in: bold)
        XCTAssertEqual(
            ReviewAuthoring.balancedDelimiterSnap(start: start, end: end, in: bold).start, 0)
        XCTAssertEqual(
            ReviewAuthoring.balancedDelimiterSnap(start: start, end: end, in: bold).end,
            (bold as NSString).length)

        // Span START (the screenshot case): only the opener would be
        // captured; the closer lies beyond the selection — revert BOTH.
        (start, end) = utf16Range(of: "Zigbee2MQTT", in: bold)
        var snapped = ReviewAuthoring.balancedDelimiterSnap(start: start, end: end, in: bold)
        XCTAssertEqual(snapped.start, start, "must NOT capture the opening **")
        XCTAssertEqual(snapped.end, end)

        // Span END: mirror image — only the closer would be captured.
        (start, end) = utf16Range(of: "MQTT Service", in: bold)
        snapped = ReviewAuthoring.balancedDelimiterSnap(start: start, end: end, in: bold)
        XCTAssertEqual(snapped.start, start)
        XCTAssertEqual(snapped.end, end, "must NOT capture the closing **")

        // Span MIDDLE: no adjacent delimiters — untouched.
        (start, end) = utf16Range(of: "→ MQTT", in: bold)
        snapped = ReviewAuthoring.balancedDelimiterSnap(start: start, end: end, in: bold)
        XCTAssertEqual(snapped.start, start)
        XCTAssertEqual(snapped.end, end)

        // Plain text: untouched.
        (start, end) = utf16Range(of: "words", in: "plain words here")
        snapped = ReviewAuthoring.balancedDelimiterSnap(
            start: start, end: end, in: "plain words here")
        XCTAssertEqual(snapped.start, start)
        XCTAssertEqual(snapped.end, end)

        // Other symmetric wraps snap; backticks stay excluded.
        (start, end) = utf16Range(of: "struck", in: "~~struck~~")
        snapped = ReviewAuthoring.balancedDelimiterSnap(start: start, end: end, in: "~~struck~~")
        XCTAssertEqual(snapped.start, 0)
        XCTAssertEqual(snapped.end, 10)
        (start, end) = utf16Range(of: "code", in: "see `code` here")
        snapped = ReviewAuthoring.balancedDelimiterSnap(
            start: start, end: end, in: "see `code` here")
        XCTAssertEqual(snapped.start, start, "backticks are never captured")
        XCTAssertEqual(snapped.end, end)

        // Mixed nesting is lopsided as STRINGS (`~~**` vs `**~~`) — revert,
        // same conservative rule replacementPreservingDelimiters applies.
        (start, end) = utf16Range(of: "both", in: "~~**both**~~")
        snapped = ReviewAuthoring.balancedDelimiterSnap(start: start, end: end, in: "~~**both**~~")
        XCTAssertEqual(snapped.start, start)
        XCTAssertEqual(snapped.end, end)

        // A caret at a span edge must stay a caret, never widen to
        // delimiter-only bytes.
        snapped = ReviewAuthoring.balancedDelimiterSnap(start: 8, end: 8, in: "**bold** tail")
        XCTAssertEqual(snapped.start, 8)
        XCTAssertEqual(snapped.end, 8)
    }

    func testReplacementAtBoldSpanStartKeepsTheEmphasisWhole() throws {
        // The exact screenshot case end-to-end: "Zigbee2MQTT" selected at
        // the start of a bold span, replacement suggested. The reverted
        // snap wraps ONLY the word; accepting keeps **…** balanced.
        let source = "Route **Zigbee2MQTT → MQTT Service** traffic.\n"
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .replacement(new: "Z2M"), range: range(of: "Zigbee2MQTT", in: source),
            in: source, reviewer: "clint", timestamp: stamp))
        let after = applying(edit, to: source)
        XCTAssertTrue(after.contains("**{~~Zigbee2MQTT~>Z2M~~}{#s1} → MQTT Service**"),
                      "the mark sits INSIDE the intact span: \(after)")

        let mark = try XCTUnwrap(SuggestionResolver.marks(in: MarkdownConverter.parse(after)).first)
        let accept = try XCTUnwrap(SuggestionResolver.edit(
            resolving: mark.range, in: after, action: .accept))
        XCTAssertTrue(applying(accept, to: after)
            .contains("Route **Z2M → MQTT Service** traffic."),
            "accepting keeps the bold balanced")
    }


    // MARK: - Block-adjacent comments (#68)

    func testBlockCommentLandsAfterACodeBlock() throws {
        let source = "Intro.\n\n```swift\nlet a = 1\n```\n\nTail.\n"
        let document = MarkdownConverter.parse(source)
        let code = try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .blockComment(body: "This needs an index"), range: code.range,
            in: source, reviewer: "clint", timestamp: stamp))
        let after = applying(edit, to: source)
        XCTAssertTrue(after.contains("```\n\n{>>This needs an index<<}{#c1}"),
                      "comment paragraph directly after the fence: \(after)")

        let afterDoc = MarkdownConverter.parse(after)
        let items = SuggestionResolver.reviewItems(in: afterDoc)
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].isSuggestion)
        XCTAssertEqual(items[0].by, "clint")
        // The code block itself is byte-identical.
        XCTAssertTrue(after.contains("```swift\nlet a = 1\n```"))
    }

    func testBlockCommentAfterTheLastBlock() throws {
        let source = "Only a table:\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
        let document = MarkdownConverter.parse(source)
        let table = try XCTUnwrap(document.blocks.first {
            if case .table = $0.kind { return true }
            return false
        })
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .blockComment(body: "Check row 2"), range: table.range,
            in: source, reviewer: "AI", timestamp: stamp))
        let after = applying(edit, to: source)
        XCTAssertEqual(SuggestionResolver.reviewItems(in: MarkdownConverter.parse(after)).count, 1,
                       "\(after)")
    }

    func testBlockCommentIsOneUndoThroughTheSession() async throws {
        let source = "Intro.\n\n```swift\nlet a = 1\n```\n"
        let document = MarkdownConverter.parse(source)
        let code = try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        let slice = try XCTUnwrap(source.substring(in: code.range))
        let session = DocumentSession(source: source, fileURL: nil)
        let result = try await session.applyAnnotation(
            kind: .blockComment(body: "note"), range: code.range,
            expectedSlice: slice, reviewer: "clint")
        XCTAssertNotNil(result)
        let restored = try await session.undo()
        XCTAssertEqual(restored?.source, source, "one undo removes comment AND entry")
    }

    func testBlockCommentDismissalLeavesTheBlockIntact() throws {
        let source = "Intro.\n\n```swift\nlet a = 1\n```\n\nTail.\n"
        let document = MarkdownConverter.parse(source)
        let code = try XCTUnwrap(document.blocks.first {
            if case .codeBlock = $0.kind { return true }
            return false
        })
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .blockComment(body: "note"), range: code.range,
            in: source, reviewer: "clint", timestamp: stamp))
        let after = applying(edit, to: source)
        let mark = try XCTUnwrap(SuggestionResolver.marks(in: MarkdownConverter.parse(after)).first)
        let dismiss = try XCTUnwrap(SuggestionResolver.combinedResolutionEdit(
            resolving: mark.range, in: after, action: .accept))
        let resolved = applying(dismiss, to: after)
        XCTAssertTrue(resolved.contains("```swift\nlet a = 1\n```"), "block untouched")
        XCTAssertEqual(
            ReviewEndmatter.resolvedRecords(in: MarkdownConverter.parse(resolved)).count, 1)
        let blocks = MarkdownConverter.parse(resolved).blocks.count
        XCTAssertEqual(MarkdownConverter.parse(source).blocks.count + 1, blocks + 0,
                       "endmatter block remains; comment paragraph reduced to blank")
    }


    // MARK: - Review-verified edge cases (2026-07-15)

    func testDocumentLevelCommentOnEmptyDocumentIsDetectable() throws {
        // The previously-untested empty-document path (review coverage
        // gap): the endmatter's `\n---\n` delimiter is required for
        // detection, so the leading blank is structural — the result must
        // parse back as review metadata.
        let edit = try XCTUnwrap(ReviewAuthoring.annotationEdit(
            kind: .comment(body: "overall"), range: ByteRange(offset: 0, length: 0),
            in: "", reviewer: "AI", timestamp: "t"))
        let after = applying(edit, to: "")
        let metadata = try XCTUnwrap(ReviewEndmatter.detect(in: after)?.metadata,
                                     "\(after.debugDescription)")
        XCTAssertEqual(metadata.comments["c1"]?.body, "overall")
        XCTAssertEqual(metadata.comments["c1"]?.by, "AI")
    }

    func testStaleRangeHittingADifferentMarkRefusesThroughTheSession() async throws {
        // The identity gap: after an intervening edit, mark B occupies
        // mark A's old equal-length range. Resolving A's stale range must
        // refuse, not resolve B (review LOW).
        let source = "{--zz--}{#a}{++qq++}{#b}\n"
        let session = DocumentSession(source: source, fileURL: nil)
        let marks = SuggestionResolver.marks(in: MarkdownConverter.parse(source))
        let a = try XCTUnwrap(marks.first { $0.id == "a" })
        let aSlice = try XCTUnwrap(source.substring(in: a.range))
        // Resolve A with its correct slice — succeeds.
        let first = try await session.applyResolution(
            markRange: a.range, action: .accept, expectedSlice: aSlice)
        XCTAssertNotNil(first)
        // Now a stale range equal to A's, but the bytes there are B's — refuse.
        let after = await session.document
        let second = try await session.applyResolution(
            markRange: a.range, action: .accept, expectedSlice: aSlice)
        XCTAssertNil(second, "stale slice no longer matches — refuse")
        let final = await session.document
        XCTAssertEqual(final.source, after.source, "nothing spliced")
    }

}
