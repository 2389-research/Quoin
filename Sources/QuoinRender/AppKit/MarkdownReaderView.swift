#if canImport(AppKit)
import AppKit
import SwiftUI
import QuoinCore

/// Format commands the window can send to the editor's selection.
public enum FormatCommand: Equatable, Sendable {
    case bold, italic, strikethrough, code, highlight, link
}

/// Block-granularity commands from the context menu (ideas #9/#10/#11);
/// the host applies them as byte-exact source edits (BlockEditing).
///
/// The table cases (#14) carry the grid coordinates of the caret/right-click
/// so the host can target the exact row/column; the host computes them from
/// the click point through `TableEditing.location` and passes them here. Row 0
/// is the header, columns are 0-based. The host still degrades gracefully: any
/// command on a non-table or an out-of-range target is a quiet no-op.
public enum BlockCommand: Equatable, Sendable {
    case moveUp, moveDown, duplicate, delete
    /// Append a blank row / column at the table's far edge (the legacy #11
    /// convenience, kept for the "add at end" affordance).
    case addTableRow, addTableColumn
    case tableInsertRow(at: Int, above: Bool)
    case tableDeleteRow(at: Int)
    case tableInsertColumn(at: Int, left: Bool)
    case tableDeleteColumn(at: Int)
    case tableMoveRow(at: Int, up: Bool)
    case tableMoveColumn(at: Int, left: Bool)
    case tableSetAlignment(at: Int, alignment: TableAlignment)
    case tableNormalize
}

/// Where the caret should land when a block activates, tagged with the
/// coordinate space the offset lives in. The two producers measure in
/// different spaces — prose clicks yield an offset into the block's
/// RENDERED text (which hides delimiters the projection dropped), while
/// embed bodies map 1:1 into the SOURCE slice via `embedSourceStart` — and
/// funneling both through a bare `Int` let a source offset get re-mapped
/// as if it were rendered, landing the caret a few characters early in
/// code bodies. The enum makes the space explicit at every call site.
public enum CaretHint: Equatable, Sendable {
    /// Offset into the block's rendered (projected) text; the model aligns
    /// it to the source through `EditMapping.sourceOffset`.
    case rendered(Int)
    /// Offset directly into the block's source slice; used verbatim.
    case source(Int)
}

// `ViewportSnapshot` moved to the QuoinRender target root
// (`ViewportSnapshot.swift`) so the shared editing view-model can own it without
// importing an AppKit view (iOS-shell extraction, ADR 0010, Phase 1).

/// The reading surface: a TextKit 2 `NSTextView` wrapped for SwiftUI.
///
/// TextKit 2 does viewport-based layout — only visible content is laid out —
/// which is what keeps very large documents scrolling at full frame rate.
/// The view is an editable projection: `isEditable` follows whether an
/// `onEditIntent` callback was supplied, so it is read-only only when hosted
/// without editing wired up. Keystrokes become source edits and non-text
/// interaction (web links, internal anchors, task checkboxes, edit chips)
/// flows through link plumbing.
public struct MarkdownReaderView: NSViewRepresentable {

    public let rendered: RenderedDocument
    public let theme: Theme
    /// Live search query; matches are highlighted with rendering attributes
    /// (no layout impact, original backgrounds untouched).
    public let searchQuery: String
    /// Match rules (case / whole word / regex) shared by the highlight scan
    /// and `SourceReplace` — ONE recognizer for both (#23).
    public let searchOptions: SearchOptions
    /// Scope the find scan to the current text selection.
    public let searchInSelection: Bool
    /// Which match is "current" (⌘G cycling); scrolled into view.
    public let activeMatchOrdinal: Int
    /// TOC navigation target; `scrollGeneration` bumps to re-apply, so
    /// clicking the same heading twice still scrolls.
    public let scrollTarget: BlockID?
    public let scrollGeneration: Int
    public let onTaskToggle: (Int) -> Void
    public let onMatchCount: (Int) -> Void
    /// Resolves an internal `#anchor` link to a block.
    public let anchorResolver: (String) -> BlockID?
    /// Fires when the topmost visible block changes (status-bar section tracking).
    public let onTopBlockChange: (BlockID?) -> Void

    /// S3a selection gestures (suggestions §3.6): the coordinator reports
    /// WHAT the user asked for and WHERE (block + rendered offsets within
    /// the block + the rendered text they saw); the model owns the
    /// rendered→source mapping and the session applies atomically.
    public var onAddAnnotation: ((ReviewAuthoring.Kind, BlockID, Int, Int, String) -> Void)? = nil
    /// Block-adjacent comment (#68): the comment paragraph lands AFTER the
    /// block — how opaque blocks (code/tables/diagrams/math) get commented.
    public var onAddBlockComment: ((BlockID, String) -> Void)? = nil
    /// Start a comment on the current selection (#45) — the selection popover's
    /// Comment button. Same effect as the ⇧⌘M / context-menu comment gesture;
    /// the app opens the compose popover for the reported selection range.
    public var onCommentOnSelection: (() -> Void)? = nil
    /// Menu-driven annotation gesture (⇧⌘M etc.), generation-fired like
    /// formatCommand. `.comment`/`.replacement` open the compose popover;
    /// `.deletion`/`.highlight` apply immediately.
    public enum AnnotationGesture: Equatable, Sendable {
        case comment, replacement, deletion, highlight
    }
    public var annotationCommand: AnnotationGesture? = nil
    public var annotationGeneration: Int = 0

