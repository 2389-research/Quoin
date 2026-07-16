import XCTest
@testable import QuoinCore

/// Pins down `EditIntent.classify` — the pure keystroke classifier extracted
/// from `ReaderCoordinator.shouldChangeTextIn`. The expectations here are the
/// *original* smart-pair behavior, so a correct `classify` is behavior-
/// preserving. (Until `classify` is implemented past its stub, the
/// smart-pair cases below fail while everything falls through to `.replace`.)
final class EditIntentTests: XCTestCase {

    // MARK: - classify: smart-pair wrapping

    func testWrapSelectionWithPairDelimiter() {
        // Select "word", type "*" → wrap to *word*, caret before the closer.
        let intent = EditIntent.classify(sourceText: "word", range: 0..<4, replacement: "*")
        XCTAssertEqual(intent, .wrapSelection(range: 0..<4, text: "*word*", caret: 5))
    }

    func testWrapEqualsUsesHighlightPair() {
        // `=` wraps as the `==` highlight pair, not a single equals.
        let intent = EditIntent.classify(sourceText: "hi", range: 0..<2, replacement: "=")
        XCTAssertEqual(intent, .wrapSelection(range: 0..<2, text: "==hi==", caret: 4))
    }

    func testWrapSuppressedInsideCodeSpanFallsBackToReplace() {
        // Selection sits inside a backtick span → wrapping is suspended.
        let intent = EditIntent.classify(sourceText: "`ab`", range: 1..<3, replacement: "*")
        XCTAssertEqual(intent, .replace(range: 1..<3, text: "*"))
    }

    // MARK: - classify: pair completion & type-over

    func testCompletePairAtEmptyCaret() {
        let intent = EditIntent.classify(sourceText: "", range: 0..<0, replacement: "*")
        XCTAssertEqual(intent, .completePair(range: 0..<0, text: "**", caret: 1))
    }

    func testTypeOverExistingCloser() {
        // Caret before an existing "*" typing "*" steps over it.
        let intent = EditIntent.classify(sourceText: "*", range: 0..<0, replacement: "*")
        XCTAssertEqual(intent, .typeOver(range: 0..<1, closer: "*"))
    }

    func testNonPairCharacterIsPlainReplace() {
        let intent = EditIntent.classify(sourceText: "hello", range: 0..<0, replacement: "z")
        XCTAssertEqual(intent, .replace(range: 0..<0, text: "z"))
    }

    func testCompletionSuppressedInsideCodeSpan() {
        // "`x" leaves the caret inside an open code span → no completion.
        let intent = EditIntent.classify(sourceText: "`x", range: 2..<2, replacement: "*")
        XCTAssertEqual(intent, .replace(range: 2..<2, text: "*"))
    }

    // MARK: - classify: plain replacements

    func testMultiCharacterReplacementIsPlain() {
        // A paste is never a smart pair.
        let intent = EditIntent.classify(sourceText: "abc", range: 1..<1, replacement: "xy")
        XCTAssertEqual(intent, .replace(range: 1..<1, text: "xy"))
    }

    func testDeletionIsPlainReplace() {
        let intent = EditIntent.classify(sourceText: "abc", range: 1..<2, replacement: "")
        XCTAssertEqual(intent, .replace(range: 1..<2, text: ""))
    }

    // MARK: - edit: the uniform triple each case resolves to

    func testEditResolvesEachCase() {
        XCTAssertEqual(EditIntent.wrapSelection(range: 0..<4, text: "*word*", caret: 5).edit.caret, 5)

        let typeOver = EditIntent.typeOver(range: 0..<1, closer: "*").edit
        XCTAssertEqual(typeOver.range, 0..<1)
        XCTAssertEqual(typeOver.text, "*")
        XCTAssertEqual(typeOver.caret, 1, "type-over lands the caret just past the stepped-over closer")

        XCTAssertNil(EditIntent.replace(range: 2..<3, text: "x").edit.caret,
            "a plain replacement uses default caret handling")
    }
}
