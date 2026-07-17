import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuoinCore
import QuoinRender

/// One document window, laid out per the design handoff: editor center
/// (max 680pt column), outline panel as a trailing inspector (⌥⌘0),
/// find bar, and a status bar with section + live statistics.
/// The library sidebar arrives in Phase D.
struct ReaderScreen: View {
    /// The document's model, owned by `OpenDocumentStore` (one per file across
    /// all windows/tabs), NOT by this view. The view is a projection that
    /// comes and goes as tabs switch; the model — and its live session and undo
    /// history — outlives it in the store (#12/#22).
    let model: ReaderModel
    let fileURL: URL?
    /// Fresh per body evaluation: `Theme()` captures the CURRENT appearance,
    /// and reading `colorScheme` below is what makes SwiftUI re-evaluate
    /// this view when the appearance flips (system or Settings preference).
    private var theme: Theme { Theme() }
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("QuoinShowStatusBar") private var showStatusBar = true
    /// Code-canvas theme (#63): colors are BAKED into the projection, so a
    /// change must re-render, same as an appearance flip.
    @AppStorage("QuoinCodeTheme") private var codeTheme = "match"
    @AppStorage("QuoinTextScale") private var textScale = 1.0
    /// Wrap long lines to the column, or let them run with a horizontal
    /// scroller (#R2). Applies to rendered + revealed source alike.
    @AppStorage("QuoinWordWrap") private var wordWrap = true

    @State private var formatCommand: FormatCommand?
    @State private var formatGeneration = 0
    @State private var editSourceToggleGeneration = 0

    @State private var isOutlineVisible = true
    /// Inspector mode: the trailing panel hosts Outline, Review
    /// (suggestions §3.5, redlined 2026-07-14: the in-canvas rail felt
    /// weird and needed a very wide window — the inspector works at every
    /// width), or Properties (#70: the front-matter field editor; the
    /// in-document grid stays the projection). Auto-selects Review when a
    /// document carries marks and the user hasn't chosen this session.
    private enum InspectorMode: String { case outline, review, properties }
    @State private var inspectorMode: InspectorMode = .outline
    @State private var userPickedInspectorMode = false
    /// Card→document flash command (generation-fired, like scrollTarget).
    @State private var flashSuggestionOffset: Int?
    @State private var flashGeneration = 0
    /// Where the flash may fall back to (block containing the offset) and
    /// how it scrolls (card clicks always center; resolution pulses center
    /// only when the change is offscreen).
    @State private var flashBlockID: BlockID?
    @State private var flashScroll: MarkdownReaderView.FlashScrollBehavior = .center
    /// S3a annotation gesture from the Format ▸ Review menu (⇧⌘M / ⇧⌘R),
    /// generation-fired into the coordinator like formatCommand.
    @State private var annotationCommand: MarkdownReaderView.AnnotationGesture?
    @State private var annotationGeneration = 0
    /// Document→card linkage: the mark the caret is inside.
    @State private var linkedMark: ByteRange?
    @State private var isExportVisible = false
    // Writing-environment modes are PER-WINDOW (#29): toggling Focus in one
    // document must not flip every open window. @SceneStorage scopes them to
    // this window (shared across its tabs, restored per window), where
    // @AppStorage was one global switch for the whole app. The View-menu
    // items reach these through focused values + toggle notifications, since
    // app-level Commands can't read @SceneStorage.
    /// Focus mode: everything but the paragraph you're on recedes.
    @SceneStorage("QuoinFocusMode") private var isFocusMode = false
    /// Typewriter scrolling: the caret line holds a fixed height.
    @SceneStorage("QuoinTypewriter") private var isTypewriter = false
    /// Sentence-granularity focus (only meaningful with focus mode on).
    @SceneStorage("QuoinFocusSentence") private var isSentenceFocus = false
    /// Word-count goal (0 = off): progress shows in the status bar. Stays a
    /// GLOBAL @AppStorage — it is a persistent writing target surfaced in
    /// Settings (Advanced ▸ Writing), not a per-window view mode; scoping it
    /// per-window would silently disconnect that Settings control.
    @AppStorage("QuoinWordGoal") private var wordGoal = 0
    /// Jump history (TOC clicks, anchor links, breadcrumbs): ⌘[ / ⌘].
    @State private var backStack: [BlockID] = []
    @State private var forwardStack: [BlockID] = []
    /// Reading progress, 0…1 (hairline under the toolbar).
    @State private var scrollProgress: Double = 0
    @State private var isFindVisible = false
    @State private var isReplaceVisible = false
    @State private var replaceText = ""
    /// Transient "Replaced N" feedback after a replace, cleared when the query
    /// changes so a stale count can't linger.
    @State private var replaceStatus: String?
    @FocusState private var replaceFieldFocused: Bool
    @State private var searchQuery = ""
    // Find options (#23). The three match rules persist across sessions and
    // documents (sticky like every editor's find bar); In-Selection is
    // transient — it means "this selection, right now".
    @AppStorage("find.matchCase") private var findMatchCase = false
    @AppStorage("find.wholeWord") private var findWholeWord = false
    @AppStorage("find.regex") private var findRegex = false
    @State private var findInSelection = false
    @State private var activeMatch = 0
    @State private var matchCount = 0
    @State private var scrollTarget: BlockID?
    @State private var scrollGeneration = 0
    @State private var topBlockID: BlockID?
    @FocusState private var findFieldFocused: Bool
    /// Menu actions must land in the KEY window only (launch ledger
    /// BLOCKER: with two windows, ⌘Z used to undo in both documents).
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    // The status strip is `.clipped()` to a fixed height so misbehaving
    // bridged controls can't inflate it; that same clip would guillotine the
    // scaled status text, so the height grows with Dynamic Type too (#28).
    @ScaledMetric(relativeTo: .body) private var statusBarHeight: CGFloat = 22

    private var isKeyWindow: Bool { controlActiveState == .key }

