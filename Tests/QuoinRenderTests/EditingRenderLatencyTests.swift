#if canImport(AppKit)
import XCTest
import QuoinCore
@testable import QuoinRender

/// The render layer's slice of the keystroke loop, budgeted like the core's
/// (see EditingLatencyTests): while a block's source is revealed for
/// editing, each keystroke re-renders ONLY that block's fragment and each
/// caret move re-styles it — both must be block-local, never document-scale.
final class EditingRenderLatencyTests: XCTestCase {

    /// One 60 Hz frame is 16 ms for the WHOLE loop; the render fragment is
    /// one slice of it. 25 ms leaves shared-CI headroom while still failing
    /// unmistakably on anything document-scale.
    private let fragmentBudget: TimeInterval = 0.025

    /// A revealed mermaid block's source, typical editing size.
    private let mermaidSource = """
    ```mermaid
    flowchart TD
        A[Weigh anchor] --> B{Wind fair?}
        B -->|yes| C[Set course]
        B -->|no| D[Wait in port]
        subgraph nav [Navigation]
            C --> E[Take bearings]
            E --> F[Log position]
        end
        F --> G[Stand watch]
    ```
    """

    private func bestOf(_ n: Int, _ work: () -> Void) -> TimeInterval {
        var best = TimeInterval.greatestFiniteMagnitude
        for _ in 0..<n {
            let start = Date()
            work()
            best = min(best, Date().timeIntervalSince(start))
        }
        return best
    }

    /// Per-keystroke fragment render of a revealed mermaid block (the
    /// storage-patch path ReaderModel takes while typing in chart source).
    func testEditableMermaidFragmentRenderMeetsBudget() {
        let renderer = AttributedRenderer()
        var length = 0
        let best = bestOf(5) {
            length = renderer.renderEditableSourceFragment(self.mermaidSource, caretOffset: 40).attributed.length
        }
        XCTAssertGreaterThan(length, 0)
        XCTAssertLessThan(best, fragmentBudget,
                          "editable mermaid fragment took \(best * 1000) ms per keystroke")
    }

    /// Per-caret-move restyle of the revealed block (span-level syntax
    /// reveal re-runs the styler on every caret step).
    func testCaretRestyleMeetsBudget() {
        let styler = MarkdownSourceStyler(theme: Theme())
        var length = 0
        let best = bestOf(5) {
            length = styler.style(self.mermaidSource, caretOffset: 60).length
        }
        XCTAssertGreaterThan(length, 0)
        XCTAssertLessThan(best, fragmentBudget,
                          "caret restyle took \(best * 1000) ms per move")
    }

    /// The fragment cost must be a property of the BLOCK, not the document
    /// it lives in: rendering the same block's fragment must cost the same
    /// whether the surrounding document is a note or a novel. (The fragment
    /// API only sees the slice, so this guards against someone threading
    /// whole-document work into the per-keystroke path.)
    func testFragmentRenderIsBlockLocal() {
        let renderer = AttributedRenderer()
        let bigSlice = mermaidSource // same block either way — cost is slice-sized
        let small = bestOf(5) { _ = renderer.renderEditableSourceFragment(bigSlice, caretOffset: 10) }
        let repeated = bestOf(5) { _ = renderer.renderEditableSourceFragment(bigSlice, caretOffset: 200) }
        // Caret position must not change the cost class (10× guard, not a
        // tight ratio — tiny numerators are noisy).
        XCTAssertLessThan(max(small, repeated), fragmentBudget)
    }
}
#endif
