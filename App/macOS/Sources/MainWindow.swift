import AppKit
import SwiftUI
import QuoinCore
import QuoinRender

/// The main window per the handoff: library sidebar (⌘0) · tab bar +
/// editor · outline inspector (⌥⌘0), with quick open (⇧⌘O) floating above.
struct MainWindow: View {
    /// Folder this window was OPENED FOR (Open Folder in New Window…) —
    /// nil for plain windows (#61).
    var requestedRootPath: String?

    @State private var library = LibraryModel()
    /// This window's library root, restored across relaunch (each window
    /// remembers ITS folder — "the folder(s)/projects I was working on").
    @SceneStorage("QuoinWindowRoot") private var persistedRootPath = ""
    @AppStorage("QuoinLaunchBehavior") private var launchBehavior = "restore"
    /// One `ReaderModel` per file, shared across every window and tab — a tab
    /// acquires on open and releases on close (#12/#22).
    private let store = OpenDocumentStore.shared

    @State private var sidebarSelection: URL?
    @State private var openTabs: [DocumentTab] = []
    @State private var activeTabID: DocumentTab.ID?
    /// Workspace memory (UI #4 / #15): the whole per-window session — open tabs
    /// (as library-relative handles, NEVER absolute paths or raw bookmarks),
    /// active tab, panel chrome, and the active document's scroll anchor —
    /// survives quit/relaunch/crash. Serialized from the platform-free,
    /// unit-tested `WindowSessionState` seam in QuoinCore.
    @SceneStorage("QuoinWindowSession") private var persistedSession = ""
    /// The active tab's inspector chrome, mirrored up from `ReaderScreen` (which
    /// owns the live `@State`) so the window can persist it and re-seed the
    /// restored active tab. Window-scoped: shared across this window's tabs.
    @State private var inspectorVisible = true
    @State private var inspectorMode = WindowSessionState.InspectorMode.outline
    /// Per-tab scroll anchors (absolute document path → top-of-viewport heading
    /// slug), kept fresh for the active tab and persisted for restore.
    @State private var scrollAnchors: [String: String] = [:]
    /// The scroll anchor to apply ONCE to the restored active tab on relaunch,
    /// tagged with that tab's identity so no other tab consumes it.
    @State private var pendingRestoreAnchor: (tabID: DocumentTab.ID, slug: String)?