    /// The review rail's cards, recomputed per projection (cheap: a walk of
    /// the parsed marks + metadata join).
    private var reviewItems: [ReviewItem] {
        SuggestionResolver.reviewItems(in: model.document)
    }
    private var resolvedRecords: [ResolvedRecord] {
        ReviewEndmatter.resolvedRecords(in: model.document)
    }
    private var reviewCounts: (suggestions: Int, comments: Int) {
        let items = reviewItems.filter { !$0.isResolved }
        let suggestions = items.filter(\.isSuggestion).count
        return (suggestions, items.count - suggestions)
    }
    private var hasReviewData: Bool { !reviewItems.isEmpty || !resolvedRecords.isEmpty }
    /// The Properties panel's rows, recomputed per projection (a cheap
    /// line walk of the front-matter block).
    private var frontMatterFields: [FrontMatterEditing.Field] {
        FrontMatterEditing.fields(in: model.document.source)
    }

    var body: some View {
        // Split into layout → chrome → menu wiring: one flat modifier
        // chain here exceeds the type-checker's budget.
        menuObservers(windowChrome(panelChrome(layout)))
    }

    private var layout: some View {
        VStack(spacing: 0) {
            if isFindVisible {
                findBar
            }
            if model.conflictDiskSource != nil {
                conflictBanner
            }
            if let failure = model.actionFailure {
                actionFailureBanner(failure)
            }
            ZStack(alignment: .topTrailing) {
            MarkdownReaderView(
                rendered: model.rendered,
                theme: theme,
                searchQuery: isFindVisible ? searchQuery : "",
                searchOptions: searchOptions,
                searchInSelection: findInSelection,
                activeMatchOrdinal: activeMatch,
                scrollTarget: scrollTarget,
                scrollGeneration: scrollGeneration,
                onTaskToggle: { offset in model.toggleTask(markerOffset: offset) },
                onMatchCount: { count in
                    matchCount = count
                    if activeMatch >= count { activeMatch = 0 }
                },
                anchorResolver: { slug in model.blockID(forSlug: slug) },
                onTopBlockChange: { top in topBlockID = top },
                onEditIntent: { range, replacement, caretDelta in
                    model.applyEdit(relativeRange: range, replacement: replacement, caretDelta: caretDelta)
                },
                onActivateBlock: { id, caretHint, pendingInsertion in
                    model.activateBlock(id, caretHint: caretHint, pendingInsertion: pendingInsertion)
                },
                caretInActiveBlock: model.caretInActiveBlock,
                caretGeneration: model.caretGeneration,
                formatCommand: formatCommand,
                formatGeneration: formatGeneration,
                editSourceToggleGeneration: editSourceToggleGeneration,
                blockSourceProvider: { id in
                    model.document.blocks.first { $0.id == id }
                        .flatMap { model.document.source.substring(in: $0.range) }
                },
                blockSourceRangeProvider: { id in
                    model.document.blocks.first { $0.id == id }?.range
                },
                isTableBlockProvider: { id in
                    if case .table = model.document.blocks.first(where: { $0.id == id })?.kind {
                        return true
                    }
                    return false
                },
                onSelectionSourceRange: { range in model.selectionSourceRange = range },
                focusModeEnabled: isFocusMode,
                typewriterEnabled: isTypewriter,
                onAnchorJump: { from in recordJump(from: from) },
                onScrollProgress: { progress in scrollProgress = progress },
                onBlockCommand: { id, command in model.perform(command, on: id) },
                focusSentenceScope: isSentenceFocus,
                onEmptyDocumentInsert: { text in model.insertIntoEmptyDocument(text) },
                onCaptureViewport: { snapshot in model.savedViewport = snapshot },
                restoreViewport: model.savedViewport,
                onActiveCaretMoved: { offset in model.noteActiveCaretMoved(offset) },
                onSuggestionAction: { range, action in model.resolveSuggestion(markRange: range, action: action) },
                flashSuggestionOffset: flashSuggestionOffset,
                flashGeneration: flashGeneration,
                flashBlockID: flashBlockID,
                flashScroll: flashScroll,
                onAddAnnotation: { kind, blockID, relStart, relEnd, renderedText in
                    model.addAnnotation(
                        kind: kind, blockID: blockID,
                        renderedStart: relStart, renderedEnd: relEnd,
                        renderedText: renderedText)
                },
                onAddBlockComment: { blockID, body in
                    model.addBlockComment(blockID: blockID, body: body)
                },
                annotationCommand: annotationCommand,
                annotationGeneration: annotationGeneration,
                onSuggestionCaretLink: { range in linkedMark = range },
                onOpenReview: {
                    isOutlineVisible = true
                    inspectorMode = .review
                    userPickedInspectorMode = true
                },
                activeFragmentProvider: { caret in model.restyledActiveFragment(caretOffset: caret) },
                onPasteImage: { model.insertPastedImage() },
                wordWrap: wordWrap
            )
            // Dropping an image file copies it into assets/ and inserts
            // the markdown reference at the caret.
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                var handled = false
                for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    handled = true
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let url: URL?
                        if let data = item as? Data {
                            url = URL(dataRepresentation: data, relativeTo: nil)
                        } else {
                            url = item as? URL
                        }
                        guard let url else { return }
                        if ReaderModel.imageExtensions.contains(url.pathExtension.lowercased()) {
                            Task { @MainActor in model.insertImage(from: url) }
                        } else if url.pathExtension.lowercased() == "md" {
                            // Dropping a markdown file on the editor OPENS
                            // it (UI #21) — inserting its bytes would be
                            // surprising; a tab is what the gesture means.
                            Task { @MainActor in
                                AppDelegate.requestOpen(url)
                            }
                        }
                    }
                }
                return handled
            }
            // Format pill (handoff: B/I/U, radius 14, hairline border,
            // floats over the content at the top of the editor).
            formatPill
                .padding(.top, 10)
                .padding(.trailing, 16)
            }
            // Reading progress hairline (idea #12) sits on the EDITOR's
            // top edge — on the window edge it overlapped the find bar.
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: proxy.size.width * scrollProgress, height: 2)
                }
                .frame(height: 2)
                .allowsHitTesting(false)
            }
            if showStatusBar {
                statusBar
            }
        }
    }

    private func panelChrome(_ content: some View) -> some View {
        content
        .onChange(of: colorScheme) {
            // Appearance flipped (system or the Settings preference): the
            // rendered projection has the old palette baked into its
            // attributed string, so the model must re-render with a fresh
            // Theme.
            model.refreshTheme()
        }
        .onChange(of: codeTheme) {
            model.refreshTheme()
        }
        // Text zoom (⌘+/⌘−/⌃⌘0): Theme() reads QuoinTextScale, so a change
        // re-renders the projection at the new size.
        .onChange(of: textScale) {
            model.refreshTheme()
        }
        .inspector(isPresented: $isOutlineVisible) {
            VStack(spacing: 0) {
                // The open count lives OUTSIDE the picker as an accent
                // badge: NSSegmentedControl flattens styled text, so a
                // count inside the segment could only ever render as
                // plain "Review 4" (user redline) — and the badge
                // doubles as the still-work-to-do indicator (#58). The
                // Review segment appears only when review data exists;
                // Outline and Properties are always available (#70).
                HStack(spacing: 6) {
                    Picker("", selection: Binding(
                        get: { inspectorMode },
                        set: { inspectorMode = $0; userPickedInspectorMode = true }
                    )) {
                        Text("Outline").tag(InspectorMode.outline)
                        if hasReviewData {
                            Text("Review").tag(InspectorMode.review)
                        }
                        Text("Properties").tag(InspectorMode.properties)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    let open = reviewItems.filter { !$0.isResolved }.count
                    if open > 0 {
                        Text("\(open)")
                            .quoinScaledFont(size: 10, weight: .semibold, design: .rounded)
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor, in: Capsule())
                            // The capsule must never clip: at the inspector's
                            // 180pt minimum the bridged segmented control's
                            // rigid intrinsic width otherwise squeezes the
                            // badge into a partial curve. Incompressible badge;
                            // the PICKER truncates its segment titles instead.
                            .fixedSize()
                            .layoutPriority(1)
                            .accessibilityLabel("\(open) open review items")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                if inspectorMode == .properties {
                    PropertiesPanel(
                        fields: frontMatterFields,
                        onSet: { key, value in model.setFrontMatterField(key: key, value: value) },
                        onSetTyped: { key, rawValue in
                            model.setTypedFrontMatterField(key: key, rawValue: rawValue)
                        },
                        onRemove: { key in model.removeFrontMatterField(key: key) }
                    )
                } else if inspectorMode == .review, hasReviewData {
                    ReviewPanel(
                        items: reviewItems,
                        resolved: resolvedRecords,
                        linked: linkedMark,
                        onResolve: { range, action in
                            model.resolveSuggestion(markRange: range, action: action)
                        },
                        onResolveAll: { action in
                            model.resolveAllSuggestions(action: action)
                        },
                        onFocus: { range in
                            // The flash handler centers the mark in the
                            // viewport and rings it — a block-level jump
                            // here would fight that scroll (it top-aligned;
                            // user redline).
                            flashSuggestionOffset = range.offset
                            flashBlockID = model.blockID(containingByteOffset: range.offset)
                            flashScroll = .center
                            flashGeneration += 1
                        }
                    )
                } else {
                    OutlinePanel(
                        outline: model.outline,
                        currentSectionID: currentSection?.id
                    ) { headingID in
                        jump(to: headingID)
                    }
                }
            }
            .inspectorColumnWidth(min: 180, ideal: 240, max: 340)
            .onChange(of: reviewItems.isEmpty && resolvedRecords.isEmpty) { _, empty in
                // The Review segment vanished from under its own selection;
                // Properties keeps its seat.
                if empty, inspectorMode == .review { inspectorMode = .outline }
            }
            // Marks ARRIVING while the inspector sits on Outline surface
            // themselves (panel review: auto-switch only fired on appear).
            .onChange(of: reviewItems.isEmpty) { was, isEmpty in
                if was, !isEmpty, !userPickedInspectorMode {
                    inspectorMode = .review
                }
            }
            // Resolution applied: pulse the splice location in place — the
            // "something happened, and HERE" cue (user ask). Never scrolls.
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.addCommentNotification)) { _ in
                guard isKeyWindow else { return }
                annotationCommand = .comment
                annotationGeneration += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.suggestReplacementNotification)) { _ in
                guard isKeyWindow else { return }
                annotationCommand = .replacement
                annotationGeneration += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.suggestDeletionNotification)) { _ in
                guard isKeyWindow else { return }
                annotationCommand = .deletion
                annotationGeneration += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.reviewHighlightNotification)) { _ in
                guard isKeyWindow else { return }
                annotationCommand = .highlight
                annotationGeneration += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleSuggestModeNotification)) { _ in
                guard isKeyWindow else { return }
                model.isSuggestMode.toggle()
            }
            .onChange(of: model.resolutionFlashGeneration) {
                guard let offset = model.resolutionFlashOffset else { return }
                flashSuggestionOffset = offset
                flashBlockID = model.blockID(containingByteOffset: offset)
                flashScroll = .centerIfOffscreen
                flashGeneration += 1
            }
            .onAppear {
                if !reviewItems.isEmpty, !userPickedInspectorMode {
                    inspectorMode = .review
                }
            }
        }
    }

    private func windowChrome(_ content: some View) -> some View {
        content
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isFocusMode.toggle()
                } label: {
                    Label("Focus", systemImage: isFocusMode ? "scope" : "circle.dashed")
                }
                .help(isFocusMode ? "Leave focus mode" : "Focus mode: dim everything but the current paragraph")
                if let fileURL {
                    ShareLink(item: fileURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share this document (AirDrop, Mail, Messages…)")
                }
                Button {
                    isExportVisible = true
                } label: {
                    Label("Export", systemImage: "arrow.up.doc")
                }
                .help("Export as Markdown, HTML, or PDF (⇧⌘E)")
                Button {
                    isOutlineVisible.toggle()
                } label: {
                    Label("Outline", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the outline (⌥⌘0)")
            }
        }
        .sheet(isPresented: $isExportVisible) {
            ExportSheet(
                documentName: fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled",
                document: model.document,
                documentDirectory: (model.fileURL ?? fileURL)?.deletingLastPathComponent(),
                isPresented: $isExportVisible
            )
        }
        .navigationTitle((model.fileURL ?? fileURL)?.deletingPathExtension().lastPathComponent ?? "Untitled")
        // Titlebar document proxy: drag the file icon, ⌘-click the title
        // for the path — table-stakes Mac behavior (launch ledger UI #14).
        .navigationDocument(ifPresent: model.fileURL ?? fileURL)
        .onAppear {
            // The model's lifecycle (start/stop) and rename handler belong to
            // OpenDocumentStore — this view only projects it. Do NOT start or
            // stop here, or a tab switch would fight the store over the session.
            // Screenshot automation presets (see MainWindow.applyShotState).
            switch UserDefaults.standard.string(forKey: "QuoinShotState") {
            case "review":
                // Review inspector showing the suggestion/comment cards.
                // A Task lets the panelChrome auto-select settle first, then
                // this pins the chosen mode (userPicked wins over auto).
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.2))
                    isOutlineVisible = true
                    inspectorMode = .review
                    userPickedInspectorMode = true
                }
            case "properties":
                // Properties inspector (front-matter field editor, #70).
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.2))
                    isOutlineVisible = true
                    inspectorMode = .properties
                    userPickedInspectorMode = true
                }
            case "reviewmode":
                // Review Mode active: the accent SUGGESTING status chip
                // (design §3.6) plus the review inspector for context.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.2))
                    isOutlineVisible = true
                    inspectorMode = .review
                    userPickedInspectorMode = true
                    model.isSuggestMode = true
                }
            case "codethemes":
                // Scroll the first fenced code block into view so the shot
                // captures the selected code theme (pass -QuoinCodeTheme <id>
                // as a launch arg; the argument domain wins without polluting
                // the persisted preference).
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let block = model.document.blocks.first(where: {
                        if case .codeBlock = $0.kind { return true }
                        return false
                    }) else { return }
                    scrollTarget = block.id
                    scrollGeneration += 1
                }
            case "footnotes":
                // Scroll the first footnote reference into view (click-to-jump
                // + hover preview, #80). The reference renders as a raised
                // marker; the definitions gather at the document end.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let block = model.document.blocks.first(where: {
                        model.document.source.substring(in: $0.range)?.contains("[^") ?? false
                    }) else { return }
                    scrollTarget = block.id
                    scrollGeneration += 1
                }
            case "find":
                isFindVisible = true
                searchQuery = "math"
            case "export":
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    isExportVisible = true
                }
            case "mermaidResilience":
                // Self-driving repro for the live-preview resilience loop
                // (ledger #6/#8 family): open the first chart's source,
                // break its header, then fix it — with QUOIN_EDIT_PERF_LOG
                // the panel.update traces record what the panel actually
                // showed at each step.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard let block = model.document.blocks.first(where: {
                        if case .mermaid = $0.kind { return true }
                        return false
                    }) else { return }
                    model.activateBlock(block.id, caretHint: .source(0))
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let active = model.activeBlockID,
                          let activeBlock = model.document.blocks.first(where: { $0.id == active }),
                          let slice = model.document.source.substring(in: activeBlock.range),
                          let range = slice.range(of: "flowchart")
                    else { return }
                    let byteOffset = slice[..<range.lowerBound].utf8.count
                    model.applyEdit(relativeRange: ByteRange(offset: byteOffset, length: 0), replacement: "@@@")
                    try? await Task.sleep(for: .seconds(2))
                    model.applyEdit(relativeRange: ByteRange(offset: byteOffset, length: 3), replacement: "")
                }
            case "codeEdit":
                // Self-driving repro for the code-block editing overlap: open
                // the first code block's source and type a character, so a
                // screenshot captures the active editing state (accent frame +
                // canvas + revealed source) and any geometry misalignment.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard let block = model.document.blocks.first(where: {
                        if case .codeBlock = $0.kind { return true }
                        return false
                    }) else { return }
                    model.activateBlock(block.id, caretHint: .source(0))
                    try? await Task.sleep(for: .seconds(1))
                    // Type into the body to exercise the per-keystroke
                    // decoration path (offset past the opening ``` line).
                    guard let active = model.activeBlockID,
                          let activeBlock = model.document.blocks.first(where: { $0.id == active }),
                          let slice = model.document.source.substring(in: activeBlock.range),
                          let firstNewline = slice.firstIndex(of: "\n")
                    else { return }
                    let bodyOffset = slice[..<slice.index(after: firstNewline)].utf8.count
                    model.applyEdit(relativeRange: ByteRange(offset: bodyOffset, length: 0), replacement: "let x = 1  ")
                }
            default:
                break
            }
        }
    }

    private func menuObservers(_ content: some View) -> some View {
        content
        // ⌥⌘0 / View ▸ Show/Hide Outline (menu command, handoff keyboard map).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleOutlineNotification)) { _ in
            guard isKeyWindow else { return }
            isOutlineVisible.toggle()
        }
        // ⌘↩ / Format ▸ Edit Source (embed-editing keyboard grammar).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleEditSourceNotification)) { _ in
            guard isKeyWindow else { return }
            editSourceToggleGeneration += 1
        }
        // Format menu (⌘B/⌘I/⇧⌘H/⌘K) → the selection formatter.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.formatNotification)) { note in
            guard isKeyWindow else { return }
            switch note.userInfo?["format"] as? String {
            case "bold": fireFormat(.bold)
            case "italic": fireFormat(.italic)
            case "strikethrough": fireFormat(.strikethrough)
            case "code": fireFormat(.code)
            case "highlight": fireFormat(.highlight)
            case "link": fireFormat(.link)
            default: break
            }
        }
        // Edit ▸ Undo/Redo → the document session's undo stack.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.undoNotification)) { _ in
            guard isKeyWindow else { return }
            model.undo()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.redoNotification)) { _ in
            guard isKeyWindow else { return }
            model.redo()
        }
        // File ▸ Export… (⇧⌘E) / Print… (⌘P).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.exportNotification)) { _ in
            guard isKeyWindow else { return }
            isExportVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.printNotification)) { _ in
            guard isKeyWindow else { return }
            DocumentExporters.runPrintOperation(
                for: model.document,
                baseURL: (model.fileURL ?? fileURL)?.deletingLastPathComponent(),
                jobTitle: fileURL?.deletingPathExtension().lastPathComponent ?? "Quoin Document"
            )
        }
        // Edit ▸ Find family (⌘F/⌘G/⇧⌘G).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.findNotification)) { _ in
            guard isKeyWindow else { return }
            isReplaceVisible = false
            openFind()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.findReplaceNotification)) { _ in
            guard isKeyWindow else { return }
            isReplaceVisible = true
            openFind()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.findNextNotification)) { _ in
            guard isKeyWindow else { return }
            nextMatch()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.findPreviousNotification)) { _ in
            guard isKeyWindow else { return }
            previousMatch()
        }
        // Go ▸ Back/Forward (⌘[ / ⌘]).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.goBackNotification)) { _ in
            guard isKeyWindow else { return }
            goBack()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.goForwardNotification)) { _ in
            guard isKeyWindow else { return }
            goForward()
        }
        // Format ▸ Move Block Up/Down (⌥⌘↑ / ⌥⌘↓) — acts on the caret's
        // block (idea #9's keyboard grammar).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.moveBlockNotification)) { note in
            guard isKeyWindow, let id = model.activeBlockID else { return }
            let direction = note.userInfo?["direction"] as? String
            model.perform(direction == "up" ? .moveUp : .moveDown, on: id)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.structureNotification)) { note in
            guard isKeyWindow, model.activeBlockID != nil,
                  let op = note.userInfo?["op"] as? String,
                  let command = structureCommand(for: op) else { return }
            model.applyStructure(command)
        }
        // Format ▸ Table (#14): structural edits on the active table block at
        // the caret's cell. The model no-ops when the active block is not a
        // table, so the shared handler can stay simple.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.tableCommandNotification)) { note in
            guard isKeyWindow, let op = note.userInfo?["op"] as? String else { return }
            model.performTableMenu(op)
        }
        // File ▸ Page Setup… (⇧⌘P) — configure the shared print info.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.pageSetupNotification)) { _ in
            guard isKeyWindow else { return }
            DocumentExporters.runPageSetup()
        }
        // View ▸ Focus Mode / Sentence Focus / Typewriter (#29): the menu
        // posts a toggle; the KEY window flips its own per-window scene
        // storage — so one document's mode never leaks into the others.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleFocusModeNotification)) { _ in
            guard isKeyWindow else { return }
            isFocusMode.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleSentenceFocusNotification)) { _ in
            guard isKeyWindow else { return }
            isSentenceFocus.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleTypewriterNotification)) { _ in
            guard isKeyWindow else { return }
            isTypewriter.toggle()
        }
        // Lets the Format menu title follow the editing state, and File/
        // Edit/Go items enable only when a document can receive them.
        .focusedSceneValue(\.quoinIsEditingBlock, model.activeBlockID != nil)
        .focusedSceneValue(\.quoinHasDocument, true)
        // Edit ▸ Undo/Redo track the session's stacks: the item names the
        // action ("Undo Typing") and disables when its stack is empty.
        .focusedSceneValue(\.quoinUndoAction, model.undoActionName)
        .focusedSceneValue(\.quoinRedoAction, model.redoActionName)
        // The View-menu writing toggles show the KEY window's per-window
        // state (checkmarks follow this document, not a global switch).
        .focusedSceneValue(\.quoinFocusMode, isFocusMode)
        .focusedSceneValue(\.quoinSentenceFocus, isSentenceFocus)
        .focusedSceneValue(\.quoinTypewriter, isTypewriter)
    }

    // MARK: - Format pill (B/I/U + link, floats over the editor)

    /// The format pill acts on the block you're editing (bold/italic/etc.
    /// wrap the selection, or the word under the caret). It only exists
    /// WHILE a block is active — appearing on click-in, gone otherwise —
    /// so it never reads as a dead control (a persistent dimmed pill was
    /// mistaken for broken).
    private var isEditingBlock: Bool { model.activeBlockID != nil }

    /// Map a Format ▸ Structure menu op string (#25) to a model command.
    private func structureCommand(for op: String) -> ReaderModel.StructureCommand? {
        switch op {
        case "h0": return .setHeading(0)
        case "h1": return .setHeading(1)
        case "h2": return .setHeading(2)
        case "h3": return .setHeading(3)
        case "h4": return .setHeading(4)
        case "h5": return .setHeading(5)
        case "h6": return .setHeading(6)
        case "cycleHeading": return .cycleHeading
        case "bullet": return .toggleBullet
        case "numbered": return .toggleNumbered
        case "quote": return .toggleQuote
        case "checkbox": return .toggleCheckbox
        default: return nil
        }
    }

    @ViewBuilder
    private var formatPill: some View {
        if isEditingBlock {
            HStack(spacing: 2) {
                formatPillButton("bold", command: .bold, help: "Bold (⌘B)")
                formatPillButton("italic", command: .italic, help: "Italic (⌘I)")
                formatPillButton("strikethrough", command: .strikethrough, help: "Strikethrough")
                formatPillButton("chevron.left.forwardslash.chevron.right", command: .code, help: "Inline code")
                formatPillButton("highlighter", command: .highlight, help: "Highlight (⇧⌘H)")
                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 2)
                formatPillButton("link", command: .link, help: "Link (⌘K)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isEditingBlock)
        }
    }

    private func formatPillButton(_ symbol: String, command: FormatCommand, help: String) -> some View {
        Button {
            fireFormat(command)
        } label: {
            Image(systemName: symbol)
                .quoinScaledFont(size: 11, weight: .medium)
                .foregroundStyle(.primary.opacity(0.75))
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The heading governing the top of the viewport.
    /// The section the reader is in, resolved by DOCUMENT ORDER (#R3). The old
    /// range-based version reverted to the ancestor heading once the current
    /// heading scrolled above the viewport (its laid-out range dropped out);
    /// block index survives that, so the highlight stays on the section you're
    /// actually reading until the NEXT heading reaches the top.
    private var currentSection: HeadingInfo? {
        OutlineNavigation.currentSection(
            topBlockID: topBlockID,
            blocks: model.document.blocks,
            outline: model.outline)
    }

    private func fireFormat(_ command: FormatCommand) {
        formatCommand = command
        formatGeneration += 1
    }

    // MARK: - Jump history (idea #7): ⌘[ back, ⌘] forward

    /// Record the pre-jump position; any new jump clears the forward stack.
    private func recordJump(from: BlockID?) {
        guard let from else { return }
        backStack.append(from)
        forwardStack.removeAll()
    }

    /// Navigate to a heading, recording history (TOC, breadcrumb).
    private func jump(to id: BlockID) {
        recordJump(from: topBlockID)
        scrollTarget = id
        scrollGeneration += 1
    }

    private func goBack() {
        guard let target = backStack.popLast() else { return }
        if let here = topBlockID { forwardStack.append(here) }
        scrollTarget = target
        scrollGeneration += 1
    }

    private func goForward() {
        guard let target = forwardStack.popLast() else { return }
        if let here = topBlockID { backStack.append(here) }
        scrollTarget = target
        scrollGeneration += 1
    }

    /// The ancestor chain of the current section (H1 › H2 › …), for the
    /// status-bar breadcrumb (idea #6).
    private var breadcrumb: [HeadingInfo] {
        guard let current = currentSection else { return [] }
        var path: [HeadingInfo] = [current]
        var level = current.level
        guard let index = model.outline.firstIndex(where: { $0.id == current.id }) else { return path }
        for heading in model.outline[..<index].reversed() where heading.level < level {
            path.insert(heading, at: 0)
            level = heading.level
        }
        return path
    }

    // MARK: - Merge banner (non-blocking, per handoff)

    private var conflictBanner: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("This file changed on disk while you had unsaved edits.")
                    .quoinScaledFont(size: 12)
                Spacer()
                Button("Keep Mine") { model.resolveConflictKeepingMine() }
                Button("Use Disk Version") { model.resolveConflictTakingDisk() }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.08))
            Divider()
        }
    }

    // MARK: - Action failure banner (non-blocking, auto-dismissing)

    private func actionFailureBanner(_ failure: ReaderModel.ActionFailure) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text(failure.message)
                    .quoinScaledFont(size: 12)
                Spacer()
                Button {
                    model.dismissActionFailure()
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Dismiss")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.08))
            Divider()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Status bar (10.5pt mono, 40% ink, top hairline)

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                // Breadcrumb (idea #6): the current section as a clickable
                // ancestor path — jump to any level.
                if !breadcrumb.isEmpty {
                    Menu {
                        ForEach(breadcrumb) { heading in
                            Button(heading.title) { jump(to: heading.id) }
                        }
                    } label: {
                        Text("§ " + breadcrumb.map(\.title).joined(separator: " › "))
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    // NOT .fixedSize(): the bridged popup button wraps a
                    // long breadcrumb at narrow widths and reports a TALL
                    // intrinsic height — the status bar once swallowed half
                    // the window (screenshot, 2026-07-14). Truncate instead.
                    .layoutPriority(1)
                    .help("Jump to a section in the current path")
                }
                Spacer()
                // Review Mode must be LOUD (design §3.6): while typing
                // becomes suggestions, the status bar says so in accent.
                if model.isSuggestMode {
                    Text("SUGGESTING")
                        .quoinScaledFont(size: 9, weight: .semibold)
                        .kerning(0.5)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.accentColor, in: Capsule())
                        // Capsules never clip (same rule as the inspector's
                        // count badge): the breadcrumb, at layoutPriority(1),
                        // otherwise squeezes this into a partial shape at
                        // narrow widths. Horizontal-only — the bar's 22pt
                        // strip must stay immune to reported heights.
                        .fixedSize(horizontal: true, vertical: false)
                        .help("Typing becomes suggestions — Format ▸ Review ▸ Suggest Edits (⌃⌘R) to turn off")
                }
                // Review counts (suggestions design §3.5): accent, mono,
                // only while unresolved marks exist.
                if reviewCounts.suggestions + reviewCounts.comments > 0 {
                    Text([
                        reviewCounts.suggestions > 0
                            ? "\(reviewCounts.suggestions) suggestion\(reviewCounts.suggestions == 1 ? "" : "s")" : nil,
                        reviewCounts.comments > 0
                            ? "\(reviewCounts.comments) comment\(reviewCounts.comments == 1 ? "" : "s")" : nil,
                    ].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(Color.accentColor)
                        // Never a mid-word sliver: the truncating breadcrumb
                        // absorbs the shortfall instead.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                // Word-count goal (idea #3): quiet progress next to stats.
                if wordGoal > 0 {
                    let fraction = min(1, Double(model.stats.wordCount) / Double(wordGoal))
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 56)
                        .tint(fraction >= 1 ? .green : .accentColor)
                        .help("\(model.stats.wordCount) of \(wordGoal) words")
                }
                StatsButton(stats: model.stats, wordGoal: $wordGoal)
            }
            .quoinScaledFont(size: 10.5, design: .monospaced)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            // The bar is a FIXED-HEIGHT hairline strip by spec — no content
            // may inflate it, whatever the bridged controls report; the height
            // tracks Dynamic Type (statusBarHeight) so the scaled label fits.
            .frame(height: statusBarHeight)
            .clipped()
        }
    }

    // MARK: - Find bar

    /// The shared match rules driving BOTH the highlight scan and replace.
    private var searchOptions: SearchOptions {
        SearchOptions(matchCase: findMatchCase, wholeWord: findWholeWord, regex: findRegex)
    }

    /// Regex on with a pattern that won't compile — the field shows a subtle
    /// invalid state and nothing matches (never a crash).
    private var isPatternInvalid: Bool {
        !searchQuery.isEmpty && !TextMatcher.isValidQuery(searchQuery, options: searchOptions)
    }

    /// The count readout next to the find field, or the invalid-pattern hint.
    private var findFieldStatus: String {
        if isPatternInvalid { return "Invalid pattern" }
        return matchCount == 0 ? "No matches" : "\(activeMatch + 1) of \(matchCount)"
    }

    private var findBar: some View {
        VStack(spacing: 0) {
            findBarContent
            findOptionsRow
            if isReplaceVisible {
                Divider().opacity(0.5)
                replaceBarContent
            }
            Divider()
        }
    }

    /// The option toggles (#23): Match Case, Whole Word, Regex, In Selection.
    private var findOptionsRow: some View {
        HStack(spacing: 6) {
            findOptionToggle("Aa", isOn: $findMatchCase, help: "Match Case")
            findOptionToggle("W", isOn: $findWholeWord, help: "Whole Word")
            findOptionToggle(".*", isOn: $findRegex, help: "Regular Expression")
            findOptionToggle("In Selection", isOn: $findInSelection,
                             help: "Limit find & replace to the selected text")
            Spacer()
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .background(reduceTransparency
            ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
            : AnyShapeStyle(Material.bar))
    }

    private func findOptionToggle(
        _ label: String, isOn: Binding<Bool>, help: String
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(label)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn.wrappedValue
                              ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                              : AnyShapeStyle(Color.clear)))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isOn.wrappedValue ? Color.accentColor : Color.secondary.opacity(0.35),
                                lineWidth: 1))
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(isOn.wrappedValue ? [.isSelected] : [])
    }

    private var replaceBarContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.2.squarepath")
                .foregroundStyle(.secondary)
            TextField("Replace with", text: $replaceText)
                .textFieldStyle(.plain)
                .focused($replaceFieldFocused)
                .onSubmit { replaceCurrent() }
                .onExitCommand { closeFind() }
            if let replaceStatus {
                Text(replaceStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("Replace") { replaceCurrent() }
                .disabled(matchCount == 0)
            Button("All") { replaceAll() }
                .disabled(matchCount == 0)
                .help("Replace every match (one undo)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(reduceTransparency
            ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
            : AnyShapeStyle(Material.bar))
    }

    private func replaceCurrent() {
        guard !searchQuery.isEmpty else { return }
        guard !isPatternInvalid else { replaceStatus = "Invalid pattern"; return }
        if findInSelection, model.selectionSourceRange == nil {
            replaceStatus = "Select text first"
            return
        }
        let replaced = model.replaceNextMatch(
            of: searchQuery, with: replaceText, fromByteOffset: model.caretByteOffset,
            options: searchOptions, inSelection: findInSelection)
        replaceStatus = replaced ? "Replaced 1" : "No match"
    }

    private func replaceAll() {
        guard !searchQuery.isEmpty else { return }
        guard !isPatternInvalid else { replaceStatus = "Invalid pattern"; return }
        if findInSelection, model.selectionSourceRange == nil {
            replaceStatus = "Select text first"
            return
        }
        let count = model.replaceAllMatches(
            of: searchQuery, with: replaceText,
            options: searchOptions, inSelection: findInSelection)
        switch count {
        case -1: replaceStatus = "Invalid pattern"
        case 0: replaceStatus = "No matches"
        default: replaceStatus = "Replaced \(count)"
        }
    }

    private var findBarContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in document", text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($findFieldFocused)
                .foregroundStyle(isPatternInvalid ? Color.red : Color.primary)
                .onSubmit { nextMatch() }
                .onExitCommand { closeFind() }
                .onChange(of: searchQuery) { replaceStatus = nil }
                .onChange(of: searchOptions) { replaceStatus = nil }
            if !searchQuery.isEmpty {
                Text(findFieldStatus)
                    .font(.caption)
                    .foregroundStyle(isPatternInvalid ? Color.red : Color.secondary)
                    .monospacedDigit()
            }
            Button(action: previousMatch) {
                Image(systemName: "chevron.up")
            }
            .disabled(matchCount == 0)
            Button(action: nextMatch) {
                Image(systemName: "chevron.down")
            }
            .disabled(matchCount == 0)
            Button(action: closeFind) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(reduceTransparency
            ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
            : AnyShapeStyle(Material.bar))
    }

    private func openFind() {
        isFindVisible = true
        findFieldFocused = true
    }

    private func closeFind() {
        isFindVisible = false
        isReplaceVisible = false
        searchQuery = ""
        replaceText = ""
        activeMatch = 0
        // In-Selection is transient ("this selection, now"); the match rules
        // persist across sessions and are intentionally left as-is.
        findInSelection = false
        replaceStatus = nil
    }

    private func nextMatch() {
        guard matchCount > 0 else { return }
        activeMatch = (activeMatch + 1) % matchCount
    }

    private func previousMatch() {
        guard matchCount > 0 else { return }
        activeMatch = (activeMatch - 1 + matchCount) % matchCount
    }
}

