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
    /// Publicly typed `NSTextView`; internally the `IslandTextView` subclass that
    /// carries the responder seams (blur / Return / Backspace).
    public var islandTextView: NSTextView { textView }

    /// Blur seam passthrough to the hosted `IslandTextView` (a responder override,
    /// NOT a delegate method — the `ChangeForwarder` delegate is untouched). The
    /// controller installs `deactivate()` here so a click outside the island — or
    /// the window handing first responder elsewhere — flushes + swaps back to
    /// read-only.
    public var onResignFirstResponder: (() -> Void)? {
        get { textView.onResignFirstResponder }
        set { textView.onResignFirstResponder = newValue }
    }

    /// Return-key seam passthrough (wired in Task 5).
    public var onInsertNewline: (() -> Bool)? {
        get { textView.onInsertNewline }
        set { textView.onInsertNewline = newValue }
    }

    /// Backspace seam passthrough (wired in Task 7).
    public var onDeleteBackward: (() -> Bool)? {
        get { textView.onDeleteBackward }
        set { textView.onDeleteBackward = newValue }
    }

    /// Phase 3 (island source styling): the function that turns the island's RAW
    /// Markdown source into its STYLED form — per-line type ramp + faded
    /// delimiters, so edit mode keeps the block's vertical skeleton (handoff §1,
    /// CLAUDE.md's per-line style transplant).
    ///
    /// Injected rather than built here so the cell stays a leaf: the recycler
    /// installs `renderer.styledIslandSource`, which is the SAME derivation (one
    /// `MarkdownSourceStyler`, one paragraph-style transplant off the read
    /// fragment) the monolithic projection's syntax reveal uses — a second
    /// delimiter recognizer would drift (CLAUDE.md).
    ///
    /// Arguments are `(source, caretUTF16)`; the caret scopes the inline-span
    /// reveal. The contract the cell ENFORCES on every call: the returned
    /// string must equal the source character for character. A styler that
    /// changes the bytes is REFUSED (the source stays, unstyled) — 1:1 is what
    /// caret mapping, Return-split and the flush path all stand on.
    ///
    /// `nil` (the default) leaves the island in the plain mono seed face, which
    /// is what the Phase-2 leaf tests exercise.
    public var sourceStyler: ((String, Int?) -> NSAttributedString)? {
        didSet { restyle() }
    }

    // A live TextKit-2 stack: content storage → layout manager → container,
    // built the same way the harness / CaretLineAnchorTests stand one up.
    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(
        size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private let textView: IslandTextView

    // Bridges the text view's `textDidChange` back to `onTextDidChange` without
    // making the cell itself the delegate (keeps NSTextViewDelegate off the
    // public surface).
    private let changeForwarder = ChangeForwarder()

    public override init(frame frameRect: NSRect) {
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = textContainer
        textView = IslandTextView(frame: frameRect, textContainer: textContainer)

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
        // The seed face, used only until a `sourceStyler` is installed (the
        // Phase-2 leaf tests run without one).
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        // Align the island's glyph origin with `BlockRenderCell`'s: the read cell
        // draws its text shifted by (leftGutter, verticalBleed) inside a row that
        // reserves that chrome padding, and the editing row reserves the same
        // padding (`BlockRowMetrics`). Without the inset the text jumped 14pt
        // left and 5pt up the instant a block was activated.
        textView.textContainerInset = NSSize(
            width: DecorationDraw.leftGutter, height: DecorationDraw.verticalBleed)

        changeForwarder.onChange = { [weak self] in
            guard let self else { return }
            // Restyle FIRST so the height the recycler is about to re-query off
            // `fittingHeightForConfiguredWidth` is measured on the styled text,
            // not on one keystroke's worth of unstyled seed face.
            self.restyle()
            self.onTextDidChange?()
        }
        changeForwarder.onSelectionChange = { [weak self] in self?.caretDidMove() }
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
        lastStyledCaret = nil
        restyle()
        textView.setFrameSize(NSSize(width: width, height: fittingHeightForConfiguredWidth))
    }

    /// Replace the island's source text WITHOUT it counting as a user edit, then
    /// restyle and seat the caret.
    ///
    /// Phase 3, Task 5b (the virtual line) needs to swap the island's string in
    /// place — host slice ⇄ host slice + the byte-less blank line — while keeping
    /// the cell's recycling identity, its first-responder status, and its STYLING.
    /// Poking `islandTextView.string` directly (what the `applyReconciled` re-home
    /// does) leaves the island in the unstyled seed face until the next keystroke;
    /// this is the same seeding path `configure` uses, minus the block identity and
    /// container-width work.
    ///
    /// The caret is seated BEFORE the restyle so the caret-scoped span reveal is
    /// computed for the position the caret actually ends at.
    public func setSourceText(_ text: String, caretUTF16: Int) {
        textView.string = text
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: max(0, min(caretUTF16, length)), length: 0))
        lastStyledCaret = nil
        restyle()
        textView.setFrameSize(
            NSSize(width: currentContentWidth, height: fittingHeightForConfiguredWidth))
    }

    // MARK: - Styling (Phase 3)

    /// Re-entrancy latch. `restyle()` writes attributes into the live text
    /// storage and restores the selection; both can echo back through the
    /// delegate (`textDidChange` / `textViewDidChangeSelection`). Without the
    /// latch that echo re-enters `restyle()` — the infinite loop the
    /// styling-on-every-keystroke design is most exposed to.
    private var isRestyling = false

    /// The caret offset the current attributes were computed for, so a
    /// selection change that does not move the caret (e.g. the one our own
    /// restyle provokes) does no work.
    private var lastStyledCaret: Int?

    /// Test hook (BlockEditorCellStylingTests): how many times attributes were
    /// actually written into the storage. A restyle loop makes this unbounded.
    private(set) var restyleCountForTest = 0

    /// Apply `sourceStyler` to the island's CURRENT text, in place, as
    /// ATTRIBUTES ONLY. The characters are never touched: a styler whose output
    /// string differs from the source is refused outright.
    private func restyle() {
        guard !isRestyling, let styler = sourceStyler,
              let storage = textView.textStorage, storage.length > 0
        else { return }
        isRestyling = true
        defer { isRestyling = false }

        let source = storage.string
        let caret = textView.selectedRange().location
        let styled = styler(source, caret)
        guard styled.string == source else {
            // THE string is sacred: a styler that changed the bytes would
            // desynchronize every offset the island's edit path computes.
            ilog("style.refuse", "styler changed the source (len \(source.utf16.count) → \(styled.length))")
            return
        }
        lastStyledCaret = caret

        let selection = textView.selectedRanges
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        // `setAttributes` per run REPLACES that run's attributes wholesale, and
        // the enumeration partitions the whole string — so no stale attribute
        // from the previous pass can survive.
        styled.enumerateAttributes(in: full, options: []) { attributes, range, _ in
            storage.setAttributes(attributes, range: range)
        }
        storage.endEditing()
        // Attribute-only editing does not move the caret, but restoring it is
        // free insurance against an AppKit selection clamp during endEditing.
        textView.selectedRanges = selection
        // Newly typed characters inherit the caret's own run rather than the
        // seed face, so a keystroke never flashes unstyled before the restyle.
        if caret > 0, caret <= styled.length {
            textView.typingAttributes = styled.attributes(at: caret - 1, effectiveRange: nil)
        }
        restyleCountForTest += 1
        ilog("style.apply", "len=\(full.length) caret=\(caret) count=\(restyleCountForTest)")
    }

    /// Caret-scoped span reveal: the handoff makes an inline span's delimiters
    /// appear ONLY while the caret is inside that span, so moving the caret is a
    /// styling event. Cheap-guarded — a selection notification that leaves the
    /// caret where it was (including the one our own restyle emits) is dropped.
    private func caretDidMove() {
        guard !isRestyling, sourceStyler != nil else { return }
        guard textView.selectedRange().location != lastStyledCaret else { return }
        restyle()
    }

    /// Test hook (BlockEditorCellStylingTests): the island's live attributed
    /// text, exactly as it is laid out and drawn.
    var styledTextForTest: NSAttributedString {
        textView.textStorage.map { NSAttributedString(attributedString: $0) }
            ?? NSAttributedString()
    }

    /// The content width the island currently LAYS OUT at (the text container's
    /// width), which is what `fittingHeightForConfiguredWidth` measures against.
    /// Exposed so the recycler can tell whether a live island still matches the
    /// column it is framed at (see `updateWidth(_:)`).
    public var currentContentWidth: CGFloat { textContainer.size.width }

    /// Phase 3 (width drift): re-lay the LIVE island at a new content `width`
    /// WITHOUT re-seeding its text.
    ///
    /// `configure(slice:blockID:width:)` is the only other setter of the text
    /// container's width, and it is reachable ONLY from the table's row reload —
    /// which `BlockRecyclerView.updateDocumentPreservingEditing`'s KEEP path
    /// deliberately SPARES for the editing row (first responder + caret survive).
    /// So a re-apply at a new width used to re-frame the cell while the island kept
    /// laying out at the OLD column, and the row was then measured at a width it did
    /// not have — mis-size, then re-size: the visible jiggle.
    ///
    /// The island's text is AUTHORITATIVE here: re-seeding it from the document
    /// would drop keystrokes that have not been flushed yet. Only the container
    /// geometry moves; the string, selection, and first-responder status are
    /// untouched. Idempotent (no-op at the same width).
    public func updateWidth(_ width: CGFloat) {
        guard textContainer.size.width != width else { return }
        textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.setFrameSize(NSSize(width: width, height: fittingHeightForConfiguredWidth))
    }

    /// Re-point this cell's recycling identity after a KEEP reconcile changed the
    /// hosted block's content-hash id. The hosted text, first responder, and caret
    /// are untouched — ONLY the identity tag moves, so the live editing row can be
    /// carried across a projection refresh without a reload (see
    /// `BlockRecyclerView.reanchorEditing`).
    public func reassignBlockID(_ newID: BlockID) {
        blockID = newID
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
        /// Caret moves drive the caret-scoped span reveal (Phase 3 styling).
        var onSelectionChange: (() -> Void)?
        func textDidChange(_ notification: Notification) { onChange?() }
        func textViewDidChangeSelection(_ notification: Notification) { onSelectionChange?() }
    }
}
#endif