    private var activeTab: DocumentTab? {
        openTabs.first { $0.id == activeTabID }
    }
    /// The document published as the current `NSUserActivity` (#36): Handoff /
    /// Siri-suggestion / window-restoration handle for the active tab. Reused
    /// across tab switches (same activity type); resigned when this window is
    /// not key or its document leaves the library; invalidated on close.
    @State private var currentActivity: NSUserActivity?
    @State private var isQuickOpenVisible = false
    @State private var isLibrarySearchVisible = false
    /// First-run sample offer (#13): set true right after the user PICKS a
    /// library that holds no sample docs yet, so the empty state shows a
    /// gentle, dismissible "add sample documents" card. Opt-in and non-modal —
    /// declining (or opening any document) simply clears it; nothing is written
    /// unless the user accepts. Not persisted: the offer is tied to the pick
    /// action, never nagged on every launch.
    @State private var offerSample = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Menu actions must land in the KEY window only — every observer
    /// below guards on this (launch ledger BLOCKER: two windows used to
    /// both undo/export on one menu click).
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isKeyWindow: Bool { controlActiveState == .key }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            if library.hasLibrary {
                LibrarySidebar(
                    library: library,
                    selection: $sidebarSelection,
                    isSearchVisible: $isLibrarySearchVisible
                ) { url in
                    open(url)
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            } else {
                // Onboarding lives in the DETAIL pane (below) where there's
                // room; the sidebar stays quiet until a library exists.
                VStack(spacing: 6) {
                    Image(systemName: "books.vertical")
                        .foregroundStyle(.tertiary)
                    Text("No library yet")
                        .quoinScaledFont(size: 11)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } detail: {
            VStack(spacing: 0) {
                // A library is NOT required to edit: opening a file (⌘O / Finder
                // / Open Recent) builds a standalone tab with no rootURL (#18).
                // Onboard only when there is genuinely nothing to show.
                if openTabs.isEmpty && !library.hasLibrary {
                    chooseLibraryPrompt
                } else {
                    DocumentTabBar(tabs: openTabs, activeTabID: $activeTabID) { tab in
                        close(tab)
                    }
                    if let tab = activeTab, let model = store.model(for: tab.url) {
                        // ONE editor is on screen at a time (a keep-alive stack
                        // of full ReaderScreens duplicated the window toolbar and
                        // broke interaction). The live session + undo history no
                        // longer die on a tab switch because the MODEL is owned by
                        // the app-level store (#12/#22), not by this transient
                        // view — re-entry re-projects from the cached model, never
                        // from disk. Keyed by the tab's STABLE identity so a
                        // first-H1 rename can't tear the editor down (ledger #13).
                        ReaderScreen(
                            model: model, fileURL: tab.url,
                            initialInspectorVisible: inspectorVisible,
                            initialInspectorMode: inspectorMode.rawValue,
                            initialScrollAnchor: pendingRestoreAnchor?.tabID == tab.id
                                ? pendingRestoreAnchor?.slug : nil,
                            onInspectorChange: { visible, modeRaw in
                                inspectorVisible = visible
                                if let mode = WindowSessionState.InspectorMode(rawValue: modeRaw) {
                                    inspectorMode = mode
                                }
                                persistSession()
                            },
                            onScrollAnchorChange: { slug in
                                let key = tab.url.standardizedFileURL.path
                                if let slug { scrollAnchors[key] = slug }
                                else { scrollAnchors.removeValue(forKey: key) }
                                persistSession()
                            },
                            onInitialScrollConsumed: { pendingRestoreAnchor = nil }
                        )
                        .id(tab.id)
                    } else {
                        emptyState
                    }
                }
            }
        }
        .overlay {
            if isQuickOpenVisible {
                Color.black.opacity(0.001) // click-away catcher
                    .onTapGesture { isQuickOpenVisible = false }
                QuickOpenPanel(library: library, isPresented: $isQuickOpenVisible) { url in
                    open(url)
                }
                .padding(.top, 80)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(windowShortcuts)
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openDocumentNotification)) { _ in
            guard isKeyWindow else { return }
            drainPendingOpenURLs()
        }
        // A quoin:// deep link arrived while running (#31): the key window
        // resolves it against its own library and opens it.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openDeepLinkNotification)) { _ in
            guard isKeyWindow else { return }
            consumePendingDeepLink()
        }
        // Services ▸ New Quoin Document with Selection (#35) arrived while
        // running. Deliberately NOT key-gated: prefer a window CONNECTED TO A
        // LIBRARY over the frontmost one, so the selection quietly becomes a
        // file in the open library instead of popping a save panel just because
        // the key window happens to be library-less (#35 review). Every window
        // gets a synchronous first refusal to claim the seed with its library
        // (the claim is atomic on the main actor — no double create); a runloop
        // hop then lets the save-panel fallback fire only if NOBODY claimed it
        // (no library configured anywhere).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.newDocumentWithSelectionNotification)) { _ in
            claimPendingSelectionSeed(fallbackToPanel: false)
            DispatchQueue.main.async { claimPendingSelectionSeed(fallbackToPanel: true) }
        }
        // ⌘0 / View ▸ Show/Hide Sidebar (handoff keyboard map).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleSidebarNotification)) { _ in
            guard isKeyWindow else { return }
            // Reduce Motion (#28): apply the sidebar change instantly.
            withAnimation(reduceMotion ? nil : .default) {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        }
        // File ▸ New Document (⌘N).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.newDocumentNotification)) { _ in
            guard isKeyWindow else { return }
            if let url = library.createDocument() { open(url) }
        }
        // File ▸ Duplicate: copy the active document to a unique sibling and
        // open the copy (matching the sidebar context menu).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.duplicateDocumentNotification)) { _ in
            guard isKeyWindow, let url = activeTab?.url else { return }
            // Flush the live session first so the copy captures unsaved
            // keystrokes still inside the 400ms autosave debounce (#12).
            Task { if let copy = await library.duplicateFlushingSession(url: url) { open(copy) } }
        }
        // File ▸ Move to Trash (⌘⌫): trash the active document. Its tabs then
        // close via the documentTrashedNotification observer below.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.trashDocumentNotification)) { _ in
            guard isKeyWindow, let url = activeTab?.url else { return }
            library.trash(url: url)
        }
        // File ▸ Close Tab (⌘W).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.closeTabNotification)) { _ in
            guard isKeyWindow, let tab = activeTab else { return }
            close(tab)
        }
        // Window ▸ Show Next/Previous Tab (⌃⇥ / ⌃⇧⇥): cycle Quoin's own
        // document tabs, wrapping at the ends (the standard tab-nav feel).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.nextTabNotification)) { _ in
            guard isKeyWindow else { return }
            cycleTab(by: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.previousTabNotification)) { _ in
            guard isKeyWindow else { return }
            cycleTab(by: -1)
        }
        // Window ▸ Select Tab 1–9 (⌘1–9): jump straight to the Nth tab. An
        // index past the open-tab count is a no-op (the item stays enabled
        // whenever a document is open — see WindowCommands).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.selectTabNotification)) { note in
            guard isKeyWindow, let index = note.userInfo?["index"] as? Int,
                  openTabs.indices.contains(index - 1) else { return }
            activeTabID = openTabs[index - 1].id
        }
        // File ▸ Show in Finder: reveal the active tab's file.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.revealInFinderNotification)) { _ in
            guard isKeyWindow, let url = activeTab?.url else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        // File ▸ Open… (⌘O): native panel, markdown files only.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openFilePanelNotification)) { _ in
            guard isKeyWindow else { return }
            presentOpenPanel()
        }
        // File ▸ Change Library Folder….
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.changeLibraryNotification)) { _ in
            guard isKeyWindow else { return }
            // Same first-run offer if the newly chosen folder has no samples (#13).
            if library.chooseLibraryFolder() {
                offerSample = library.shouldOfferSampleDocuments
            }
        }
        // Go ▸ Quick Open (⇧⌘O) / Daily Note (⌘D).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleQuickOpenNotification)) { _ in
            guard isKeyWindow else { return }
            isQuickOpenVisible.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.dailyNoteNotification)) { _ in
            guard isKeyWindow else { return }
            if let url = library.dailyNote() { open(url) }
        }
        // Edit ▸ Find ▸ Search Library (⇧⌘F).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.toggleLibrarySearchNotification)) { _ in
            guard isKeyWindow else { return }
            isLibrarySearchVisible.toggle()
        }
        // A trashed document's tabs close in EVERY window (deliberately
        // not key-gated) — a live session would autosave into the Trash.
        .onReceive(NotificationCenter.default.publisher(for: LibraryModel.documentTrashedNotification)) { note in
            if let url = note.userInfo?["url"] as? URL {
                let doomed: (DocumentTab) -> Bool = { $0.url == url || $0.url.path.hasPrefix(url.path + "/") }
                let dropped = openTabs.filter(doomed)
                guard !dropped.isEmpty else { return }
                // Positional stability holds here too (#77): if the active tab
                // is trashed out from under the user, focus lands on the tab
                // now occupying its slot, not on the rightmost tab.
                let activeIndex = openTabs.firstIndex { $0.id == activeTabID }
                let removedIndices = Set(openTabs.indices.filter { doomed(openTabs[$0]) })
                openTabs.removeAll(where: doomed)
                dropped.forEach { store.release($0.url) }
                if activeTabID != nil, activeTab == nil {
                    activeTabID = activeIndex
                        .flatMap { index in
                            TabSuccession.successorIndex(
                                activeIndex: index,
                                originalCount: openTabs.count + dropped.count
                            ) { removedIndices.contains($0) }
                        }
                        .map { openTabs[$0].id }
                }
            }
        }
        // A document renamed itself on disk (first-H1 rename). The store already
        // relocated the one shared session; every window re-points its tab so
        // the URL, tab title, and sidebar selection follow the file (#12/#13).
        .onReceive(NotificationCenter.default.publisher(for: OpenDocumentStore.documentRenamedNotification)) { note in
            guard let old = note.userInfo?["old"] as? URL,
                  let new = note.userInfo?["new"] as? URL else { return }
            var touched = false
            for index in openTabs.indices where OpenDocumentStore.sameFile(openTabs[index].url, old) {
                openTabs[index].url = new
                touched = true
            }
            guard touched else { return }
            if let selection = sidebarSelection, OpenDocumentStore.sameFile(selection, old) {
                sidebarSelection = new
            }
            library.rescan()
        }
        // Help ▸ (any bundled guide): LIVE documents in the library (editable
        // examples — the guide teaches by being edited). One handler for every
        // Help entry; the resource + filename ride the notification (#13).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openBundledDocumentNotification)) { note in
            guard isKeyWindow,
                  let resource = note.userInfo?["resource"] as? String,
                  let filename = note.userInfo?["filename"] as? String else { return }
            if let url = library.materializeBundledDocument(resource: resource, as: filename) { open(url) }
        }
        .onAppear {
            connectLibrary()
            restoreTabs()
            applyShotState()
            // Cold launch via Finder double-click / Open With (#16): the file
            // open was delivered before this window's observer existed, so drain
            // any pending file opens now that the window is up. Not key-gated —
            // the FIRST window to appear at cold launch owns the drain (the slot
            // clears atomically, so a later window sees nothing).
            drainPendingOpenURLs()
            // Cold launch via quoin:// (#31): the URL was delivered before this
            // window's observer existed, so drain any pending link now that the
            // library is connected.
            consumePendingDeepLink()
            // Cold launch via Services (#35): the selection likewise arrived
            // before any observer existed — drain it once the library connects.
            // Single window here, so the save-panel fallback is allowed inline.
            claimPendingSelectionSeed(fallbackToPanel: true)
            // Publish the active document as the current activity (#36) once the
            // library (its confinement root) is connected.
            updateUserActivity()
        }
        // Every root change (chooser, starter library, folder-window) is
        // remembered as THIS window's folder.
        .onChange(of: library.rootURL) { _, url in
            if let url { persistedRootPath = url.standardizedFileURL.path }
            // The confinement root moved: rebuild (or clear) the activity so its
            // deep link is anchored to the new library — or nothing, if the
            // active document now falls outside it (#36).
            updateUserActivity()
        }
        // Only the KEY window publishes the current activity; becoming/resigning
        // key flips which window's document is the one the user is on (#36).
        // Becoming key also drains any pending open (#16): a Finder open / dock
        // recent while Quoin was backgrounded posts before any window is key, so
        // the key-gated observer above drops it — this backstops that case once
        // activation makes a window key (replacing the old fixed-delay guess).
        .onChange(of: controlActiveState) {
            updateUserActivity()
            if isKeyWindow { drainPendingOpenURLs() }
        }
        // Closing the window (red button) with tabs still open must release the
        // store's hold on each, or their sessions leak (kept watching + never
        // stopped). ⌘W already releases per tab; this covers the whole-window
        // path. Autosave safety on quit is handled separately by the live-
        // session flush registry.
        .onDisappear {
            openTabs.forEach { store.release($0.url) }
            // Tear down the published activity with the window (#36).
            currentActivity?.invalidate()
            currentActivity = nil
        }
        // A rename can change the active tab's URL without changing activeTabID,
        // so republish on any tab-list change too (keeps the deep link current).
        .onChange(of: openTabs) { persistSession(); updateUserActivity() }
        .onChange(of: activeTabID) { persistSession(); updateUserActivity() }
        // Sidebar visibility is part of the window session (⌘0 toggles it).
        .onChange(of: columnVisibility) { persistSession() }
        // Sidebar keyboard selection (↑/↓ + the List's type-select) opens
        // documents, not just mouse clicks (UI #23). open() re-sets the
        // selection to the same URL, so this settles after one pass.
        .onChange(of: sidebarSelection) { _, url in
            if let url, url.pathExtension.lowercased() == "md", activeTab?.url != url {
                open(url)
            }
        }
        // With per-window folders, the title bar says WHICH folder this
        // window is (#61).
        .navigationTitle(library.rootURL?.lastPathComponent ?? "Quoin")
    }

    /// Which folder this window shows, decided in priority order:
    /// automation override (already adopted in init) → the folder the
    /// window was opened FOR → the window's own remembered folder → the
    /// launch preference (most-recent library, or an empty window).
    /// "Start empty" applies to LAUNCH restoration only — windows the user
    /// opens mid-session still get the most recent library.
    private func connectLibrary() {
        guard !library.hasLibrary else { return }
        if let requestedRootPath {
            library.adoptFolder(path: requestedRootPath)
            return
        }
        if !persistedRootPath.isEmpty, launchBehavior != "empty" || !AppDelegate.isLaunchRestoration {
            library.adoptFolder(path: persistedRootPath)
            return
        }
        if launchBehavior == "empty", AppDelegate.isLaunchRestoration {
            persistedSession = "" // an empty start restores no workspace either
            return
        }
        library.restoreDefaultLibrary()
    }

    // MARK: - Workspace persistence (UI #4 / #15)

    /// Snapshot the whole window session into the `@SceneStorage` blob. The
    /// pure `WindowSessionState.capture` folds every open tab to a
    /// library-relative handle (dropping one-off files opened from outside the
    /// library — they have no sandbox-safe handle) and guarantees no absolute
    /// path or bookmark ever reaches the blob.
    private func persistSession() {
        let state = WindowSessionState.capture(
            rootPath: library.rootURL?.standardizedFileURL.path,
            openTabPaths: openTabs.map { $0.url.standardizedFileURL.path },
            activeTabPath: activeTab?.url.standardizedFileURL.path,
            scrollAnchors: scrollAnchors,
            sidebarVisible: columnVisibility != .detailOnly,
            inspectorVisible: inspectorVisible,
            inspectorMode: inspectorMode
        )
        persistedSession = state.serialized()
    }

    /// Restore the window session from the last run. Only files still reachable
    /// through the library's security scope come back — a sandboxed relaunch has
    /// no access to one-off files opened via the panel, and the pure seam prunes
    /// any handle that vanished, moved, or would escape the root, and dedupes two
    /// handles for one file to a single tab (never two sessions over one file).
    private func restoreTabs() {
        guard openTabs.isEmpty, !persistedSession.isEmpty,
              let state = WindowSessionState(serialized: persistedSession),
              let rootPath = library.rootURL?.standardizedFileURL.path else { return }
        // Panel chrome restores even when no tabs survive.
        columnVisibility = state.sidebarVisible ? .all : .detailOnly
        inspectorVisible = state.inspectorVisible
        inspectorMode = state.inspectorMode

        let restored = state.restoredTabs(rootPath: rootPath) {
            FileManager.default.fileExists(atPath: $0)
        }
        guard !restored.orderedPaths.isEmpty else { return }
        // Re-seed the per-tab scroll anchors so switching tabs mid-session keeps
        // each document's remembered position, and the next persist keeps them.
        for tab in state.tabs {
            guard let slug = tab.scrollAnchor,
                  let resolved = QuoinURLScheme.resolvedPath(forRawPath: tab.path, relativeTo: rootPath)
            else { continue }
            scrollAnchors[resolved] = slug
        }
        let tabs = restored.orderedPaths.map { DocumentTab(url: URL(fileURLWithPath: $0)) }
        // Acquire BEFORE publishing the tabs so the model is present the first
        // time the body renders the active tab (no empty-state flash).
        tabs.forEach { store.acquire($0.url) }
        openTabs = tabs
        let active = restored.activePath.flatMap { path in
            tabs.first { $0.url.path == path }
        } ?? tabs.last
        activeTabID = active?.id
        if let active {
            sidebarSelection = active.url
            library.reveal(url: active.url)
            // Apply the active tab's saved scroll position ONCE on relaunch
            // (the in-session per-tab scroll memory is the model's savedViewport).
            if let slug = scrollAnchors[active.url.standardizedFileURL.path] {
                pendingRestoreAnchor = (active.id, slug)
            }
        }
    }

    /// Screenshot automation: `-QuoinShotOpen name.md` opens a library file
    /// at launch; `-QuoinShotState …` presets window chrome. Deterministic
    /// state beats synthetic keyboard events on headless runners. States
    /// handled HERE are window-level (quick open / library search); states
    /// that preset the editor's inspector or review mode are handled in
    /// `ReaderScreen` (which owns that @State). The full state list +
    /// launch args are catalogued in docs/screenshots.md.
    ///
    /// So the orchestrator can drive a single `-QuoinShotState review` with
    /// no `-QuoinShotOpen`, review/properties/reviewmode default to the
    /// review-stress-test fixture and codethemes/footnotes to showcase.
    private func applyShotState() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "QuoinShotOpen") != nil
                || defaults.string(forKey: "QuoinShotState") != nil else { return }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1)) // let the library scan land
            let state = defaults.string(forKey: "QuoinShotState")
            if let name = defaults.string(forKey: "QuoinShotOpen"), let root = library.rootURL {
                open(root.appendingPathComponent(name))
            } else if let root = library.rootURL, let fixture = defaultShotFixture(for: state) {
                // No explicit -QuoinShotOpen: open the fixture the state needs.
                open(root.appendingPathComponent(fixture))
            }
            switch state {
            case "quickopen":
                isQuickOpenVisible = true
                library.quickOpenQuery = "show"
                try? await Task.sleep(for: .milliseconds(500))
                library.runQuickOpen()
            case "libsearch":
                isLibrarySearchVisible = true
                library.librarySearchQuery = "engine"
                try? await Task.sleep(for: .milliseconds(500))
                library.runLibrarySearch()
            default:
                // review / properties / reviewmode / codethemes / footnotes
                // preset the EDITOR chrome, handled in ReaderScreen once the
                // fixture's ReaderScreen appears.
                break
            }
        }
    }

    /// The fixture a `-QuoinShotState` opens when no `-QuoinShotOpen` is
    /// given. Review states want the 21-suggestion stress fixture; code +
    /// footnote states want the showcase (it carries a fenced code block and
    /// a footnote reference/definition pair).
    private func defaultShotFixture(for state: String?) -> String? {
        switch state {
        // The realistic demo docs read like real work — a spec under
        // review, a note with rich properties — better screenshot subjects
        // than the synthetic stress fixtures.
        case "review", "reviewmode": return "demo-product-spec.md"
        case "properties": return "demo-daily-note.md"
        case "codethemes": return "demo-research-note.md"
        case "footnotes": return "demo-research-note.md"
        default: return nil
        }
    }

    // MARK: - Tabs

    private func open(_ url: URL) {
        // Opening any document dismisses the first-run sample offer (#13).
        offerSample = false
        // Dedup by file IDENTITY, not raw URL equality — two path forms of the
        // same file must reuse the one tab, not open a second session (#12).
        if let existing = openTabs.first(where: { OpenDocumentStore.sameFile($0.url, url) }) {
            activeTabID = existing.id
        } else {
            store.acquire(url)
            let tab = DocumentTab(url: url)
            openTabs.append(tab)
            activeTabID = tab.id
        }
        sidebarSelection = url
        // Reveal in the tree: expand ancestor folders so the selection is
        // visible when the doc was opened via quick open or Finder.
        library.reveal(url: url)
        // Feeds quick open's empty-query recents (idea #13) + the system's
        // recents (dock menu, Spotlight "recent items").
        library.recordOpen(url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// Open every file waiting in `AppDelegate.pendingOpenURLs` (#16) as a tab in
    /// THIS window, draining the slot atomically so a dropped notification never
    /// loses an open and two windows can't race to open the same file twice.
    /// Every Finder / Open With / Open Recent / dock / editor-drop open lands
    /// here, so they all share the ONE open path (`open`) — a real tab + session,
    /// never detached state.
    private func drainPendingOpenURLs() {
        guard !AppDelegate.pendingOpenURLs.isEmpty else { return }
        let urls = AppDelegate.pendingOpenURLs
        AppDelegate.pendingOpenURLs = []
        for url in urls { open(url) }
    }

    /// Resolve and open the pending `quoin://` deep link, if one is waiting and
    /// this window can honor it (#31).
    ///
    /// Confinement is layered: the raw path is resolved *lexically* into this
    /// window's library root (`QuoinURLScheme.resolvedPath` — no traversal can
    /// escape), the file must actually exist and be markdown, and it must be
    /// reachable through the library's live security scope (the app holds no
    /// access outside the root, so an out-of-library link fails here even if
    /// the lexical check were somehow fooled). Anything else beeps and clears
    /// the slot rather than opening a surprise file.
    private func consumePendingDeepLink() {
        guard let link = AppDelegate.pendingDeepLink else { return }
        // Only a window with a library can resolve a path — leave the slot for
        // a window that has one (e.g. this one, once connectLibrary lands).
        guard let root = library.rootURL else { return }
        guard let resolved = QuoinURLScheme.resolvedPath(
            forRawPath: link.rawPath,
            relativeTo: root.standardizedFileURL.path)
        else {
            // A root-confined link (a Spotlight tap, #6) names its document by
            // an absolute path that lives under exactly ONE library root. If
            // that isn't this window's root, LEAVE the slot for the window that
            // owns it — beeping or opening a same-named file from this library
            // would be the wrong document. External quoin:// links carry a
            // portable relative path any window may resolve, so a genuine
            // failure there still beeps (and clears the slot) as before.
            if link.confinedToContainingRoot { return }
            AppDelegate.pendingDeepLink = nil
            NSSound.beep()
            return
        }
        AppDelegate.pendingDeepLink = nil
        let url = URL(fileURLWithPath: resolved)
        guard url.pathExtension.lowercased() == "md",
              FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        open(url)
    }

    /// Resolve a pending Services selection (#35), if one is waiting.
    ///
    /// PREFERS a window with a library. If THIS window has one, it claims the
    /// seed (atomically clearing the shared slot) and creates the file inside
    /// the library — Quoin already holds security scope on the root, so no new
    /// entitlement. If this window has NO library, the seed is LEFT for a window
    /// that does (the deep-link sibling `consumePendingDeepLink` defers the same
    /// way) — so the frontmost window being library-less no longer forces a save
    /// panel when another window owns the library.
    ///
    /// The `fallbackToPanel` save-panel path fires only when there is genuinely
    /// no library to create into (the no-library-configured case #35 must still
    /// support): the powerbox save panel, which the existing user-selected
    /// read-write entitlement permits. It is passed `false` on the warm
    /// notification (and re-tried a runloop hop later once every library window
    /// has had its synchronous first refusal) and `true` on the single-window
    /// cold-launch path.
    private func claimPendingSelectionSeed(fallbackToPanel: Bool) {
        guard let seed = AppDelegate.pendingSelectionSeed else { return }
        if library.rootURL != nil {
            AppDelegate.pendingSelectionSeed = nil
            if let url = library.createDocument(baseName: seed.baseName, content: seed.content) {
                open(url)
            } else {
                saveSelectionViaPanel(seed)
            }
        } else if fallbackToPanel {
            AppDelegate.pendingSelectionSeed = nil
            saveSelectionViaPanel(seed)
        }
        // else: no library here — leave the seed for a window that has one.
    }

    /// No-library fallback for the Services selection: a save panel (powerbox)
    /// lets the user place the new document anywhere; the grant it returns is
    /// what makes the write + subsequent open legal in the sandbox.
    private func saveSelectionViaPanel(_ seed: NewDocumentSeed.Seed) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.markdownDocument]
        panel.nameFieldStringValue = seed.baseName + ".md"
        panel.message = "Choose where to save the new document."
        panel.prompt = "Create"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard (try? Data(seed.content.utf8).write(to: url)) != nil else {
            NSSound.beep()
            return
        }
        open(url)
    }

    /// Publish (or resign) the active document as the current `NSUserActivity`
    /// (#36) so Handoff, Siri suggestions, and window restoration can resume it.
    ///
    /// The payload is a `quoin://` deep link built *relative to* this window's
    /// library root — NEVER an absolute file path or a security-scoped bookmark,
    /// so the resuming side re-resolves it through `QuoinURLScheme` and the
    /// sandbox boundary holds. Only the KEY window publishes (a background
    /// window's document isn't what the user is on), and a document that falls
    /// outside the granted library publishes NOTHING (`deepLink` returns nil) —
    /// the app has no portable, boundary-respecting handle for it.
    ///
    /// The activity object is reused across tab switches (one editing activity
    /// per window); resigned when the window is not key or has no linkable
    /// document; invalidated on close (`onDisappear`).
    private func updateUserActivity() {
        guard isKeyWindow,
              let url = activeTab?.url,
              let root = library.rootURL,
              let link = QuoinURLScheme.deepLink(
                forDocumentPath: url.standardizedFileURL.path,
                relativeTo: root.standardizedFileURL.path)
        else {
            currentActivity?.resignCurrent()
            return
        }
        let activity = currentActivity
            ?? NSUserActivity(activityType: QuoinURLScheme.editingActivityType)
        activity.title = url.deletingPathExtension().lastPathComponent
        activity.userInfo = [QuoinURLScheme.activityDeepLinkKey: link.absoluteString]
        activity.isEligibleForHandoff = true
        // Spotlight indexing is a separate feature (#6) — don't claim it here.
        activity.isEligibleForSearch = false
        currentActivity = activity
        activity.becomeCurrent()
    }

    /// Move the active tab by `delta` positions, wrapping around. A no-op
    /// with 0 or 1 tabs (nothing to switch to).
    private func cycleTab(by delta: Int) {
        guard openTabs.count > 1,
              let current = openTabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        let next = ((current + delta) % openTabs.count + openTabs.count) % openTabs.count
        activeTabID = openTabs[next].id
    }

    private func close(_ tab: DocumentTab) {
        let closedIndex = openTabs.firstIndex { $0.id == tab.id }
        openTabs.removeAll { $0.id == tab.id }
        // Let go of this window's hold on the file; the store stops the session
        // only when the LAST tab (across all windows) releases it.
        store.release(tab.url)
        // Browser-standard positional stability (#77): focus the tab now in
        // the closed tab's slot, not the rightmost tab.
        if activeTabID == tab.id {
            activeTabID = closedIndex
                .flatMap { TabSuccession.successorIndex(closedIndex: $0, remainingCount: openTabs.count) }
                .map { openTabs[$0].id }
        }
    }

    /// File ▸ Open…: markdown files anywhere on disk; each becomes a tab.
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.markdownDocument, .plainText]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where url.pathExtension.lowercased() == "md" {
            open(url)
        }
    }

    // MARK: - Shortcuts (conflict-audited map from the handoff)

    /// The one shortcut with no menu-bar home: the no-document sidebar-move
    /// undo. ⌘Z is the universal Undo gesture — Edit ▸ Undo is its conceptual
    /// home, but that item drives the document session (disabled with no
    /// document open), so this catches ⌘Z to reverse a sidebar file move made
    /// while no document is open. Tab switching (⌘1–9) moved into the Window
    /// menu (issue #5); everything else lives in File/Edit/View/Go/Format
    /// (QuoinApp.commands).
    private var windowShortcuts: some View {
        Group {
            // ⌘Z undoes sidebar file moves when no document is open;
            // with a document open, its edit-undo owns the shortcut.
            if activeTabID == nil {
                Button("") { library.undoLastMove() }
                    .keyboardShortcut("z", modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Empty states (per handoff §4)

    private var emptyState: some View {
        VStack(spacing: 10) {
            if offerSample { sampleOfferCard }
            Image(systemName: "doc.text")
                .quoinScaledFont(size: 44)
                .foregroundStyle(.primary.opacity(0.35))
            Text("No document open")
                .quoinScaledFont(size: 13, weight: .semibold)
                .foregroundStyle(.primary.opacity(0.55))
            Text("Select a document, or press ⌘N")
                .quoinScaledFont(size: 12)
                .foregroundStyle(.secondary)
            Button("New Document") {
                if let url = library.createDocument() { open(url) }
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
            .padding(.top, 6)
            HStack(spacing: 16) {
                Button(LibrarySeeding.welcome.menuTitle) {
                    openBundled(LibrarySeeding.welcome)
                }
                Button(LibrarySeeding.markdownGuide.menuTitle) {
                    openBundled(LibrarySeeding.markdownGuide)
                }
            }
            .buttonStyle(.link)
            .quoinScaledFont(size: 11)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Opt-in, non-modal first-run offer to drop the curated sample documents
    /// into a freshly chosen library (#13). Shown in the empty state; declining
    /// or opening any document dismisses it. Nothing is written unless the user
    /// taps Add.
    private var sampleOfferCard: some View {
        VStack(spacing: 8) {
            Text("New to Quoin?")
                .quoinScaledFont(size: 12.5, weight: .semibold)
            Text("Add a short Welcome note and a Markdown guide so you can explore Quoin's features. They're ordinary .md files you can edit or delete — nothing is added unless you choose to.")
                .quoinScaledFont(size: 11.5)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 12) {
                Button("Add Sample Documents") {
                    if let url = library.seedSampleDocuments() { open(url) }
                    offerSample = false
                }
                .buttonStyle(.borderedProminent)
                Button("No Thanks") { offerSample = false }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: 440)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 8)
    }

    /// Open a bundled Help/guide document from the empty state, materializing
    /// it into the library (or the writable Guides fallback) on first use.
    private func openBundled(_ doc: LibrarySeeding.BundledDocument) {
        if let url = library.materializeBundledDocument(resource: doc.resource, as: doc.filename) {
            open(url)
        }
    }

    private var chooseLibraryPrompt: some View {
        VStack(spacing: 10) {
            // A vanished library must never masquerade as a fresh install
            // (ledger senior #11) — say what happened and how to recover.
            if let failure = library.bookmarkRestoreFailure {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(failure)
                        .quoinScaledFont(size: 11.5)
                        .multilineTextAlignment(.leading)
                }
                .padding(10)
                .frame(maxWidth: 420)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 8)
            }
            Image(systemName: "doc.text")
                .quoinScaledFont(size: 36)
                .foregroundStyle(.primary.opacity(0.35))
            Text("Open a file, or set up a library")
                .quoinScaledFont(size: 13, weight: .semibold)
            Text("Your documents stay plain .md files on disk.\nQuoin never converts or moves your files.")
                .quoinScaledFont(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // Just edit a file — no library required (#18). First-class path,
            // so a single-file user is never forced to create a folder.
            Button("Open a File…") {
                presentOpenPanel()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
            // First frame of the real app should be a beautiful rendered
            // document, not an empty tree (launch ledger L1).
            Button("Create a Starter Library") {
                if let welcome = library.createStarterLibrary() { open(welcome) }
            }
            .buttonStyle(.bordered)
            Button("Choose an Existing Folder…") {
                // First-run: OFFER (never force) to drop the sample docs into a
                // folder that has none yet (#13). Only after a real pick (not a
                // cancelled panel), and only when the folder isn't already seeded.
                if library.chooseLibraryFolder() {
                    offerSample = library.shouldOfferSampleDocuments
                }
            }
            .buttonStyle(.bordered)
            Text("A library is just a folder Quoin watches — optional. Every document is a plain file you can open anywhere.")
                .quoinScaledFont(size: 10.5)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