private extension View {
    /// `navigationDocument` has no optional overload; a detached session
    /// (open failure) has no URL and gets no proxy.
    @ViewBuilder
    func navigationDocument(ifPresent url: URL?) -> some View {
        if let url {
            navigationDocument(url)
        } else {
            self
        }
    }
}

// MARK: - Outline panel ("ruled tree" per handoff: hairline under each row,
// indent 0/16/34 by level, H1 bold / H2 semibold / H3+ regular, current
// section in accent at weight 500)

struct OutlinePanel: View {
    let outline: [HeadingInfo]
    let currentSectionID: BlockID?
    let onSelect: (BlockID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Collapsed heading subtrees (session-scoped). A heading hides when
    /// any ancestor — the nearest preceding heading of a shallower level —
    /// is collapsed. Manual collapse is authoritative: only the chevron
    /// toggle and the keyboard collapse/expand keys mutate this set;
    /// reading-position follow never does.
    @State private var collapsed: Set<BlockID> = []

    /// Keyboard focus cursor (#11), distinct from the reading-position
    /// `currentSectionID` highlight: arrow keys walk this through the visible
    /// rows, Left/Right collapse/expand, Return jumps the document to it.
    @State private var focused: BlockID?
    @FocusState private var panelFocused: Bool

    /// Which headings own children (the next entry is deeper).
    private var parents: Set<BlockID> {
        OutlineCollapse.parents(outline: outline)
    }

    /// The outline with collapsed subtrees removed. When the current
    /// section hides inside a collapsed branch the "you are here" marker
    /// climbs to the deepest visible ancestor instead of forcing the row
    /// open (user directive: manual collapse sticks).
    private var visible: [HeadingInfo] {
        OutlineCollapse.visibleHeadings(outline: outline, collapsed: collapsed)
    }

    /// The row that carries the current-section highlight after collapse
    /// resolution (the section itself, or its deepest visible ancestor).
    private var highlightID: BlockID? {
        OutlineCollapse.resolveHighlight(for: currentSectionID, outline: outline, collapsed: collapsed)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("OUTLINE")
                        .quoinScaledFont(size: 10, weight: .semibold)
                        .kerning(0.5)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 6)

                    ForEach(visible) { heading in
                        OutlineRow(
                            heading: heading,
                            isCurrent: heading.id == highlightID,
                            isFocused: heading.id == focused,
                            isParent: parents.contains(heading.id),
                            isCollapsed: collapsed.contains(heading.id),
                            onSelect: { id in
                                focused = id
                                onSelect(id)
                            },
                            onToggle: { toggleCollapse(heading.id) }
                        )
                        .id(heading.id)
                    }
                }
            }
            // The outline is a keyboard tree (#11): focusable so Tab reaches
            // it in the VoiceOver focus order, arrow keys walk the visible
            // rows, ←/→ collapse/expand, Return jumps the document. Movement
            // math lives in OutlineKeyboard so wrap/skip rules are tested once.
            .focusable(!outline.isEmpty)
            .focused($panelFocused)
            .onKeyPress(.downArrow) { apply(OutlineKeyboard.moveDown(from: focused, outline: outline, collapsed: collapsed)) }
            .onKeyPress(.upArrow) { apply(OutlineKeyboard.moveUp(from: focused, outline: outline, collapsed: collapsed)) }
            .onKeyPress(.leftArrow) {
                guard let focused else { return .ignored }
                return apply(OutlineKeyboard.collapseOrParent(focused: focused, outline: outline, collapsed: collapsed))
            }
            .onKeyPress(.rightArrow) {
                guard let focused else { return .ignored }
                return apply(OutlineKeyboard.expandOrChild(focused: focused, outline: outline, collapsed: collapsed))
            }
            .onKeyPress(.return) {
                guard let focused else { return .ignored }
                onSelect(focused)
                return .handled
            }
            // Keep the reading section in view as it advances (#37). `highlightID`
            // changes only at section boundaries (#R3), so scrolling here is
            // naturally debounced — no per-scroll-tick jitter. No `anchor` means
            // scroll the MINIMUM to reveal the row, so a section already on
            // screen doesn't move. Reduce-Motion-aware. Manual collapse still
            // wins — we scroll to the resolved highlight (collapsed ancestor),
            // never re-expand (#74).
            .onChange(of: highlightID) { _, newHighlight in
                guard let newHighlight else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newHighlight)
                }
            }
            // The keyboard cursor scrolls itself into view as it walks.
            .onChange(of: focused) { _, newFocus in
                guard let newFocus else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newFocus)
                }
            }
        }
        .overlay {
            if outline.isEmpty {
                Text("No headings")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    /// Toggle a heading's collapse state (chevron click or ← / → key),
    /// Reduce-Motion-aware. The single mutation point for manual collapse.
    private func toggleCollapse(_ id: BlockID) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            if collapsed.contains(id) {
                collapsed.remove(id)
            } else {
                collapsed.insert(id)
            }
        }
    }

    /// Apply a keyboard navigation response; returns the key-press result so
    /// an edge-of-list no-op passes the event through instead of eating it.
    private func apply(_ response: OutlineKeyboard.Response) -> KeyPress.Result {
        switch response {
        case .move(let id):
            focused = id
        case .collapse(let id):
            focused = id
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { collapsed.insert(id) }
        case .expand(let id):
            focused = id
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { collapsed.remove(id) }
        case .none:
            return .ignored
        }
        return .handled
    }
}

