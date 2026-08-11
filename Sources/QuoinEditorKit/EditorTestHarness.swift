#if canImport(AppKit)
import AppKit

/// A headless driver for a REAL editable `NSTextView` — the piece whose absence
/// let green-but-broken editor fixes ship repeatedly. It stands up a live
/// TextKit-2 stack (content storage + layout manager + container) inside an
/// offscreen borderless window, makes the text view first responder, and drives
/// it through the real `NSTextInputClient`/`NSResponder` input methods so the
/// genuine input path runs (not a shortcut that mutates `.string`).
///
/// The offscreen-window + TextKit-2 setup mirrors `CaretLineAnchorTests`, which
/// already stands up the same stack headlessly in this codebase's CI — proof the
/// mechanism works without a host app.
///
/// Barrier: every driven edit bumps a monotonic `appliedRevision`. This is a
/// deliberately private counter, NOT `DocumentSession.contentRevision` — the
/// session revision does not tick on every ordinary edit, and the harness needs
/// a quiescence barrier that ticks on each driven edit. In Phase 2 the harness's
/// `textView` is repointed at the real island cell's text view and the same
/// drivers/asserts become the end-to-end regression gate; there the orchestrator's
/// real applied-revision is wired in.
///
/// The insertion-bar gate (`assertInsertionBar`) lives test-side so XCTest is not
/// linked into this shipping library product; see the test target's
/// `EditorTestHarness` extension.
@MainActor
public final class EditorTestHarness {
    private let window: NSWindow
    private let scroll: NSScrollView
    /// A real editable `NSTextView` in an offscreen window.
    public let textView: NSTextView
    /// Monotonic; bumps once per driven edit.
    public private(set) var appliedRevision = 0

    public init(width: CGFloat = 600) {
        let frame = NSRect(x: 0, y: 0, width: width, height: 800)

        // A live TextKit-2 stack: content storage → layout manager → container.
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: width, height: .greatestFiniteMagnitude))
        layoutManager.textContainer = container

        textView = NSTextView(frame: frame, textContainer: container)
        textView.isEditable = true
        textView.isRichText = false
        // Keep the real input path deterministic: no autocorrect/smart-substitution
        // rewriting the driven characters out from under the assertions.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        scroll = NSScrollView(frame: frame)
        scroll.documentView = textView

        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    // MARK: - Drivers (real responder / NSTextInputClient methods)

    /// Seed island source directly (not counted as a driven edit).
    public func setText(_ s: String) {
        textView.string = s
        quiesce()
    }

    /// Type each character through `insertText(_:replacementRange:)` — the real
    /// `NSTextInputClient` entry point — bumping `appliedRevision` per character.
    public func type(_ s: String) {
        for ch in s {
            textView.insertText(
                String(ch),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            appliedRevision += 1
        }
    }

    public func pressReturn() {
        textView.insertNewline(nil)
        appliedRevision += 1
    }

    public func pressBackspace() {
        textView.deleteBackward(nil)
        appliedRevision += 1
    }

    /// Drive a selection/movement command (e.g. `#selector(NSResponder.moveRight(_:))`).
    public func move(_ sel: Selector) {
        textView.doCommand(by: sel)
        appliedRevision += 1
    }

    // MARK: - Quiescence + reads

    /// Settle the layout and pump the runloop so `firstRect`/geometry reads are
    /// resolved before they are queried.
    public func quiesce() {
        if let content = textView.textContentStorage {
            textView.textLayoutManager?.ensureLayout(for: content.documentRange)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    /// The first rect for the current insertion point, in window coordinates.
    public var caretRect: CGRect {
        let sel = textView.selectedRange()
        var actual = NSRange()
        return textView.firstRect(forCharacterRange: sel, actualRange: &actual)
    }
}
#endif
