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
    /// Owned window/scroll for the standalone (`init(width:)`) stack. Nil when the
    /// harness is *adopting* a live island cell's text view — that view's window
    /// and enclosing scroll view are owned by the recycler, not by us.
    private let window: NSWindow?
    private let scroll: NSScrollView?
    /// A real editable `NSTextView`. In the standalone stack it is one this
    /// harness built; when adopting, it points at a live
    /// `BlockEditorCell.islandTextView` — the drivers/reads below touch ONLY this
    /// view (never its delegate, owned by the cell) and `appliedRevision`, so they
    /// run unchanged against the real island edit path.
    public let textView: NSTextView
    /// Bumped once per driven edit in the standalone stack. When adopting, the
    /// applied-revision is sourced from the orchestrator via `appliedRevisionSource`.
    private var drivenRevision = 0
    /// When adopting, keys `appliedRevision` off the real applied-edit signal (the
    /// orchestrator's revision) instead of the harness-local driven counter.
    private let appliedRevisionSource: (() -> Int)?
    /// Monotonic; bumps once per driven edit (standalone) or reflects the real
    /// applied-edit signal (adopting).
    public var appliedRevision: Int { appliedRevisionSource?() ?? drivenRevision }

    /// Adopt a live island cell's text view. Skips window/stack construction — the
    /// text view already belongs to a promoted `BlockEditorCell` inside the
    /// recycler's own offscreen window. The same drivers
    /// (`type`/`pressReturn`/`pressBackspace`/`move`) and reads
    /// (`quiesce`/`caretRect`/`assertInsertionBar`) become the end-to-end
    /// regression gate against the REAL edit path. The `appliedRevision` closure
    /// lets the harness key its quiescence off the real applied-edit signal.
    ///
    /// Does NOT reassign `textView.delegate` — the cell owns it (that delegate is
    /// what fans typed changes out to the `IslandController` reconcile debounce).
    public init(adopting textView: NSTextView, appliedRevision: @escaping () -> Int) {
        self.window = nil
        self.scroll = nil
        self.textView = textView
        self.appliedRevisionSource = appliedRevision
    }

    public init(width: CGFloat = 600) {
        self.appliedRevisionSource = nil
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

        let scroll = NSScrollView(frame: frame)
        scroll.documentView = textView
        self.scroll = scroll

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        self.window = window
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
            drivenRevision += 1
        }
    }

    /// Drive Return through the REAL command path — `doCommand(by: insertNewline:)`
    /// — NOT `insertNewline(nil)` directly, so the `IslandTextView.doCommand`
    /// override (and its `onInsertNewline` structural-op hook, Task 5) is actually
    /// exercised. A hook that consumes the keystroke suppresses the native newline;
    /// a nil/false hook falls through to native, same as before.
    public func pressReturn() {
        textView.doCommand(by: #selector(NSTextView.insertNewline(_:)))
        drivenRevision += 1
    }

    /// Drive Backspace through the real command path (mirrors `pressReturn`), so the
    /// `onDeleteBackward` hook (Task 7) is exercised.
    public func pressBackspace() {
        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        drivenRevision += 1
    }

    /// Drive a selection/movement command (e.g. `#selector(NSResponder.moveRight(_:))`).
    public func move(_ sel: Selector) {
        textView.doCommand(by: sel)
        drivenRevision += 1
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