    // MARK: Editing (nil callbacks = read-only reader)

    /// A keystroke inside the active block's revealed source. The range is
    /// relative to the active block's source slice (UTF-8 bytes); the app
    /// converts to an absolute `SourceEdit` and routes it through the
    /// session. `caretDelta` overrides where the caret lands (UTF-8 bytes
    /// from the range start; nil = end of replacement) — smart pairs use it
    /// to park the caret between the inserted delimiters.
    public let onEditIntent: ((_ relativeRange: ByteRange, _ replacement: String, _ caretDelta: Int?) -> Void)?
    /// Caret entered a block (nil id = deactivate, Esc). The `String?` is a
    /// pending insertion: the keystroke that triggered the activation by
    /// landing on a rendered block. The model applies it at the mapped caret
    /// position through the normal session edit path, so typing on a
    /// rendered block reveals the source AND inserts the character — the
    /// keystroke is never swallowed.
    public let onActivateBlock: ((BlockID?, CaretHint?, String?) -> Void)?
    /// Caret position (UTF-16, relative to the active block's source text)
    /// to restore after a re-render; `caretGeneration` bumps to re-apply.
    public let caretInActiveBlock: Int?
    public let caretGeneration: Int
    /// Format command to apply to the current selection (⌘B/⌘I/⌘K/⇧⌘H);
    /// `formatGeneration` bumps to fire.
    public let formatCommand: FormatCommand?
    public let formatGeneration: Int
    /// ⌘↩ / Format ▸ Edit Source: bumps to toggle the block under the
    /// caret between rendered and revealed source.
    public let editSourceToggleGeneration: Int
    /// A block's markdown source slice, for the context menu's Copy
    /// Markdown Source (the render layer holds only the projection).
    public let blockSourceProvider: ((BlockID) -> String?)?
    /// A block's absolute byte range in the document source, so the
    /// coordinator can map a projection selection to a source byte range for
    /// In-Selection replace.
    public let blockSourceRangeProvider: ((BlockID) -> ByteRange?)?
    /// Whether a block is a GFM table per the AST — the single recognizer of
    /// record for the context menu's Table submenu. The render layer holds
    /// only a projection, so it asks the host; gating on the lenient
    /// `TableEditing.parse` would surface the submenu on setext headings and
    /// malformed pipe paragraphs (two-recognizers-diverge, CLAUDE.md).
    public let isTableBlockProvider: ((BlockID) -> Bool)?
    /// The current text selection mapped to a source byte range (nil when
    /// empty or unmappable) — the find bar scopes In-Selection replace to it.
    public let onSelectionSourceRange: ((ByteRange?) -> Void)?
    /// Focus mode: every block except the caret's recedes to a fraction
    /// of its ink. Rendering attributes only — no reflow, no re-render.
    public let focusModeEnabled: Bool
    /// Typewriter scrolling: while typing, the caret's line stays pinned
    /// at a fixed height (~40% of the viewport) instead of drifting to
    /// the fold.
    public let typewriterEnabled: Bool
    /// Fires before an in-document anchor jump with the block at the top
    /// of the viewport — the host records it as back/forward history.
    public let onAnchorJump: ((BlockID?) -> Void)?
    /// Block actions from the context menu (move/duplicate/delete/table).
    public let onBlockCommand: ((BlockID, BlockCommand) -> Void)?
    /// Typing into a document with NO blocks (freshly created, empty):
    /// the host appends the text and the first block materializes around
    /// the caret. Without this, ⌘N produced an untypeable blank pane.
    public let onEmptyDocumentInsert: ((String) -> Void)?
    /// Sentence-granularity focus (iA-Writer-style): dim to the caret's
    /// SENTENCE inside the current block. Only meaningful with focus mode.
    public let focusSentenceScope: Bool
    /// Scroll position as a 0…1 fraction of the document (reading
    /// progress hairline).
    public let onScrollProgress: ((Double) -> Void)?
    /// Whether this editor is the frontmost tab in its window. Keep-alive
    /// tabs share the window's responder chain, so on becoming active the
    /// editor must claim first responder (steal it back from the tab the
    /// user switched away from). Defaults true so single-editor hosts and
    /// tests are unaffected.
    public var isActiveTab: Bool = true
    /// Fires when this editor is torn down (tab switch), reporting its final
    /// scroll + selection so the host can stash it in the persistent model.
    public var onCaptureViewport: ((ViewportSnapshot) -> Void)? = nil
    /// Caret moved WITHIN the active block's revealed source (relative
    /// offset). Bookkeeping only: the host keeps its copy of the caret fresh
    /// so a model-initiated re-render (async image decode) styles the reveal
    /// at the caret's real position — with a stale copy, the revealed span
    /// snapped back to wherever the caret was at activation.
    public var onActiveCaretMoved: ((Int) -> Void)? = nil
    /// Scroll + selection to restore once, when this editor is (re)built for a
    /// tab the user is returning to. Applied only when no block is being
    /// edited — an active block's caret is restored by the model's own path.
    public var restoreViewport: ViewportSnapshot? = nil
    /// Accept/reject a CriticMarkup mark: the whole-mark SOURCE byte range
    /// (from `QuoinAttribute.suggestionRange`) + the chosen action. The host
    /// re-verifies the bytes still parse as that mark before splicing.
    public var onSuggestionAction: ((ByteRange, SuggestionResolver.Action) -> Void)? = nil
    /// Card→document flash: scroll to and ring the mark at this byte offset;
    /// `flashGeneration` bumps to re-fire (same card clicked twice).
    public var flashSuggestionOffset: Int? = nil
    public var flashGeneration: Int = 0
    /// Fallback flash target when no rendered mark matches the offset —
    /// the RESOLUTION pulse: the mark is gone after accept/reject, so the
    /// ring lands on the block the splice happened in.
    public var flashBlockID: BlockID? = nil
    /// Card clicks always center the flashed text; resolution pulses keep
    /// the viewport still when the change is already visible, and scroll
    /// to it exactly like a card click when it is offscreen (user redline:
    /// the pulse must be SEEN).
    public enum FlashScrollBehavior {
        case center
        case centerIfOffscreen
    }
    public var flashScroll: FlashScrollBehavior = .center
    /// Document→card linkage: the caret entered (byte range) or left (nil)
    /// a rendered mark.
    public var onSuggestionCaretLink: ((ByteRange?) -> Void)? = nil
    /// The review-endmatter chip was clicked: open the Review inspector.
    public var onOpenReview: (() -> Void)? = nil
    /// The active block's FULL reveal fragment re-styled for a caret
    /// offset — the same renderer pipeline the reveal used (styler config
    /// AND fallback metrics AND paragraph transplant). The caret-move
    /// restyle consumes this; a bare styler pass dropped the mono font on
    /// the first click into revealed code (the fallback metrics live
    /// outside the styler — screenshots 2026-07-14).
    public var activeFragmentProvider: ((_ caretOffset: Int) -> NSAttributedString?)? = nil

