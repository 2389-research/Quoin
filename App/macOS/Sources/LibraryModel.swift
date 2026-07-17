import AppKit
import Foundation
import SwiftUI
import QuoinCore

/// Owns the library: the user-picked root folder (persisted as a
/// security-scoped bookmark), the scanned tree, and file operations.
@MainActor
@Observable
final class LibraryModel {

    private static let bookmarkKey = "quoin.library.bookmark"
    /// Per-folder bookmarks (path → bookmark data): every folder the user
    /// has ever granted, so any window can reopen any of them (#61). The
    /// legacy single key stays as "most recent" for default new windows
    /// and migration.
    private static let bookmarksKey = "quoin.library.bookmarks"

    // Formerly @Published; @Observable observes these plain properties. The
    // internal state below is @ObservationIgnored to match the old @Published
    // set exactly.
    private(set) var root: LibraryNode?
    private(set) var rootURL: URL?
    var quickOpenQuery = ""
    private(set) var quickOpenResults: [QuickOpen.Result] = []
    /// Persistent library-wide search (⇧⌘F) shown in the sidebar.
    var librarySearchQuery = ""
    private(set) var librarySearchResults: [QuickOpen.Result] = []
    /// Expanded folders in the tree (standardized paths). `reveal(url:)`
    /// expands a document's ancestors so opening via quick open or Finder
    /// shows the selection.
    var expandedFolders: Set<String> = []

    /// Expand every ancestor folder of `url` up to the library root.
    func reveal(url: URL) {
        guard let rootURL else { return }
        let rootPath = rootURL.standardizedFileURL.path
        var directory = url.deletingLastPathComponent().standardizedFileURL
        while directory.path.hasPrefix(rootPath), directory.path != rootPath {
            expandedFolders.insert(directory.path)
            directory = directory.deletingLastPathComponent()
        }
    }

    @ObservationIgnored private var accessedURL: URL?
    @ObservationIgnored private var eventsWatcher: FSEventsWatcher?
    @ObservationIgnored private var librarySearchTask: Task<Void, Never>?
    @ObservationIgnored private var quickOpenTask: Task<Void, Never>?
    /// Coalesce full-tree rescans: at most one runs at a time; requests that
    /// arrive mid-scan collapse into a single re-run (QoL #34).
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var rescanRequestedDuringScan = false
    /// Hoisted out of `dailyNote()` — a fixed `yyyy-MM-dd` formatter never
    /// needs re-allocating (QoL #34).
    @ObservationIgnored private static let dailyNoteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    /// Inverse file moves for ⌘Z (design rule: sidebar moves are undoable).
    @ObservationIgnored private var moveUndoStack: [(from: URL, to: URL)] = []
    #if canImport(CoreSpotlight)
    /// In-app Core Spotlight indexer (#6): reconciled after every scan so
    /// system search finds documents, headings, and snippets. Local-only.
    @ObservationIgnored private let spotlightIndexer = SpotlightIndexer()
    #endif