private struct OutlineRow: View {
    let heading: HeadingInfo
    let isCurrent: Bool
    let isFocused: Bool
    let isParent: Bool
    let isCollapsed: Bool
    let onSelect: (BlockID) -> Void
    let onToggle: () -> Void

    private var indent: CGFloat {
        switch heading.level {
        case 1: return 0
        case 2: return 16
        default: return 34
        }
    }

    private var weight: Font.Weight {
        if isCurrent { return .medium }
        switch heading.level {
        case 1: return .bold
        case 2: return .semibold
        default: return .regular
        }
    }

    var body: some View {
        Button {
            onSelect(heading.id)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    // Disclosure chevron: only headings with children get
                    // one; leaves keep a spacer so titles align.
                    if isParent {
                        Button(action: onToggle) {
                            Image(systemName: "chevron.right")
                                .quoinScaledFont(size: 8, weight: .semibold)
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                                .frame(width: 12, height: 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(isCollapsed ? "Expand section" : "Collapse section")
                        // Disclosure semantics for VoiceOver (#11): announce
                        // the row as expandable and its current state.
                        .accessibilityLabel(isCollapsed ? "Expand section" : "Collapse section")
                        .accessibilityValue(isCollapsed ? "collapsed" : "expanded")
                    } else {
                        Color.clear.frame(width: 12, height: 12)
                    }
                    Text(heading.title)
                        .quoinScaledFont(size: 12, weight: weight)
                        .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                    if isCollapsed, isParent {
                        Text("…")
                            .quoinScaledFont(size: 12)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 8 + indent)
                .padding(.trailing, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                    .padding(.leading, 12)
            }
            .contentShape(Rectangle())
            // Keyboard focus ring (#11): a subtle tint + accent stroke marks
            // the arrow-key cursor, kept distinct from the accent-TEXT
            // reading-position highlight so the two never read as one.
            .background(isFocused ? Color.accentColor.opacity(0.12) : Color.clear)
            .overlay(alignment: .leading) {
                if isFocused {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Statistics ("412 words · 2,304 chars · 2 min read"; click → detail)

struct StatsButton: View {
    let stats: DocumentStats
    var wordGoal: Binding<Int>?
    @State private var isPresented = false

    private var summary: String {
        let words = stats.wordCount.formatted()
        let chars = stats.characterCount.formatted()
        return "\(words) words · \(chars) chars · \(stats.readingTimeMinutes) min read"
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Text(summary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            StatsView(stats: stats, wordGoal: wordGoal)
        }
        .help("Document statistics")
    }
}

struct StatsView: View {
    let stats: DocumentStats
    var wordGoal: Binding<Int>?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            row("Words", stats.wordCount)
            row("Characters", stats.characterCount)
            row("Reading time", "\(stats.readingTimeMinutes) min")
            Divider()
            row("Headings", stats.headingCount)
            row("Links", stats.linkCount)
            row("Images", stats.imageCount)
            row("Code blocks", stats.codeBlockCount)
            row("Tables", stats.tableCount)
            if stats.mathCount > 0 { row("Math", stats.mathCount) }
            if stats.diagramCount > 0 { row("Diagrams", stats.diagramCount) }
            if stats.taskTotal > 0 {
                Divider()
                row("Tasks", "\(stats.taskDone) of \(stats.taskTotal) done")
            }
            if let wordGoal {
                Divider()
                GridRow {
                    Text("Word goal").foregroundStyle(.secondary)
                    TextField("Off", value: wordGoal, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                        .help("Set a word-count goal (0 turns it off); progress shows in the status bar")
                }
            }
        }
        .padding(16)
        .font(.callout)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: Int) -> some View {
        row(label, "\(value)")
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