    /// ⌘V of a clipboard image (screenshot, copied bitmap, or copied image
    /// file). The app writes the image into the library's `assets/` folder and
    /// inserts `![](assets/…)` at the caret; returning true means the image was
    /// handled so the plain-text paste is skipped. nil = read-only reader.
    public var onPasteImage: (() -> Bool)? = nil

    /// Soft-wrap long lines to the column (true) or let them run and scroll
    /// horizontally (false) — the Wrap/No-Wrap setting (#R2). Applies to both
    /// the rendered projection and the revealed source, since it's one text
    /// container for both states.
    public var wordWrap: Bool = true

    public init(
        rendered: RenderedDocument,
        theme: Theme = Theme(),
        searchQuery: String = "",
        searchOptions: SearchOptions = SearchOptions(),
        searchInSelection: Bool = false,
        activeMatchOrdinal: Int = 0,
        scrollTarget: BlockID? = nil,
        scrollGeneration: Int = 0,
        onTaskToggle: @escaping (Int) -> Void = { _ in },
        onMatchCount: @escaping (Int) -> Void = { _ in },
        anchorResolver: @escaping (String) -> BlockID? = { _ in nil },
        onTopBlockChange: @escaping (BlockID?) -> Void = { _ in },
        onEditIntent: ((_ relativeRange: ByteRange, _ replacement: String, _ caretDelta: Int?) -> Void)? = nil,
        onActivateBlock: ((BlockID?, CaretHint?, String?) -> Void)? = nil,
        caretInActiveBlock: Int? = nil,
        caretGeneration: Int = 0,
        formatCommand: FormatCommand? = nil,
        formatGeneration: Int = 0,
        editSourceToggleGeneration: Int = 0,
        blockSourceProvider: ((BlockID) -> String?)? = nil,
        blockSourceRangeProvider: ((BlockID) -> ByteRange?)? = nil,
        isTableBlockProvider: ((BlockID) -> Bool)? = nil,
        onSelectionSourceRange: ((ByteRange?) -> Void)? = nil,
        focusModeEnabled: Bool = false,
        typewriterEnabled: Bool = false,
        onAnchorJump: ((BlockID?) -> Void)? = nil,
        onScrollProgress: ((Double) -> Void)? = nil,
        onBlockCommand: ((BlockID, BlockCommand) -> Void)? = nil,
        focusSentenceScope: Bool = false,
        onEmptyDocumentInsert: ((String) -> Void)? = nil,
        isActiveTab: Bool = true,
        onCaptureViewport: ((ViewportSnapshot) -> Void)? = nil,
        restoreViewport: ViewportSnapshot? = nil,
        onActiveCaretMoved: ((Int) -> Void)? = nil,
        onSuggestionAction: ((ByteRange, SuggestionResolver.Action) -> Void)? = nil,
        flashSuggestionOffset: Int? = nil,
        flashGeneration: Int = 0,
        flashBlockID: BlockID? = nil,
        flashScroll: FlashScrollBehavior = .center,
        onAddAnnotation: ((ReviewAuthoring.Kind, BlockID, Int, Int, String) -> Void)? = nil,
        onAddBlockComment: ((BlockID, String) -> Void)? = nil,
        onCommentOnSelection: (() -> Void)? = nil,
        annotationCommand: AnnotationGesture? = nil,
        annotationGeneration: Int = 0,
        onSuggestionCaretLink: ((ByteRange?) -> Void)? = nil,
        onOpenReview: (() -> Void)? = nil,
        activeFragmentProvider: ((_ caretOffset: Int) -> NSAttributedString?)? = nil,
        onPasteImage: (() -> Bool)? = nil,
        wordWrap: Bool = true
    ) {
        self.rendered = rendered
        self.theme = theme
        self.searchQuery = searchQuery
        self.searchOptions = searchOptions
        self.searchInSelection = searchInSelection
        self.activeMatchOrdinal = activeMatchOrdinal
        self.scrollTarget = scrollTarget
        self.scrollGeneration = scrollGeneration
        self.onTaskToggle = onTaskToggle
        self.onMatchCount = onMatchCount
        self.anchorResolver = anchorResolver
        self.onTopBlockChange = onTopBlockChange
        self.onEditIntent = onEditIntent
        self.onActivateBlock = onActivateBlock
        self.caretInActiveBlock = caretInActiveBlock
        self.caretGeneration = caretGeneration
        self.formatCommand = formatCommand
        self.formatGeneration = formatGeneration
        self.editSourceToggleGeneration = editSourceToggleGeneration
        self.blockSourceProvider = blockSourceProvider
        self.blockSourceRangeProvider = blockSourceRangeProvider
        self.isTableBlockProvider = isTableBlockProvider
        self.onSelectionSourceRange = onSelectionSourceRange
        self.focusModeEnabled = focusModeEnabled
        self.typewriterEnabled = typewriterEnabled
        self.onAnchorJump = onAnchorJump
        self.onScrollProgress = onScrollProgress
        self.onBlockCommand = onBlockCommand
        self.focusSentenceScope = focusSentenceScope
        self.onEmptyDocumentInsert = onEmptyDocumentInsert
        self.isActiveTab = isActiveTab
        self.onCaptureViewport = onCaptureViewport
        self.restoreViewport = restoreViewport
        self.onActiveCaretMoved = onActiveCaretMoved
        self.onSuggestionAction = onSuggestionAction
        self.flashSuggestionOffset = flashSuggestionOffset
        self.flashGeneration = flashGeneration
        self.flashBlockID = flashBlockID
        self.flashScroll = flashScroll
        self.onAddAnnotation = onAddAnnotation
        self.onAddBlockComment = onAddBlockComment
        self.onCommentOnSelection = onCommentOnSelection
        self.annotationCommand = annotationCommand
        self.annotationGeneration = annotationGeneration
        self.onSuggestionCaretLink = onSuggestionCaretLink
        self.onOpenReview = onOpenReview
        self.activeFragmentProvider = activeFragmentProvider
        self.onPasteImage = onPasteImage
        self.wordWrap = wordWrap
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        // Explicit TextKit 2 stack.
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container

        let textView = QuoinTextView(frame: .zero, textContainer: container)
        // Editable when editing callbacks are wired; every keystroke is
        // gated through shouldChangeTextIn and routed to the session — the
        // text storage itself is never the source of truth.
        textView.isEditable = onEditIntent != nil
        textView.allowsUndo = false // undo lives in DocumentSession
        textView.isSelectable = true
        textView.isRichText = true
        // macOS smart substitutions rewrite the user's exact bytes behind the
        // source-edit mapping — double-space→". " (the "period with extra
        // spaces" glitch), curly quotes, "--"→em dash, autocorrect. In a
        // byte-lossless plain-text Markdown editor those are wrong by design:
        // what you type is what lands on disk. Turn them all off.
        textView.isAutomaticTextReplacementEnabled = false   // incl. double-space→". "
        textView.isAutomaticQuoteSubstitutionEnabled = false // straight quotes stay straight
        textView.isAutomaticDashSubstitutionEnabled = false  // "--" stays "--", not "—"
        textView.isAutomaticSpellingCorrectionEnabled = false // no autocorrect rewrites
        // Spelling underlines ARE safe here (#26): unlike the substitutions
        // above they only annotate, never rewrite the bytes. Enabled once as
        // the default so the standard Edit ▸ Spelling and Grammar menu can
        // still toggle it per the user's preference. Grammar stays off (noisy).
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false     // don't auto-linkify raw URLs
        textView.isAutomaticDataDetectionEnabled = false     // no date/address detection
        textView.smartInsertDeleteEnabled = false            // no smart copy/paste spacing
        textView.textContainerInset = NSSize(width: theme.contentInset, height: theme.contentInset)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // Default maxSize is the initial frame (zero) — without lifting it the
        // view can never grow taller than the viewport, so nothing scrolls.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        // ⌘A scope: the active block's editable range while editing.
        textView.selectAllScope = { [weak coordinator = context.coordinator] in
            coordinator?.parent.rendered.activeEditableRange
        }
        textView.drawsBackground = true
        textView.backgroundColor = theme.canvas
        textView.linkTextAttributes = [
            .foregroundColor: theme.linkColor,
            .cursor: NSCursor.pointingHand,
        ]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.canvas

        // Track scrolling so the status bar can show the current section.
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            coordinator?.reportTopBlock()
            // Keep the selection popover (#45) glued to its selection as the
            // content scrolls (it's a fixed-frame subview, not scroll-tracked).
            if let tv = coordinator?.textView { coordinator?.updateSelectionToolbar(in: tv) }
        }

