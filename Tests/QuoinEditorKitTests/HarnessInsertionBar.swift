#if canImport(AppKit)
import XCTest
import AppKit
@testable import QuoinEditorKit

/// The insertion-bar gate lives test-side (XCTest is not linked into the
/// QuoinEditorKit library product; keeping `XCTAssert*` out of the shipping
/// library avoids linking XCTest into a non-test target). The call site is
/// identical to the harness owning it — `h.assertInsertionBar(minHeight:)`.
///
/// This is the 2pt-dot regression gate: a collapsed insertion point renders as
/// a ~2pt dot, a real caret is the line height. In Phase 2, repointed at the
/// island cell's text view, this catches the caret-collapse regression.
extension EditorTestHarness {
    func assertInsertionBar(
        minHeight: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(
            caretRect.height, minHeight,
            "caret must be a real insertion bar, not a collapsed dot",
            file: file, line: line)
    }
}
#endif
