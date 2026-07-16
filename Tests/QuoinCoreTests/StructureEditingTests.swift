import XCTest
@testable import QuoinCore

/// #25 — structural line-prefix edits. These operate on a block's source slice
/// and must preserve line terminators exactly (LF and CRLF) so round-trip
/// losslessness holds for the untouched rest of the document.
final class StructureEditingTests: XCTestCase {

    // MARK: Headings

    func testParagraphToHeading() {
        XCTAssertEqual(StructureEditing.settingHeadingLevel("Hello", level: 1), "# Hello")
        XCTAssertEqual(StructureEditing.settingHeadingLevel("Hello", level: 3), "### Hello")
    }

    func testChangeHeadingLevel() {
        XCTAssertEqual(StructureEditing.settingHeadingLevel("## Hello", level: 1), "# Hello")
        XCTAssertEqual(StructureEditing.settingHeadingLevel("# Hello", level: 4), "#### Hello")
    }

    func testHeadingToParagraph() {
        XCTAssertEqual(StructureEditing.settingHeadingLevel("### Hello", level: 0), "Hello")
    }

    func testHeadingCycleWraps() {
        var s = "Hello"
        for expected in ["# Hello", "## Hello", "### Hello", "#### Hello", "##### Hello", "###### Hello", "Hello"] {
            s = StructureEditing.cyclingHeadingLevel(s)!
            XCTAssertEqual(s, expected)
        }
    }

    func testHeadingRejectsMultiLine() {
        XCTAssertNil(StructureEditing.settingHeadingLevel("line one\nline two", level: 1))
    }

    func testHeadingPreservesTrailingNewline() {
        XCTAssertEqual(StructureEditing.settingHeadingLevel("Hello\n", level: 2), "## Hello\n")
    }

    // MARK: Quote

    func testToggleQuoteOn() {
        XCTAssertEqual(StructureEditing.togglingQuote("a\nb"), "> a\n> b")
    }

    func testToggleQuoteOff() {
        XCTAssertEqual(StructureEditing.togglingQuote("> a\n> b"), "a\nb")
    }

    // MARK: Lists

    func testToggleBulletOn() {
        XCTAssertEqual(StructureEditing.togglingList("a\nb", ordered: false), "- a\n- b")
    }

    func testToggleBulletOff() {
        XCTAssertEqual(StructureEditing.togglingList("- a\n- b", ordered: false), "a\nb")
    }

    func testToggleNumberedRenumbers() {
        XCTAssertEqual(StructureEditing.togglingList("a\nb\nc", ordered: true), "1. a\n2. b\n3. c")
    }

    func testBulletToNumbered() {
        XCTAssertEqual(StructureEditing.togglingList("- a\n- b", ordered: true), "1. a\n2. b")
    }

    func testToggleListPreservesTrailingNewline() {
        XCTAssertEqual(StructureEditing.togglingList("a\nb\n", ordered: false), "- a\n- b\n")
    }

    // MARK: Checkbox

    func testCheckboxOnPlainLine() {
        XCTAssertEqual(StructureEditing.togglingCheckbox("todo", caretUTF16: 0), "- [ ] todo")
    }

    func testCheckboxOnBullet() {
        XCTAssertEqual(StructureEditing.togglingCheckbox("- todo", caretUTF16: 0), "- [ ] todo")
    }

    func testCheckboxFlipUncheckedToChecked() {
        XCTAssertEqual(StructureEditing.togglingCheckbox("- [ ] todo", caretUTF16: 0), "- [x] todo")
    }

    func testCheckboxFlipCheckedToUnchecked() {
        XCTAssertEqual(StructureEditing.togglingCheckbox("- [x] done", caretUTF16: 0), "- [ ] done")
    }

    func testCheckboxTogglesCaretLineInMultiItemList() {
        // Caret on the second item ("- b" starts at UTF-16 offset 4).
        let slice = "- a\n- b\n- c"
        XCTAssertEqual(StructureEditing.togglingCheckbox(slice, caretUTF16: 5), "- a\n- [ ] b\n- c")
    }

    // MARK: CRLF preservation

    func testCRLFTerminatorsPreserved() {
        XCTAssertEqual(StructureEditing.togglingList("a\r\nb", ordered: false), "- a\r\n- b")
        XCTAssertEqual(StructureEditing.togglingQuote("a\r\nb\r\n"), "> a\r\n> b\r\n")
    }

    // MARK: Round-trip against real parsed blocks

    func testRoundTripAgainstParsedParagraph() {
        let src = "First para.\n\nSecond para.\n"
        let doc = MarkdownConverter.parse(src)
        // First paragraph block (ASCII, so UTF-8 and UTF-16 offsets coincide).
        let para = doc.blocks.first { if case .paragraph = $0.kind { return true }; return false }!
        let slice = doc.source.substring(in: para.range)!
        let promoted = StructureEditing.settingHeadingLevel(slice, level: 2)!
        // Splicing the replacement back must leave the rest byte-identical.
        let ns = doc.source as NSString
        let edited = ns.replacingCharacters(
            in: NSRange(location: para.range.offset, length: para.range.length),
            with: promoted)
        XCTAssertEqual(edited, "## First para.\n\nSecond para.\n")
    }
}