    /// The restore decision is the WINDOW's (per-window roots + the launch
    /// setting live in scene state, unreadable at init) — MainWindow calls
    /// one of the restore/adopt entry points from onAppear. Only the
    /// screenshot-automation override applies here.
    init() {
        // `-QuoinLibraryPath /path` (launch argument → UserDefaults) bypasses
        // the folder picker — used by UI tests/screenshot automation and
        // handy for local development.
        if let path = UserDefaults.standard.string(forKey: "QuoinLibraryPath") {
            adopt(rootURL: URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    /// Default restore: the most recently used library (legacy single key).
    func restoreDefaultLibrary() {
        guard rootURL == nil else { return }
        restoreBookmark()
    }

    /// Reopen a SPECIFIC folder from the per-folder bookmark store — window
    /// restoration and Open Folder in New Window… (#61). Falls back to the
    /// legacy key when it points at the same path (migration).
    func adoptFolder(path: String) {
        guard rootURL?.standardizedFileURL.path != path else { return }
        guard let url = Self.resolveBookmark(forPath: path) else {
            bookmarkRestoreFailure = "Quoin lost access to \(URL(fileURLWithPath: path).lastPathComponent) — choose it again to reconnect; your documents are untouched on disk."
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            bookmarkRestoreFailure = "\(url.lastPathComponent) is no longer at \(url.deletingLastPathComponent().path). If you moved it, choose its new location."
            return
        }
        adopt(rootURL: url)
        Self.saveBookmarks(for: url)
    }

    /// Every grant lands in BOTH stores: the per-folder dictionary (any
    /// window can reopen it) and the legacy most-recent key.
    static func saveBookmarks(for url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        var all = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        all[url.standardizedFileURL.path] = bookmark
        UserDefaults.standard.set(all, forKey: bookmarksKey)
    }

    private static func resolveBookmark(forPath path: String) -> URL? {
        let all = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        var candidates: [Data] = []
        if let exact = all[path] { candidates.append(exact) }
        if let legacy = UserDefaults.standard.data(forKey: bookmarkKey) { candidates.append(legacy) }
        for data in candidates {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }
            guard url.standardizedFileURL.path == path else { continue }
            return url
        }
        return nil
    }

    deinit {
        librarySearchTask?.cancel()
        quickOpenTask?.cancel()
        accessedURL?.stopAccessingSecurityScopedResource()
    }

    var hasLibrary: Bool { rootURL != nil }

    // MARK: - Root folder

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder that holds your markdown documents."
        panel.prompt = "Use as Library"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adopt(rootURL: url)
        Self.saveBookmarks(for: url)
    }

    /// Why the saved library didn't come back (bookmark dead, folder
    /// gone) — shown by the first-run prompt so a vanished library never
    /// looks like a fresh install (ledger senior #11).
    private(set) var bookmarkRestoreFailure: String?

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            bookmarkRestoreFailure = "Quoin lost access to your library folder — it may have been moved, renamed, or deleted. Choose it again to reconnect; your documents are untouched on disk."
            return
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            bookmarkRestoreFailure = "Your library folder (\(url.lastPathComponent)) is no longer at \(url.deletingLastPathComponent().path). If you moved it, choose its new location — your documents are untouched."
            return
        }
        adopt(rootURL: url)
        // Migrate/refresh into the per-folder store so other windows can
        // reopen this folder by path.
        Self.saveBookmarks(for: url)
    }

    private func adopt(rootURL url: URL) {
        bookmarkRestoreFailure = nil
        librarySearchTask?.cancel()
        quickOpenTask?.cancel()
        librarySearchResults = []
        quickOpenResults = []
        accessedURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        accessedURL = url
        rootURL = url
        rescan()
        // Keep the sidebar live for external changes (Finder, sync, other
        // editors). FSEvents debounces internally.
        eventsWatcher = FSEventsWatcher(url: url) { [weak self] in
            // The FSEvents stream is dispatched on `DispatchQueue.main` (see
            // FSEventsWatcher.init), so this @Sendable callback always runs on
            // the main queue — `assumeIsolated` documents and checks that,
            // letting us touch this @MainActor model without an async hop that
            // would defer (and reorder) the rescan.
            MainActor.assumeIsolated {
                self?.rescan()
                if let self, !self.librarySearchQuery.isEmpty {
                    self.runLibrarySearch()
                }
            }
        }
    }

    // MARK: - Tree

    func rescan() {
        guard let rootURL else { return }
        // Coalesce: a scan already in flight absorbs this request (it re-runs
        // once when it finishes) instead of racing a second full-tree scan.
        // FSEvents already batches at 0.5s latency, but a burst that straddles
        // the window — or a direct mutation landing next to an FSEvent — would
        // otherwise spawn overlapping detached scans whose last completion wins
        // arbitrarily. Direct callers still get an immediate first scan.
        if scanTask != nil {
            rescanRequestedDuringScan = true
            return
        }
        // Scanning is fast (directory metadata only) but not free; keep the
        // walk off the main actor for large libraries. The owning task runs
        // ON the main actor (LibraryModel is @MainActor), so adopting the
        // result needs no `MainActor.run` hop — that hop was what tripped the
        // Swift 6 `sending self` check. Only the pure `Library.scan` detaches;
        // `rootURL` (a Sendable URL) crosses in and a Sendable `LibraryNode`
        // crosses back.
        scanTask = Task { [weak self] in
            let tree = await Task.detached(priority: .userInitiated) {
                Library.scan(root: rootURL)
            }.value
            guard let self else { return }
            self.root = tree
            self.scanTask = nil
            #if canImport(CoreSpotlight)
            // Reconcile the private Core Spotlight index against this scan (#6):
            // (re)index changed documents, delete items for files that moved or
            // vanished. Incremental and coalesced — cheap on an unchanged tree.
            self.spotlightIndexer.reconcile(root: tree, rootURL: rootURL)
            #endif
            if self.rescanRequestedDuringScan {
                self.rescanRequestedDuringScan = false
                self.rescan()
            }
        }
    }

    var documentCount: Int { root?.documentCount ?? 0 }

    // MARK: - File operations

    func rename(url: URL, to newName: String) -> URL? {
        guard let renamed = try? Library.rename(url, to: newName) else { return nil }
        rescan()
        return renamed
    }

    /// Drops from INSIDE the library move; drops from outside COPY — a
    /// drag from Desktop must never make the original vanish (UI #21).
    /// A failed drop beeps: silence reads as success.
    func importOrMove(url: URL, into folder: URL) {
        let standardized = url.standardizedFileURL.path
        if let rootPath = rootURL?.standardizedFileURL.path,
           standardized.hasPrefix(rootPath + "/") {
            if move(url: url, into: folder) == nil,
               url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
                NSSound.beep()
            }
        } else {
            let destination = Library.uniqueURL(
                baseName: url.deletingPathExtension().lastPathComponent,
                extension: url.pathExtension,
                in: folder)
            guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else {
                NSSound.beep()
                return
            }
            rescan()
        }
    }

    /// Sidebar drag-to-move: a real file move, recorded for ⌘Z.
    @discardableResult
    func move(url: URL, into folder: URL) -> URL? {
        guard url.deletingLastPathComponent() != folder,
              folder != url, // no folder-into-itself
              let moved = try? Library.move(url, into: folder)
        else { return nil }
        moveUndoStack.append((from: moved, to: url.deletingLastPathComponent()))
        rescan()
        return moved
    }

    var canUndoMove: Bool { !moveUndoStack.isEmpty }

    /// Posted after a document is moved to the Trash so open tabs for it
    /// can close instead of autosaving into a dead path.
    static let documentTrashedNotification = Notification.Name("quoin.documentTrashed")

    /// Move a file or folder to the Trash (recoverable — never a hard
    /// delete; the Finder's undo owns restoration).
    func trash(url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            // Silence reads as success; a failed trash beeps like a failed drop.
            NSSound.beep()
            return
        }
        NotificationCenter.default.post(
            name: Self.documentTrashedNotification, object: nil, userInfo: ["url": url])
        rescan()
    }

    /// Duplicate a document or folder to a unique sibling name, rescan, and
    /// return the copy so the caller can select/open it. A failed copy beeps
    /// (silence reads as success, matching trash and drag-drop).
    @discardableResult
    func duplicate(url: URL) -> URL? {
        guard let copy = try? Library.duplicate(url) else {
            NSSound.beep()
            return nil
        }
        rescan()
        return copy
    }

    /// Duplicate, first flushing any live session for `url` so the copy
    /// captures the latest keystrokes rather than the pre-debounce disk file
    /// (#12: autosave is 400ms-debounced, so a fast Duplicate right after
    /// typing would otherwise silently omit the last edits). Folders and
    /// unopened files skip straight to the copy — the flush no-ops when the URL
    /// isn't held open.
    @discardableResult
    func duplicateFlushingSession(url: URL) async -> URL? {
        await OpenDocumentStore.shared.flush(url)
        return duplicate(url: url)
    }

    /// New folder inside `parent` (or the library root), pre-expanded so
    /// the user sees where it landed.
    @discardableResult
    func createFolder(in parent: URL? = nil) -> URL? {
        guard let target = parent ?? rootURL else { return nil }
        // uniqueURL appends an extension; folders name themselves.
        var candidate = target.appendingPathComponent("New Folder", isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = target.appendingPathComponent("New Folder \(counter)", isDirectory: true)
            counter += 1
        }
        guard (try? FileManager.default.createDirectory(
            at: candidate, withIntermediateDirectories: false)) != nil else { return nil }
        expandedFolders.insert(target.standardizedFileURL.path)
        rescan()
        return candidate
    }

    /// Undoes the most recent sidebar move (moves the file back on disk).
    func undoLastMove() {
        guard let last = moveUndoStack.popLast() else { return }
        _ = try? Library.move(last.from, into: last.to)
        rescan()
    }

    // MARK: - Library-wide search (⇧⌘F)

    func runLibrarySearch() {
        guard let root else {
            librarySearchTask?.cancel()
            librarySearchResults = []
            return
        }
        let query = librarySearchQuery
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            librarySearchTask?.cancel()
            librarySearchResults = []
            return
        }
        librarySearchTask?.cancel()
        librarySearchTask = Task { [weak self, root, query] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                QuickOpen.search(query: query, in: root, maxResults: 40)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.librarySearchQuery == query else { return }
                self.librarySearchResults = results
                self.librarySearchTask = nil
            }
        }
    }

    /// New document in the library root (design: first H1 renames the file
    /// live once the editor supports it). Defaults to an empty "Untitled" —
    /// the ⌘N path; the Services provider (#35) passes a `baseName`/`content`
    /// pair from `NewDocumentSeed` to seed the file with a selection. Returns
    /// nil with no library configured, which the Services path reads as its
    /// cue to fall back to a save panel.
    func createDocument(
        in folder: URL? = nil,
        baseName: String = "Untitled",
        content: String = ""
    ) -> URL? {
        guard let target = folder ?? rootURL else { return nil }
        let candidate = Library.uniqueURL(baseName: baseName, extension: "md", in: target)
        guard (try? Data(content.utf8).write(to: candidate)) != nil else { return nil }
        rescan()
        return candidate
    }

    // MARK: - Starter library + bundled documents (launch ledger L1/L2/L5)

    /// Copies a bundled document into the library (if absent) and returns
    /// its URL — the guide and welcome docs are LIVE documents, editable
    /// like everything else, never read-only bundle views.
    func materializeBundledDocument(resource: String, as filename: String) -> URL? {
        // XcodeGen folder-type resources land under Resources/ inside the
        // bundle; a plain lookup returned nil and the Welcome/Guide
        // buttons silently did nothing (field report).
        let source = Bundle.main.url(forResource: resource, withExtension: "md")
            ?? Bundle.main.url(forResource: resource, withExtension: "md", subdirectory: "Resources")
        guard let rootURL, let source else { return nil }
        let destination = rootURL.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: destination.path) {
            guard (try? FileManager.default.copyItem(at: source, to: destination)) != nil else {
                return nil
            }
            rescan()
        }
        return destination
    }

    /// First-run path A: create a fresh library folder and seed it with
    /// the welcome document and the markdown guide.
    func createStarterLibrary() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Create a Starter Library"
        panel.prompt = "Create"
        panel.nameFieldStringValue = "Quoin"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        adopt(rootURL: url)
        Self.saveBookmarks(for: url)
        _ = materializeBundledDocument(resource: "MarkdownGuide", as: "Markdown Guide.md")
        return materializeBundledDocument(resource: "WelcomeToQuoin", as: "Welcome to Quoin.md")
    }

    // MARK: - Recents (idea #13) + daily note (idea #14)

    private static let recentsKey = RecentDocuments.defaultsKey

    /// Called on every document open (Finder, ⌘O, sidebar, deep link, Open
    /// Recent); feeds the Open Recent / dock menus and quick open's empty-query
    /// list. The MRU rules live in the platform-free `RecentDocuments` seam.
    func recordOpen(_ url: URL) {
        let list = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        UserDefaults.standard.set(
            RecentDocuments.recording(url.path, into: list), forKey: Self.recentsKey)
    }

    var recentDocuments: [URL] {
        RecentDocuments.present(
            in: UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? [],
            exists: { FileManager.default.fileExists(atPath: $0) }
        ).map { URL(fileURLWithPath: $0) }
    }

    /// Today's note: `Journal/YYYY-MM-DD.md`, created on first visit with
    /// a date heading.
    func dailyNote() -> URL? {
        guard let rootURL else { return nil }
        let journal = rootURL.appendingPathComponent("Journal", isDirectory: true)
        try? FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let name = Self.dailyNoteFormatter.string(from: Date())
        let url = journal.appendingPathComponent("\(name).md")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? Data("# \(name)\n\n".utf8).write(to: url)) != nil else { return nil }
            rescan()
        }
        return url
    }

    // MARK: - Quick open

    func runQuickOpen() {
        guard let root else {
            quickOpenTask?.cancel()
            quickOpenResults = []
            return
        }
        let query = quickOpenQuery
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            // Empty query = the recents list: what you touched last is
            // what you almost always want next (idea #13).
            quickOpenTask?.cancel()
            quickOpenResults = recentDocuments.prefix(8).map {
                QuickOpen.Result(
                    url: $0,
                    title: $0.deletingPathExtension().lastPathComponent,
                    snippet: "", score: 0)
            }
            return
        }
        quickOpenTask?.cancel()
        quickOpenTask = Task { [weak self, root, query] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                QuickOpen.search(query: query, in: root)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.quickOpenQuery == query else { return }
                self.quickOpenResults = results
                self.quickOpenTask = nil
            }
        }
    }
}
