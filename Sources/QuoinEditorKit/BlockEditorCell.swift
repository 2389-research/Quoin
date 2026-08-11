#if canImport(AppKit)
import AppKit
import QuoinCore

/// Phase 2, Task 1: a cell hosting a REAL editable `NSTextView` seeded with a
/// single block's RAW Markdown source (e.g. `"# Heading"`, WITH the `#`). This
/// is the leaf the editable "island" is built from — the counterpart to
/// `BlockRenderCell` (the read-only KEEP projection) for the ACTIVE block.
///
/// Unlike `BlockRenderCell`, this is not a draw-only view: it embeds a genuine
/// `NSTextView` on a live TextKit-2 stack (content storage → layout manager →
/// container at the configured width), configured EXACTLY as
/// `EditorTestHarness` configures its text view so the real input path runs
/// (no smart-quote / dash / replacement / spelling rewrites corrupting the
/// Markdown source out from under the caret).
///
/// Scope for this task is the editable leaf ONLY: no recycler, no
/// `DocumentSession` wiring, no reconcile. `onTextDidChange` fires on live
/// edits (the debounce + height signal for later tasks);
/// `fittingHeightForConfiguredWidth` measures the LIVE text layout so the row
/// can grow as the source is edited.
@MainActor
public final class BlockEditorCell: NSView {
    /// Which block this cell currently hosts. `nil` before the first
    /// `configure`. Recycling identity, mirroring `BlockRenderCell.blockID`.
    public private(set) var blockID: BlockID?

    /// Fired on every live edit (drives the debounce → reconcile + height
    /// re-query in later tasks). Delivered on the main actor from the text
    /// view's `textDidChange` delegate callback.
    public var onTextDidChange: (() -> Void)?

    /// The real editable view. The harness (and, in Task 5, the controller)
    /// makes THIS first responder and places the caret from a click point.
    public var islandTextView: NSTextView { textView }

    // A live TextKit-2 stack: content storage → layout manager → container,
    // built the same way the harness / CaretLineAnchorTests stand one up.
    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(
        size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private let textView: NSTextView

    // Bridges the text view's `textDidChange` back to `onTextDidChange` without
    // making the cell itself the delegate (keeps NSTextViewDelegate off the
    // public surface).
    private let changeForwarder = ChangeForwarder()

    public override init(frame frameRect: NSRect) {
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = textContainer
        textView = NSTextView(frame: frameRect, textContainer: textContainer)

        super.init(frame: frameRect)
        wantsLayer = true

        // Mirror EditorTestHarness / spec: a real editable, plain-text view with
        // every auto-rewrite OFF so the raw Markdown source is never mutated
        // (a smart quote would corrupt the source the session round-trips).
        textView.isEditable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Monospace source is fine for Phase 2 (styling is deferred).
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)

        changeForwarder.onChange = { [weak self] in self?.onTextDidChange?() }
        textView.delegate = changeForwarder

        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // The recycler places rows top-down; a flipped coordinate space matches
    // BlockRenderCell and the text view's own top-down layout.
    public override var isFlipped: Bool { true }

    /// Point the cell at `blockID`, seeding the text view with `slice` — the
    /// RAW block source (with delimiters) — and laying it out at content
    /// `width`. Reusable: safe to call repeatedly to recycle across blocks.
    public func configure(slice: String, blockID: BlockID, width: CGFloat) {
        self.blockID = blockID
        textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        // Seeding the source is NOT a user edit — swap the string directly.
        textView.string = slice
        textView.setFrameSize(NSSize(width: width, height: fittingHeightForConfiguredWidth))
    }

    /// The row height for the CURRENTLY-LIVE source at the configured width,
    /// measured from the real text layout (ensure layout, then sum the layout
    /// fragment heights). Grows as the source is edited — later tasks re-query
    /// this on `onTextDidChange`. Zero before the first `configure`.
    public var fittingHeightForConfiguredWidth: CGFloat {
        layoutManager.ensureLayout(for: contentStorage.documentRange)
        var height: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(
            from: contentStorage.documentRange.location
        ) { fragment in
            height += fragment.layoutFragmentFrame.height
            return true
        }
        return height
    }

    /// Private `NSTextViewDelegate` shim: forwards `textDidChange` to the cell's
    /// `onTextDidChange` without exposing conformance on `BlockEditorCell`.
    private final class ChangeForwarder: NSObject, NSTextViewDelegate {
        var onChange: (() -> Void)?
        func textDidChange(_ notification: Notification) { onChange?() }
    }
}
#endif
