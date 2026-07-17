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
    /// Workspace memory (UI #4): open tabs survive relaunch. First line
    /// is the active tab's path, the rest are the tab order.
    @SceneStorage("QuoinOpenTabs") private var persistedTabs = ""

    private var activeTab: DocumentTab? {
        openTabs.first { $0.id == activeTabID }
    }
    @State private var isQuickOpenVisible = false
    @State private var isLibrarySearchVisible = false
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
                        ReaderScreen(model: model, fileURL: tab.url)
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
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openDocumentNotification)) { note in
            guard isKeyWindow else { return }
            if let url = note.userInfo?["url"] as? URL {
                open(url)
            }
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
        // File ▸ Close Tab (⌘W).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.closeTabNotification)) { _ in
            guard isKeyWindow, let tab = activeTab else { return }
            close(tab)
        }
        // File ▸ Open… (⌘O): native panel, markdown files only.
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openFilePanelNotification)) { _ in
            guard isKeyWindow else { return }
            presentOpenPanel()
        }
        // File ▸ Change Library Folder….
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.changeLibraryNotification)) { _ in
            guard isKeyWindow else { return }
            library.chooseLibraryFolder()
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
        // Help ▸ Markdown Guide / Welcome to Quoin: LIVE documents in the
        // library (editable examples — the guide teaches by being edited).
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openGuideNotification)) { _ in
            guard isKeyWindow else { return }
            if let url = library.materializeBundledDocument(
                resource: "MarkdownGuide", as: "Markdown Guide.md") { open(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openWelcomeNotification)) { _ in
            guard isKeyWindow else { return }
            if let url = library.materializeBundledDocument(
                resource: "WelcomeToQuoin", as: "Welcome to Quoin.md") { open(url) }
        }
        .onAppear {
            connectLibrary()
            restoreTabs()
            applyShotState()
        }
        // Every root change (chooser, starter library, folder-window) is
        // remembered as THIS window's folder.
        .onChange(of: library.rootURL) { _, url in
            if let url { persistedRootPath = url.standardizedFileURL.path }
        }
        // Closing the window (red button) with tabs still open must release the
        // store's hold on each, or their sessions leak (kept watching + never
        // stopped). ⌘W already releases per tab; this covers the whole-window
        // path. Autosave safety on quit is handled separately by the live-
        // session flush registry.
        .onDisappear {
            openTabs.forEach { store.release($0.url) }
        }
        .onChange(of: openTabs) { persistTabs() }
        .onChange(of: activeTabID) { persistTabs() }
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
            persistedTabs = "" // an empty start restores no workspace either
            return
        }
        library.restoreDefaultLibrary()
    }

    // MARK: - Workspace persistence (UI #4)

    private func persistTabs() {
        persistedTabs = ([activeTab?.url.path ?? ""] + openTabs.map(\.url.path)).joined(separator: "\n")
    }

    /// Restores tabs from the last session. Only files reachable through
    /// the library's security scope come back — a sandboxed relaunch has
    /// no access to one-off files that were opened via the panel.
    private func restoreTabs() {
        guard openTabs.isEmpty, !persistedTabs.isEmpty,
              let rootPath = library.rootURL?.standardizedFileURL.path else { return }
        let lines = persistedTabs.components(separatedBy: "\n")
        guard lines.count > 1 else { return }
        let restored = lines.dropFirst()
            .filter { $0.hasPrefix(rootPath + "/") && FileManager.default.fileExists(atPath: $0) }
            .map { DocumentTab(url: URL(fileURLWithPath: $0)) }
        guard !restored.isEmpty else { return }
        // Acquire BEFORE publishing the tabs so the model is present the first
        // time the body renders the active tab (no empty-state flash).
        restored.forEach { store.acquire($0.url) }
        openTabs = restored
        let activePath = lines[0]
        let active = restored.first { $0.url.path == activePath } ?? restored.last
        activeTabID = active?.id
        if let active {
            sidebarSelection = active.url
            library.reveal(url: active.url)
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

    /// Only what has no menu-bar home: tab switching (⌘1–9) and the
    /// no-document sidebar-move undo. Everything else moved into REAL
    /// menus (File/Edit/View/Go/Format — QuoinApp.commands).
    private var windowShortcuts: some View {
        Group {
            // ⌘Z undoes sidebar file moves when no document is open;
            // with a document open, its edit-undo owns the shortcut.
            if activeTabID == nil {
                Button("") { library.undoLastMove() }
                    .keyboardShortcut("z", modifiers: .command)
            }
            ForEach(1..<10) { index in
                Button("") {
                    if openTabs.indices.contains(index - 1) {
                        activeTabID = openTabs[index - 1].id
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Empty states (per handoff §4)

    private var emptyState: some View {
        VStack(spacing: 10) {
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
                Button("Welcome to Quoin") {
                    if let url = library.materializeBundledDocument(
                        resource: "WelcomeToQuoin", as: "Welcome to Quoin.md") { open(url) }
                }
                Button("Markdown Guide") {
                    if let url = library.materializeBundledDocument(
                        resource: "MarkdownGuide", as: "Markdown Guide.md") { open(url) }
                }
            }
            .buttonStyle(.link)
            .quoinScaledFont(size: 11)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                library.chooseLibraryFolder()
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