        context.coordinator.textView = textView
        context.coordinator.flipTransition = FlipTransitionController(
            scrollView: scrollView, textView: textView)
        textView.onDoubleClick = { [weak coordinator = context.coordinator] index in
            coordinator?.activateEmbedBlock(atCharIndex: index) ?? false
        }
        textView.onDoneChipClick = { [weak coordinator = context.coordinator] in
            guard let coordinator, let textView = coordinator.textView,
                  coordinator.parent.rendered.activeBlockID != nil else { return }
            // ✓ done: commit and close, caret back at its rendered image —
            // the same contract as Escape.
            coordinator.captureDeactivationCaret(in: textView)
            coordinator.parent.onActivateBlock?(nil, nil, nil)
        }
        textView.onContextMenu = { [weak coordinator = context.coordinator] index, menu in
            coordinator?.populateContextMenu(menu, atCharIndex: index)
        }
        textView.onEditingFrameGeometry = { [weak coordinator = context.coordinator] frameBox in
            coordinator?.updatePreviewPanel(editingFrame: frameBox)
        }
        textView.onPasteImage = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onPasteImage?() ?? false
        }
        textView.onSmartPaste = { [weak coordinator = context.coordinator] in
            coordinator?.handleSmartPaste() ?? false
        }
        textView.onLinkHover = { [weak coordinator = context.coordinator] url, rect in
            coordinator?.handleLinkHover(url: url, at: rect)
        }
        textView.updateTrackingAreas()
        Self.applyWrapMode(wordWrap, textView: textView, scrollView: scrollView)
        return scrollView
    }

    /// Wrap/No-Wrap (#R2). Wrap: the container tracks the viewport width so
    /// lines fold to the column. No-wrap: an unlimited-width container + a
    /// horizontally-resizable text view + a horizontal scroller, so long lines
    /// run off and scroll. Idempotent — safe to call every update.
    static func applyWrapMode(_ wrap: Bool, textView: NSTextView, scrollView: NSScrollView) {
        guard let container = textView.textContainer else { return }
        if wrap {
            guard container.widthTracksTextView == false || scrollView.hasHorizontalScroller else { return }
            container.widthTracksTextView = true
            container.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            scrollView.hasHorizontalScroller = false
            // The frame may have grown wide under no-wrap; snap it back so the
            // container re-tracks the viewport instead of staying over-wide.
            textView.setFrameSize(NSSize(width: scrollView.contentSize.width,
                                         height: textView.frame.height))
        } else {
            guard container.widthTracksTextView else { return }
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.height]
            scrollView.hasHorizontalScroller = true
        }
        textView.needsLayout = true
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        Self.applyWrapMode(wordWrap, textView: textView, scrollView: scrollView)

        // View-level chrome follows the theme on every update, so an
        // appearance flip (dark/light) recolors the canvas along with the
        // re-rendered content — makeNSView's values would otherwise stick
        // for the window's lifetime.
        if textView.backgroundColor != theme.canvas {
            textView.backgroundColor = theme.canvas
            scrollView.backgroundColor = theme.canvas
            textView.linkTextAttributes = [
                .foregroundColor: theme.linkColor,
                .cursor: NSCursor.pointingHand,
            ]
        }

        let (caretLineAnchorY, flipMotionID) = applyProjection(
            coordinator: coordinator, textView: textView, in: scrollView)
        // Activation changes invalidate queued keystroke positions.
        if rendered.activeBlockID != coordinator.lastActiveBlockID {
            coordinator.clearPendingKeystrokes()
        }
        coordinator.lastActiveBlockID = rendered.activeBlockID

        restoreActiveCaret(
            coordinator: coordinator, textView: textView, in: scrollView,
            caretLineAnchorY: caretLineAnchorY)

        applyPendingCommands(
            coordinator: coordinator, textView: textView, in: scrollView,
            flipMotionID: flipMotionID)
    }

    /// Apply the changed projection to the live text storage (the viewport
    /// invariant lives here): capture the anchor line the caret is on, freeze
    /// flip pixels, splice only the changed span, collapse a straddling
    /// selection, restore the flip-back caret, and announce the mode change.
    /// Returns the caret-line anchor and flip-motion id the post-splice caret
    /// restore and motion passes need. A no-op (returns nils) when the
    /// revision is unchanged or marked text (IME) is in flight.
    private func applyProjection(
        coordinator: Coordinator, textView: NSTextView, in scrollView: NSScrollView
    ) -> (caretLineAnchorY: CGFloat?, flipMotionID: BlockID?) {
        // THE viewport invariant: the thing the user touched must not move.
        // On a flip (activate/deactivate), the anchor is the LINE THE CARET
        // IS ON — the clicked row of a table, the list item the arrow key
        // just entered — captured before the projection changes and pinned
        // back after, no matter how the block's height changes around it.
        // Only when no caret applies (closing a block to nothing) does the
        // anchor fall back to the flipped block's top edge.
        let flipPending = rendered.activeBlockID != coordinator.lastActiveBlockID
        let caretRestorePending = caretInActiveBlock != nil
            && caretGeneration != coordinator.appliedCaretGeneration
            && rendered.activeEditableRange != nil
        var caretLineAnchorY: CGFloat?
        var flipMotionID: BlockID?

        // IME gate (editor-modes plan, 3.5): while marked text (dead-key or
        // CJK composition) is in flight, replacing the fragment under it is
        // undefined behavior — defer the projection. appliedRevision stays
        // stale, so the NEXT pass applies it; composition normally ends
        // with an insertText → edit → publish, which is that pass. A
        // CANCELLED composition flushes on the next publish instead
        // (documented limitation until the projector owns application).
        if coordinator.appliedRevision != rendered.revision,
           !textView.hasMarkedText(),
           let storage = textView.textContentStorage?.textStorage {
            let anchorID = coordinator.topVisibleBlockID(in: textView)
            let viewport = scrollView.contentView.bounds.height
            if flipPending, caretRestorePending {
                let selection = min(textView.selectedRange().location, max(0, storage.length - 1))
                if let screenY = coordinator.lineScreenY(at: selection, in: textView),
                   screenY > -viewport, screenY < viewport * 2 {
                    caretLineAnchorY = screenY
                }
                QuoinPerformanceTrace.log(
                    "anchor.capture", startedAt: DispatchTime.now().uptimeNanoseconds,
                    metadata: "sel=\(selection) anchorY=\(caretLineAnchorY.map { Int($0) } ?? -999) clipY=\(Int(scrollView.contentView.bounds.origin.y))")
            } else if flipPending {
                QuoinPerformanceTrace.log(
                    "anchor.capture.skipped", startedAt: DispatchTime.now().uptimeNanoseconds,
                    metadata: "caretRestorePending=\(caretRestorePending) caretInActive=\(caretInActiveBlock ?? -1) gen=\(caretGeneration)")
            }
            // Fallback anchor for caret-less flips (Esc closing a block).
            var flipAnchor: (id: BlockID, screenY: CGFloat)?
            if flipPending, caretLineAnchorY == nil,
               let flipID = rendered.activeBlockID ?? coordinator.lastActiveBlockID,
               let oldRange = coordinator.blockRanges[flipID],
               let screenY = coordinator.blockTopScreenY(oldRange, in: textView) {
                // Only pin when the flip is near the viewport — a far-away
                // programmatic flip shouldn't drag the scroll position to it.
                if screenY > -viewport * 2, screenY < viewport * 2 {
                    flipAnchor = (flipID, screenY)
                }
            }
            // Motion (embed-editing brief, Phase 3): freeze the current
            // pixels before the splice so the flip can animate. A non-flip
            // projection (typing) instead truncates any transition still
            // running — a storage mutation invalidates frozen pixels.
            if flipPending,
               let flipID = rendered.activeBlockID ?? coordinator.lastActiveBlockID,
               let oldRange = coordinator.blockRanges[flipID],
               let oldRect = coordinator.blockScreenRect(oldRange, in: textView),
               oldRect.minY < viewport, oldRect.maxY > 0,
               coordinator.flipCaptureWorthwhile(
                   oldBlockRect: oldRect, flipID: flipID, rendered: rendered,
                   viewportHeight: viewport, in: textView) {
                flipMotionID = flipID
                coordinator.flipTransition?.capture(oldBlockRect: oldRect)
            } else {
                coordinator.flipTransition?.cancel()
            }
            coordinator.suppressSelectionCallback = true
            let preSelection = textView.selectedRange()
            let preLength = storage.length
            // Splice only the changed span into the live storage rather than
            // replacing the whole document. TextKit 2 then re-lays-out just
            // that region, so unchanged content keeps its exact layout and the
            // scroll offset never jumps.
            let application = QuoinPerformanceTrace.measure(
                "render.textkit.splice",
                metadata: "old_utf16=\(storage.length) new_utf16=\(rendered.attributed.length) hinted=\(rendered.spliceHint != nil) patched=\(rendered.storagePatches.count)"
            ) {
                Coordinator.applyProjection(rendered, to: storage)
            }
            let splicedRange: NSRange?
            switch application {
            case .patched(let patches):
                splicedRange = patches.first.map {
                    NSRange(location: $0.oldRange.location, length: $0.replacement.length)
                }
                // Bounded edits: adjust the decoration runs in place instead
                // of rescanning the whole document's attributes on the next
                // draw.
                for patch in patches {
                    (textView as? QuoinTextView)?.noteStorageEdit(
                        oldRange: patch.oldRange, newLength: patch.replacement.length)
                }
            case .spliced(let range):
                splicedRange = range
                // Unbounded change (full replace, computed splice, or the
                // stale-patch resync): runs rebuild from scratch on the
                // next draw.
                QuoinPerformanceTrace.measure("render.decorations.invalidate") {
                    (textView as? QuoinTextView)?.invalidateDecorations()
                }
            }
            // Kill estimated geometry while the document is small enough to
            // lay out eagerly (a few ms at tens of KB): TextKit 2's lazy
            // estimates RESOLVE on click (hit-testing forces layout), and
            // the resolved heights shift the content under the pointer — a
            // viewport jump no delegate ever sees, on any block type. Large
            // documents keep lazy layout (the anchor + settle passes handle
            // them); typical documents simply never lie.
            if storage.length < 200_000,
               let layoutManager = textView.textLayoutManager,
               let contentStorage = textView.textContentStorage {
                QuoinPerformanceTrace.measure(
                    "render.textkit.eagerLayout", metadata: "utf16=\(storage.length)"
                ) {
                    layoutManager.ensureLayout(for: contentStorage.documentRange)
                }
            }
            // A range selection straddling the changed region has no meaning
            // in the new text — AppKit clamps the stale indexes into whatever
            // the splice put there, which reads as a random selection.
            // Collapse it to its start; selections clear of the change (and
            // all carets) survive untouched. The caret-restore paths below
            // override this when they apply.
            if let collapsed = Coordinator.collapsedSelection(
                preSelection,
                changedOldRange: Coordinator.changedOldRange(
                    for: application, oldLength: preLength, newLength: storage.length),
                newLength: storage.length
            ) {
                textView.setSelectedRange(collapsed)
            }
            coordinator.renderedGeneration = rendered.attributed
            coordinator.appliedRevision = rendered.revision
            coordinator.blockRanges = rendered.blockRanges
            // Flip-back caret: the closing block's caret returns to the
            // rendered image of its source position (Escape/⌘↩/Done). The
            // selection is otherwise left wherever the splice pushed it —
            // an unspecified spot the next keystroke would act on.
            if let pending = coordinator.pendingDeactivationCaret {
                coordinator.pendingDeactivationCaret = nil
                if rendered.activeBlockID == nil,
                   let range = rendered.blockRanges[pending.id],
                   NSMaxRange(range) <= storage.length {
                    let location = coordinator.flipBackCaretLocation(
                        blockRange: range,
                        storage: storage,
                        sourceOffset: pending.sourceOffset,
                        sourceText: pending.sourceText
                    )
                    textView.setSelectedRange(NSRange(location: location, length: 0))
                }
            }
            if let flipAnchor, let newRange = rendered.blockRanges[flipAnchor.id] {
                // Caret-less flip: pin the flipped block's top edge; this
                // also forces real layout for the spliced region, so the
                // first paint uses settled geometry instead of estimates.
                coordinator.scrollBlockTop(newRange, toScreenY: flipAnchor.screenY, in: textView)
            } else if splicedRange == nil, caretInActiveBlock == nil,
                      let anchorID, let range = rendered.blockRanges[anchorID] {
                // Re-anchor only on a full/large replacement (splice returned
                // nil); an in-place splice preserves the viewport by
                // construction.
                textView.scrollRangeToVisible(range)
            }
            coordinator.suppressSelectionCallback = false
            coordinator.appliedQuery = nil // force re-highlight on new content
            // The draw-pass geometry callback is deduped by rect (perf
            // #10); a projection can change the preview panel's CONTENT
            // behind an unchanged frame, so re-plan it here.
            coordinator.refreshPreviewPanelForProjectionChange()
            // VoiceOver hears the mode change (never announced by tint
            // alone): entering/leaving source editing.
            if flipPending {
                NSAccessibility.post(
                    element: textView,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: rendered.activeBlockID != nil
                            ? "Editing source" : "Done editing",
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                    ]
                )
            }
        }
        return (caretLineAnchorY, flipMotionID)
    }

    /// Restore the caret into the active block after an edit round-trip, then
    /// hold its line where the user was looking. Deferred during IME
    /// composition (3.5): `setSelectedRange` would discard marked text. The
    /// three positioning modes are the viewport invariant in miniature — a
    /// flip pins to the captured anchor line, typewriter mode holds a fixed
    /// height, and an ordinary edit scrolls only if the caret left the viewport.
    private func restoreActiveCaret(
        coordinator: Coordinator, textView: NSTextView, in scrollView: NSScrollView,
        caretLineAnchorY: CGFloat?
    ) {
        guard let caret = caretInActiveBlock,
              caretGeneration != coordinator.appliedCaretGeneration,
              !textView.hasMarkedText(),
              let active = rendered.activeEditableRange
        else { return }
        coordinator.appliedCaretGeneration = caretGeneration
        let location = min(active.location + caret, active.location + active.length)
        coordinator.suppressSelectionCallback = true
        textView.setSelectedRange(NSRange(location: location, length: 0))
        if let caretLineAnchorY {
            // Flip: the caret's line goes back exactly where the user
            // was looking (the clicked table row, the list item the
            // arrow key entered) regardless of the height change. The
            // revealed block's full range is laid out first so the pin
            // measures real geometry, not estimates.
            coordinator.pinCaretLine(
                at: location, toScreenY: caretLineAnchorY, in: textView,
                ensuringLayoutOf: rendered.activeBlockID.flatMap { rendered.blockRanges[$0] })
        } else if typewriterEnabled, rendered.activeBlockID != nil {
            // Typewriter scrolling (idea #1): while typing, the
            // caret's line holds a fixed height — the page moves, the
            // eye doesn't. Reuses the viewport-invariant pin.
            let anchorY = scrollView.contentView.bounds.height * 0.4
            coordinator.pinCaretLine(
                at: location, toScreenY: anchorY, in: textView, settle: false)
        } else {
            // Edit round-trip: scroll ONLY if the caret left the
            // viewport, and then by the minimal amount — arrowing and
            // typing must never lurch.
            coordinator.scrollCaretIntoViewIfNeeded(location, in: textView)
        }
        coordinator.suppressSelectionCallback = false
        if textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
        // The edit's echo has fully landed (projection + caret):
        // release the next queued keystroke (ledger #11).
        coordinator.noteEditEchoApplied(in: textView)
    }

    /// The generation-fired commands that run after the projection settles:
    /// flip-motion choreography, search, format, edit-source toggle, focus
    /// dimming, first-responder claims, annotation, flash, scroll target, and
    /// viewport restore. Each is edge-triggered on its own generation so it
    /// fires once per request. Ordering matters — motion measures the settled
    /// geometry the splice produced, and the focus/scroll passes run last.
    private func applyPendingCommands(
        coordinator: Coordinator, textView: NSTextView, in scrollView: NSScrollView,
        flipMotionID: BlockID?
    ) {
        // Motion, second half: with the splice applied and the pin's settle
        // pass already queued, measure the flipped block's REAL new
        // geometry and start the choreography — its animations enqueue
        // behind the settle, so they converge on truth, never estimates.
        if let flipMotionID,
           let newRange = rendered.blockRanges[flipMotionID],
           let storage = textView.textContentStorage?.textStorage,
           let newRect = coordinator.blockScreenRect(newRange, in: textView) {
            coordinator.flipTransition?.run(newBlockRect: newRect, documentLength: storage.length)
        } else if flipMotionID != nil {
            coordinator.flipTransition?.cancel()
        }

        QuoinPerformanceTrace.measure("render.search.apply", metadata: "query_empty=\(searchQuery.isEmpty)") {
            coordinator.applySearch(
                query: searchQuery, activeOrdinal: activeMatchOrdinal,
                options: searchOptions, inSelection: searchInSelection)
        }

        if let formatCommand, formatGeneration != coordinator.appliedFormatGeneration {
            coordinator.appliedFormatGeneration = formatGeneration
            coordinator.applyFormat(formatCommand, in: textView)
        }

        if editSourceToggleGeneration != coordinator.appliedEditSourceToggleGeneration {
            coordinator.appliedEditSourceToggleGeneration = editSourceToggleGeneration
            coordinator.toggleEditSource(in: textView)
        }

        // Focus mode: re-derive the dimming whenever the projection, the
        // caret, or the toggle changed (rendering attributes — no layout).
        coordinator.applyFocusDimming(in: textView, theme: theme)

        // A freshly opened document must be TYPEABLE immediately — ⌘N
        // then typing did nothing until a manual click (field report).
        // Claim first responder exactly once, when the window exists. Only
        // the frontmost tab claims — a background keep-alive editor must not
        // steal focus from the visible one at launch.
        if isActiveTab, !coordinator.hasClaimedInitialFocus, let window = textView.window {
            coordinator.hasClaimedInitialFocus = true
            if window.firstResponder === window || window.firstResponder == nil {
                window.makeFirstResponder(textView)
            }
        }

        // Tab switch: the newly-frontmost editor claims first responder,
        // taking it back from the (still-alive) editor the user just left.
        // Edge-triggered on the false→true transition so it never fights the
        // find field or a deliberate click within the active tab. Only
        // recorded once the window exists, so the grab stays armed through a
        // window-less first pass (a tab opened at runtime).
        if let window = textView.window {
            if isActiveTab, !coordinator.wasActiveTab, window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
            coordinator.wasActiveTab = isActiveTab
        }

        if let annotationCommand, annotationGeneration != coordinator.appliedAnnotationGeneration {
            coordinator.appliedAnnotationGeneration = annotationGeneration
            coordinator.beginAnnotation(annotationCommand, in: textView)
        }

        if let flashSuggestionOffset, flashGeneration != coordinator.appliedFlashGeneration {
            coordinator.appliedFlashGeneration = flashGeneration
            coordinator.flashSuggestionMark(
                byteOffset: flashSuggestionOffset, fallbackBlockID: flashBlockID,
                scroll: flashScroll, in: textView)
        }

        if let scrollTarget, scrollGeneration != coordinator.appliedScrollGeneration {
            coordinator.appliedScrollGeneration = scrollGeneration
            if let range = rendered.blockRanges[scrollTarget] {
                QuoinPerformanceTrace.measure("render.scroll.target") {
                    coordinator.scrollBlockToTop(range, in: textView)
                }
            }
        }

        // Returning to a tab (#22): restore where the user was reading, exactly
        // once, after content is laid out. Skipped while a block is being
        // edited — the model's caret path (above) owns that positioning, and a
        // reveal changes the coordinate space the saved selection lived in.
        if !coordinator.hasRestoredViewport,
           let snapshot = restoreViewport,
           rendered.activeBlockID == nil {
            coordinator.hasRestoredViewport = true
            let length = textView.textContentStorage?.textStorage?.length ?? 0
            let loc = min(snapshot.selection.location, length)
            let len = min(snapshot.selection.length, length - loc)
            coordinator.suppressSelectionCallback = true
            textView.setSelectedRange(NSRange(location: loc, length: len))
            coordinator.suppressSelectionCallback = false
            // Scroll after TextKit 2 settles the (lazy) layout height, else the
            // target clamps against a not-yet-grown document.
            let restoreScroll = { [weak scrollView, weak textView] in
                guard let scrollView, let textView else { return }
                let viewport = scrollView.contentView.bounds.height
                let maxY = max(0, textView.frame.height - viewport)
                let y = min(max(0, snapshot.scrollY), maxY)
                textView.scroll(NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            restoreScroll()
            DispatchQueue.main.async(execute: restoreScroll)
        }
    }

    /// The editor is being torn down (the host switched tabs). Capture the
    /// final scroll + selection so the persistent model can hand it back when
    /// this tab is shown again (#22).
    public static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        // Popovers, the hover dwell, and a mid-fade flash ring are all
        // anchored to the dying text view — close them here or a shown
        // popover floats on as an orphaned panel (#72).
        coordinator.teardownTransientChrome()
        guard let textView = coordinator.textView else { return }
        coordinator.parent.onCaptureViewport?(
            ViewportSnapshot(
                scrollY: scrollView.contentView.bounds.origin.y,
                selection: textView.selectedRange()))
    }

}
#endif
