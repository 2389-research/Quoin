import AppKit
import QuoinCore
import SwiftUI
import UniformTypeIdentifiers
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

@main
struct QuoinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #if canImport(Sparkle)
    @StateObject private var updater = SoftwareUpdater()
    #endif

    var body: some Scene {
        // The window VALUE is a library-folder path: plain New Window opens
        // with nil (most-recent library); Open Folder in New Window… passes
        // the picked folder (#61).
        WindowGroup(id: "main", for: String.self) { $rootPath in
            MainWindow(requestedRootPath: rootPath)
                // Floor the window so the sidebar + editor + inspector triad
                // can't be crushed to a sliver (the split-view column mins
                // don't floor the whole window).
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 1280, height: 800) // 16:10 — room for sidebar + editor + outline/inspector
        .commands {
            // File menu: honest items for what the keys actually do. The
            // system's "New Window"/"Close" pair lied about ⌘N/⌘W (launch
            // ledger UI #5); the real grammar is documents and tabs.
            FileCommands()
            // Save is automatic (autosave-in-place).
            CommandGroup(replacing: .saveItem) {}
            EditCommands()
            AboutCommands()
            #if canImport(Sparkle)
            // Quoin ▸ Check for Updates… (Sparkle), directly under About.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: updater)
            }
            #endif
            // Format / View / Go / Window / File-export menus, bundled into
            // one Commands node so the top-level builder stays under its
            // 10-child limit.
            MenuBarCommands()
            // Help menu: real content, not just search (launch ledger L5/L14).
            CommandGroup(replacing: .help) {
                Button("Markdown Guide") {
                    NotificationCenter.default.post(name: AppDelegate.openGuideNotification, object: nil)
                }
                Button("Welcome to Quoin") {
                    NotificationCenter.default.post(name: AppDelegate.openWelcomeNotification, object: nil)
                }
                Divider()
                Button("Report an Issue…") {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    let os = ProcessInfo.processInfo.operatingSystemVersionString
                    let body = "\n\n—\nQuoin \(version) · macOS \(os)"
                        .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let url = URL(string: "https://github.com/2389-research/Quoin/issues/new?body=\(body)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        // Quoin ▸ Settings… (⌘,): appearance + editor preferences.
        Settings {
            SettingsView()
        }

        // Quoin ▸ About Quoin: the custom about window.
        Window("About Quoin", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// The key window's editing state, published by ReaderScreen so menu
/// titles can follow it (Edit Source ↔ Done Editing).
struct QuoinIsEditingBlockKey: FocusedValueKey {
    typealias Value = Bool
}

/// Whether the key window has an open document — drives menu enablement
/// (launch ledger UI #6/#7: items that can't act must be disabled).
struct QuoinHasDocumentKey: FocusedValueKey {
    typealias Value = Bool
}

/// The key window's next Undo/Redo action, or nil when that stack is empty.
/// Drives the Edit menu's item TITLE ("Undo Typing") and its enablement in
/// one value — nil both disables the item and drops it back to bare "Undo".
struct QuoinUndoActionKey: FocusedValueKey {
    typealias Value = UndoActionName
}
struct QuoinRedoActionKey: FocusedValueKey {
    typealias Value = UndoActionName
}

extension FocusedValues {
    var quoinIsEditingBlock: Bool? {
        get { self[QuoinIsEditingBlockKey.self] }
        set { self[QuoinIsEditingBlockKey.self] = newValue }
    }
    var quoinHasDocument: Bool? {
        get { self[QuoinHasDocumentKey.self] }
        set { self[QuoinHasDocumentKey.self] = newValue }
    }
    var quoinUndoAction: UndoActionName? {
        get { self[QuoinUndoActionKey.self] }
        set { self[QuoinUndoActionKey.self] = newValue }
    }
    var quoinRedoAction: UndoActionName? {
        get { self[QuoinRedoActionKey.self] }
        set { self[QuoinRedoActionKey.self] = newValue }
    }
    var quoinFocusMode: Bool? {
        get { self[QuoinFocusModeKey.self] }
        set { self[QuoinFocusModeKey.self] = newValue }
    }
    var quoinSentenceFocus: Bool? {
        get { self[QuoinSentenceFocusKey.self] }
        set { self[QuoinSentenceFocusKey.self] = newValue }
    }
    var quoinTypewriter: Bool? {
        get { self[QuoinTypewriterKey.self] }
        set { self[QuoinTypewriterKey.self] = newValue }
    }
}

/// The key window's PER-WINDOW writing-mode state (#29). The View-menu
/// toggles read these so their checkmarks follow the focused document, and
/// flip them by posting a notification the key window observes — @SceneStorage
/// itself is unreachable from app-level Commands.
struct QuoinFocusModeKey: FocusedValueKey { typealias Value = Bool }
struct QuoinSentenceFocusKey: FocusedValueKey { typealias Value = Bool }
struct QuoinTypewriterKey: FocusedValueKey { typealias Value = Bool }

private func post(_ name: Notification.Name, userInfo: [String: Any]? = nil) {
    NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
}

/// File menu: New Document ⌘N / New Window ⇧⌘N / Open… ⌘O / Open Recent /
/// Close Tab ⌘W (the system Close item is retitled Close Window ⇧⌘W by the
/// app delegate). Every action routes to the KEY window via gated
/// notifications — never broadcast (launch ledger BLOCKER).
private struct FileCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.quoinHasDocument) private var hasDocument

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Document") { post(AppDelegate.newDocumentNotification) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open…") { post(AppDelegate.openFilePanelNotification) }
                .keyboardShortcut("o", modifiers: .command)
            Button("Open Folder in New Window…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.message = "Choose a folder to open in a new window."
                panel.prompt = "Open Folder"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                LibraryModel.saveBookmarks(for: url)
                openWindow(id: "main", value: url.standardizedFileURL.path)
            }
            Menu("Open Recent") {
                let recents = RecentDocuments.present(
                    in: UserDefaults.standard.stringArray(forKey: RecentDocuments.defaultsKey) ?? [],
                    limit: 10,
                    exists: { FileManager.default.fileExists(atPath: $0) }
                ).map { URL(fileURLWithPath: $0) }
                ForEach(recents, id: \.path) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        AppDelegate.requestOpen(url)
                    }
                }
                if !recents.isEmpty {
                    Divider()
                    Button("Clear Menu") {
                        UserDefaults.standard.removeObject(forKey: RecentDocuments.defaultsKey)
                        NSDocumentController.shared.clearRecentDocuments(nil)
                    }
                }
            }
            Divider()
            // Document management: the current document (active tab) is the
            // target. Neither carries a key equivalent: ⌘D is Daily Note, and
            // ⌘⌫ is AppKit's system deleteToBeginningOfLine: editing binding —
            // a menu key equivalent would win over the first responder via
            // NSApplication.sendEvent and turn a common in-line delete into a
            // (not-in-app-undoable) document trash. Trashing stays menu/context
            // only, matching Duplicate.
            Button("Duplicate") { post(AppDelegate.duplicateDocumentNotification) }
                .disabled(hasDocument != true)
            Button("Move to Trash") { post(AppDelegate.trashDocumentNotification) }
                .disabled(hasDocument != true)
            Divider()
            Button("Close Tab") { post(AppDelegate.closeTabNotification) }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(hasDocument != true)
            Divider()
            // Reveal the front document in Finder. The sidebar's context menu
            // reveals a selected node; this acts on the active tab, so it's
            // reachable without hunting for the file in the tree (issue #5).
            // No key equivalent — Finder's own ⌘R meanings vary and the menu
            // is enough for an infrequent action.
            Button("Show in Finder") { post(AppDelegate.revealInFinderNotification) }
                .disabled(hasDocument != true)
            Divider()
            Button("Change Library Folder…") { post(AppDelegate.changeLibraryNotification) }
        }
    }
}

/// Edit menu: real Undo/Redo (enabled only with a document) + the Find
/// family, which used to be invisible window-local shortcuts.
private struct EditCommands: Commands {
    @FocusedValue(\.quoinHasDocument) private var hasDocument
    // nil means "nothing to undo/redo" — disables the item AND drops its
    // title back to bare "Undo"/"Redo" (HIG: name the action, disable on
    // an empty stack). With no document these are nil too, so ⌘Z falls
    // through to the no-document sidebar-move undo in MainWindow.
    @FocusedValue(\.quoinUndoAction) private var undoAction
    @FocusedValue(\.quoinRedoAction) private var redoAction

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(undoAction.map { "Undo \($0.menuTitle)" } ?? "Undo") {
                post(AppDelegate.undoNotification)
            }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(undoAction == nil)
            Button(redoAction.map { "Redo \($0.menuTitle)" } ?? "Redo") {
                post(AppDelegate.redoNotification)
            }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(redoAction == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find in Document…") { post(AppDelegate.findNotification) }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(hasDocument != true)
                Button("Find & Replace…") { post(AppDelegate.findReplaceNotification) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(hasDocument != true)
                Button("Find Next") { post(AppDelegate.findNextNotification) }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(hasDocument != true)
                Button("Find Previous") { post(AppDelegate.findPreviousNotification) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(hasDocument != true)
                Divider()
                Button("Search Library…") { post(AppDelegate.toggleLibrarySearchNotification) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
    }
}

/// View menu: panel toggles + the writing-environment toggles as REAL
/// checkmarked toggles. Focus/Sentence/Typewriter are now PER-WINDOW (#29):
/// their checkmarks read the key window's focused value and flip it by
/// posting a toggle the key window observes (app-level Commands can't read
/// @SceneStorage). Status Bar and text zoom stay global @AppStorage — they
/// are app preferences, not per-document writing modes.
private struct ViewCommands: Commands {
    @FocusedValue(\.quoinHasDocument) private var hasDocument
    @FocusedValue(\.quoinFocusMode) private var focusMode
    @FocusedValue(\.quoinSentenceFocus) private var sentenceFocus
    @FocusedValue(\.quoinTypewriter) private var typewriter
    @AppStorage("QuoinShowStatusBar") private var showStatusBar = true
    @AppStorage("QuoinTextScale") private var textScale = 1.0
    @AppStorage("QuoinWordWrap") private var wordWrap = true

    /// A checkmark that mirrors the key window's per-window state and toggles
    /// it through a notification (the set value is ignored — the window owns
    /// the truth and republishes it).
    private func toggleBinding(
        _ value: Bool?, _ notification: Notification.Name
    ) -> Binding<Bool> {
        Binding(get: { value ?? false }, set: { _ in post(notification) })
    }

    var body: some Commands {
        // Replacing .sidebar also removes the system Toggle Sidebar
        // duplicate (⌃⌘S) — Quoin's ⌘0 is the one true toggle (UI #19).
        CommandGroup(replacing: .sidebar) {
            Button("Show/Hide Sidebar") { post(AppDelegate.toggleSidebarNotification) }
                .keyboardShortcut("0", modifiers: .command)
            Button("Show/Hide Outline") { post(AppDelegate.toggleOutlineNotification) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Toggle("Status Bar", isOn: $showStatusBar)
            Divider()
            // No key equivalent: every F chord is taken (⌘F Find, ⌥⌘F
            // Replace, ⇧⌘F Search Library) and ⌃⌘F is the SYSTEM's Enter Full
            // Screen — binding it there produced two menu items on one chord.
            // Focus Mode stays reachable via this menu + the toolbar button;
            // a deliberate chord can be assigned from the keyboard map later.
            Toggle("Focus Mode", isOn: toggleBinding(focusMode, AppDelegate.toggleFocusModeNotification))
                .disabled(hasDocument != true)
            Toggle("Sentence Focus", isOn: toggleBinding(sentenceFocus, AppDelegate.toggleSentenceFocusNotification))
                .disabled(hasDocument != true || focusMode != true)
            Toggle("Typewriter Scrolling", isOn: toggleBinding(typewriter, AppDelegate.toggleTypewriterNotification))
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(hasDocument != true)
            Divider()
            // Document text zoom. ⌘0 is Show/Hide Sidebar, so reset is ⌃⌘0.
            Button("Zoom In") { textScale = min((textScale > 0 ? textScale : 1) + 0.1, 2.5) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { textScale = max((textScale > 0 ? textScale : 1) - 0.1, 0.6) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { textScale = 1 }
                .keyboardShortcut("0", modifiers: [.command, .control])
            Divider()
            // Wrap long lines to the column, or let them run and scroll (#R2).
            Toggle("Wrap Lines", isOn: $wordWrap)
            Divider()
        }
    }
}

/// Go menu: navigation that existed only as invisible shortcuts (UI #12).
private struct GoCommands: Commands {
    @FocusedValue(\.quoinHasDocument) private var hasDocument

    var body: some Commands {
        CommandMenu("Go") {
            Button("Back") { post(AppDelegate.goBackNotification) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(hasDocument != true)
            Button("Forward") { post(AppDelegate.goForwardNotification) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(hasDocument != true)
            Divider()
            Button("Quick Open…") { post(AppDelegate.toggleQuickOpenNotification) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Daily Note") { post(AppDelegate.dailyNoteNotification) }
                .keyboardShortcut("d", modifiers: .command)
        }
    }
}

/// Bundles the discoverable menus (Format, View, Go, Window, File-export)
/// into a single `Commands` node — the App's top-level `.commands` builder
/// caps at ten children, and Window/Next-Previous-Tab (#29) was the eleventh.
private struct MenuBarCommands: Commands {
    var body: some Commands {
        FormatCommands()
        ViewCommands()
        GoCommands()
        WindowCommands()
        ExportCommands()
    }
}

/// Window menu: Quoin's own document tabs get standard Show Next/Previous
/// Tab items (⌃⇥ / ⌃⇧⇥) plus the direct Select Tab 1–9 items (⌘1–9). System
/// window tabbing is off (`allowsAutomaticWindowTabbing = false`), so these
/// drive Quoin's tab bar, not native window tabs. Show Next/Previous came in
/// with #29; the numbered items lived only as invisible ⌘1–9 buttons in
/// MainWindow until this (issue #5). Enabled only with a document — with none
/// there is no tab to switch to.
private struct WindowCommands: Commands {
    @FocusedValue(\.quoinHasDocument) private var hasDocument

    var body: some Commands {
        CommandGroup(before: .windowArrangement) {
            Button("Show Next Tab") { post(AppDelegate.nextTabNotification) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(hasDocument != true)
            Button("Show Previous Tab") { post(AppDelegate.previousTabNotification) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(hasDocument != true)
            Divider()
            // ⌘1–9 select the Nth open tab directly. The item stays enabled
            // whenever a document is open (the app-level menu can't count the
            // key window's tabs); selecting past the last tab no-ops, exactly
            // as the invisible buttons did.
            ForEach(1..<10) { index in
                Button("Select Tab \(index)") {
                    post(AppDelegate.selectTabNotification, userInfo: ["index": index])
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                .disabled(hasDocument != true)
            }
            Divider()
        }
    }
}

/// File ▸ Export…/Print… — enabled only with a document to act on.
private struct ExportCommands: Commands {
    @FocusedValue(\.quoinHasDocument) private var hasDocument

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export…") { post(AppDelegate.exportNotification) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(hasDocument != true)
            // Page Setup… (⇧⌘P) sits directly above Print, the standard File-
            // menu pairing. ⇧⌘P is free (⌘P is Print; we never take the
            // system's ⌘P meaning). Both gate on a document to act on.
            Button("Page Setup…") { post(AppDelegate.pageSetupNotification) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(hasDocument != true)
            Button("Print…") { post(AppDelegate.printNotification) }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(hasDocument != true)
        }
    }
}

/// Format menu: the formatting grammar as real, discoverable menu items.
/// The Edit Source title follows the focused window's editing state — a
/// menu item that mislabels its action reads as broken.
private struct FormatCommands: Commands {
    @FocusedValue(\.quoinIsEditingBlock) private var isEditingBlock
    @FocusedValue(\.quoinHasDocument) private var hasDocument

    private func postFormat(_ name: Notification.Name, format: String? = nil) {
        post(name, userInfo: format.map { ["format": $0] })
    }

    private func postStructure(_ op: String) {
        post(AppDelegate.structureNotification, userInfo: ["op": op])
    }

    var body: some Commands {
        CommandMenu("Format") {
            Group {
                Button("Bold") { postFormat(AppDelegate.formatNotification, format: "bold") }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Italic") { postFormat(AppDelegate.formatNotification, format: "italic") }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Strikethrough") { postFormat(AppDelegate.formatNotification, format: "strikethrough") }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Button("Inline Code") { postFormat(AppDelegate.formatNotification, format: "code") }
                    .keyboardShortcut("e", modifiers: [.command, .control])
                Button("Highlight") { postFormat(AppDelegate.formatNotification, format: "highlight") }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Add Link") { postFormat(AppDelegate.formatNotification, format: "link") }
                    .keyboardShortcut("k", modifiers: .command)
            }
            .disabled(isEditingBlock != true)
            Divider()
            Group {
                Button("Move Block Up") {
                    post(AppDelegate.moveBlockNotification, userInfo: ["direction": "up"])
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Move Block Down") {
                    post(AppDelegate.moveBlockNotification, userInfo: ["direction": "down"])
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Button(isEditingBlock == true ? "Done Editing" : "Edit Source") {
                    postFormat(AppDelegate.toggleEditSourceNotification)
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
            .disabled(hasDocument != true)
            Divider()
            // Structure (#25): line-prefix edits on the caret's block. Enabled
            // only while a block is being edited — they act on that block.
            Menu("Structure") {
                Menu("Heading") {
                    Button("No Heading") { postStructure("h0") }
                    Divider()
                    Button("Heading 1") { postStructure("h1") }
                        .keyboardShortcut("1", modifiers: [.command, .option])
                    Button("Heading 2") { postStructure("h2") }
                        .keyboardShortcut("2", modifiers: [.command, .option])
                    Button("Heading 3") { postStructure("h3") }
                        .keyboardShortcut("3", modifiers: [.command, .option])
                    Button("Heading 4") { postStructure("h4") }
                        .keyboardShortcut("4", modifiers: [.command, .option])
                    Button("Heading 5") { postStructure("h5") }
                        .keyboardShortcut("5", modifiers: [.command, .option])
                    Button("Heading 6") { postStructure("h6") }
                        .keyboardShortcut("6", modifiers: [.command, .option])
                    Divider()
                    Button("Cycle Heading Level") { postStructure("cycleHeading") }
                }
                Divider()
                Button("Toggle Bullet List") { postStructure("bullet") }
                Button("Toggle Numbered List") { postStructure("numbered") }
                Button("Toggle Block Quote") { postStructure("quote") }
                Divider()
                Button("Toggle Checkbox") { postStructure("checkbox") }
                    .keyboardShortcut(.return, modifiers: [.command, .control])
            }
            .disabled(isEditingBlock != true)
            Divider()
            // Review gestures (suggestions §3.6, S3a): annotate the
            // selection without changing the prose. ⇧⌘H stays with the
            // formatting Highlight above; the review highlight is
            // menu/context-menu only.
            Menu("Review") {
                Button("Add Comment…") { post(AppDelegate.addCommentNotification) }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Suggest Replacement…") { post(AppDelegate.suggestReplacementNotification) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Suggest Deletion") { post(AppDelegate.suggestDeletionNotification) }
                Button("Highlight for Review") { post(AppDelegate.reviewHighlightNotification) }
                Divider()
                Button("Suggest Edits") { post(AppDelegate.toggleSuggestModeNotification) }
                    .keyboardShortcut("r", modifiers: [.command, .control])
            }
            .disabled(hasDocument != true)
        }
    }
}

/// Replaces the standard About item with the custom window. A separate
/// `Commands` type because `openWindow` is only available through the
/// environment.
private struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Quoin") { openWindow(id: "about") }
        }
    }
}

/// One-shot delivery of `applicationShouldTerminate`'s deferred reply. The
/// flush task and the watchdog both race to answer; whichever arrives first
/// replies and disarms the other. `@MainActor` (so `didReply` needs no
/// locking and `reply` is on AppKit's actor) and therefore implicitly
/// Sendable, so the detached flush can carry it without capturing the
/// non-Sendable `NSApplication` directly.
@MainActor
private final class TerminationReplyBox {
    private let app: NSApplication
    private var didReply = false

    init(_ app: NSApplication) { self.app = app }

    func reply() {
        guard !didReply else { return }
        didReply = true
        app.reply(toApplicationShouldTerminate: true)
    }
}

/// Handles Finder "Open With Quoin" for individual files.
///
/// `@MainActor`: an app delegate's callbacks all run on the main thread, and
/// its shared mutable slot (`pendingDeepLink`) is written from
/// `application(_:open:)` and drained by `MainWindow`, both on the main actor.
/// Annotating the class isolates that state instead of leaving it as
/// nonisolated global mutable state (a Swift 6 data-race error). The static
/// `Notification.Name` constants are immutable `Sendable` values, so they stay
/// freely readable from anywhere.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let openDocumentNotification = Notification.Name("quoin.openDocument")
    /// File-open URLs (Finder double-click / Open With, Open Recent, dock recents,
    /// a markdown file dropped on the editor) waiting for a window to open them.
    /// A SLOT — not the notification's `userInfo` — so a COLD launch, where the
    /// open arrives before any `MainWindow` observer is subscribed, can still be
    /// drained from the first window's `onAppear` (the same reason `quoin://`
    /// deep links and Services seeds use slots). Every opener appends here and
    /// posts `openDocumentNotification`; the key window (or, cold, the first
    /// window's `onAppear`) drains the whole array atomically, so a dropped
    /// notification never loses an open. Empty between deliveries.
    static var pendingOpenURLs: [URL] = []

    /// Append a file URL to the pending-open slot and signal a window to drain
    /// it. Routes Finder/menu/dock/drop opens through the ONE open path
    /// (`MainWindow.open`, i.e. a real tab + session), never detached state.
    static func requestOpen(_ url: URL) {
        pendingOpenURLs.append(url)
        NotificationCenter.default.post(name: openDocumentNotification, object: nil)
    }
    /// A `quoin://` deep link was received (#31). The parsed link is stashed in
    /// `pendingDeepLink`; the key window resolves it against ITS library root
    /// and drains the slot. A slot (not the notification's userInfo) is used so
    /// a cold launch — where the URL arrives before any window's observer is
    /// installed — can still drain it from the first window's `onAppear`.
    static let openDeepLinkNotification = Notification.Name("quoin.openDeepLink")
    /// The Services provider ("New Quoin Document with Selection", #35) captured
    /// a selection from another app. The seed is stashed in
    /// `pendingSelectionSeed`; the key window creates + opens a document from it
    /// (or falls back to a save panel when no library is configured). A slot
    /// (not the notification's userInfo) is used so a cold launch — where the
    /// service message arrives before any window's observer exists — can still
    /// drain it from the first window's `onAppear`, exactly like a deep link.
    static let newDocumentWithSelectionNotification = Notification.Name("quoin.newDocumentWithSelection")
    static let toggleSidebarNotification = Notification.Name("quoin.toggleSidebar")
    static let toggleOutlineNotification = Notification.Name("quoin.toggleOutline")
    static let toggleEditSourceNotification = Notification.Name("quoin.toggleEditSource")
    static let moveBlockNotification = Notification.Name("quoin.moveBlock")
    static let openGuideNotification = Notification.Name("quoin.openGuide")
    static let openWelcomeNotification = Notification.Name("quoin.openWelcome")
    static let formatNotification = Notification.Name("quoin.format")
    static let structureNotification = Notification.Name("quoin.structure")
    static let undoNotification = Notification.Name("quoin.undo")
    static let redoNotification = Notification.Name("quoin.redo")
    static let exportNotification = Notification.Name("quoin.export")
    static let printNotification = Notification.Name("quoin.print")
    static let pageSetupNotification = Notification.Name("quoin.pageSetup")
    static let nextTabNotification = Notification.Name("quoin.nextTab")
    static let previousTabNotification = Notification.Name("quoin.previousTab")
    /// Select the Nth open tab (⌘1–9). `userInfo["index"]` is 1-based; an
    /// index past the open-tab count is a no-op (matches the old invisible
    /// ⌘1–9 buttons this replaced).
    static let selectTabNotification = Notification.Name("quoin.selectTab")
    /// Reveal the KEY window's active document in Finder (File ▸ Show in
    /// Finder). The sidebar's context menu reveals a SELECTED node; this
    /// acts on the front document, so it works without a sidebar selection.
    static let revealInFinderNotification = Notification.Name("quoin.revealInFinder")
    static let toggleFocusModeNotification = Notification.Name("quoin.toggleFocusMode")
    static let toggleSentenceFocusNotification = Notification.Name("quoin.toggleSentenceFocus")
    static let toggleTypewriterNotification = Notification.Name("quoin.toggleTypewriter")
    static let newDocumentNotification = Notification.Name("quoin.newDocument")
    static let duplicateDocumentNotification = Notification.Name("quoin.duplicateDocument")
    static let trashDocumentNotification = Notification.Name("quoin.trashDocument")
    static let closeTabNotification = Notification.Name("quoin.closeTab")
    static let openFilePanelNotification = Notification.Name("quoin.openFilePanel")
    static let dailyNoteNotification = Notification.Name("quoin.dailyNote")
    static let toggleQuickOpenNotification = Notification.Name("quoin.toggleQuickOpen")
    static let toggleLibrarySearchNotification = Notification.Name("quoin.toggleLibrarySearch")
    static let findNotification = Notification.Name("quoin.find")
    static let findReplaceNotification = Notification.Name("quoin.findReplace")
    static let findNextNotification = Notification.Name("quoin.findNext")
    static let findPreviousNotification = Notification.Name("quoin.findPrevious")
    static let goBackNotification = Notification.Name("quoin.goBack")
    static let goForwardNotification = Notification.Name("quoin.goForward")
    static let changeLibraryNotification = Notification.Name("quoin.changeLibrary")
    static let addCommentNotification = Notification.Name("quoin.review.addComment")
    static let suggestReplacementNotification = Notification.Name("quoin.review.suggestReplacement")
    static let suggestDeletionNotification = Notification.Name("quoin.review.suggestDeletion")
    static let reviewHighlightNotification = Notification.Name("quoin.review.highlight")
    static let toggleSuggestModeNotification = Notification.Name("quoin.review.toggleSuggestMode")

    /// ⌘Q inside the autosave debounce window used to drop the last
    /// keystrokes — drain every live session before the process dies.
    /// The flush runs DETACHED (sessions are plain actors, not
    /// main-actor): a MainActor Task is not guaranteed to execute while
    /// the runloop spins in the terminateLater mode — the first
    /// implementation of this method lost data exactly that way.
    ///
    /// Two paths race to answer `terminateLater`: the flush completing and a
    /// 3s watchdog. `TerminationReplyBox` makes the answer one-shot (calling
    /// `NSApplication.reply` twice is undefined) and owns the `NSApplication`
    /// so no non-Sendable AppKit object is captured in the detached @Sendable
    /// flush — only the box (a Sendable @MainActor class) crosses, and the
    /// reply hops back to the main actor to fire.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let sessions = ReaderModel.liveSessionSnapshot()
        guard !sessions.isEmpty else { return .terminateNow }
        let replyBox = TerminationReplyBox(sender)
        Task.detached(priority: .userInitiated) {
            for session in sessions {
                try? await session.saveNow()
            }
            await MainActor.run { replyBox.reply() }
        }
        // Watchdog: never let a hung save wedge quit for more than 3s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            replyBox.reply()
        }
        return .terminateLater
    }

    /// True while the app is still inside its launch window — how a
    /// restored-at-launch window is told apart from one the user opened
    /// mid-session ("start empty" applies only to the former).
    static var isLaunchRestoration: Bool {
        ProcessInfo.processInfo.systemUptime - launchUptime < 5
    }
    private static let launchUptime = ProcessInfo.processInfo.systemUptime

    /// Opt into secure state restoration (the modern default); without this
    /// macOS logs "does not implement… returning NO" and opts the app out.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Register as a Services PROVIDER (#35) as EARLY as possible — before the
    /// run loop starts. The NSServices array in Info.plist declares the menu
    /// item + NSMessage; this hands macOS the object whose @objc
    /// `newDocumentWithSelection(_:userData:error:)` handles it. Quoin stays a
    /// services *requestor* too — NSTextView's built-in Services support is
    /// untouched by registering a provider.
    ///
    /// This MUST be `applicationWillFinishLaunching`, not
    /// `applicationDidFinishLaunching`: a COLD launch triggered by another app
    /// picking "New Quoin Document with Selection" delivers the service message
    /// as part of bringing Quoin up, and that can land BEFORE
    /// `didFinishLaunching`. Registering the provider in `willFinishLaunching`
    /// (Apple's guidance: register before the run loop) guarantees the provider
    /// object exists when the launch-triggering message arrives, so the seed is
    /// stashed and the cold-launch `onAppear` drain has something to consume.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Quoin has its own document tabs; the system window-tab items
        // ("Show Tab Bar" etc.) would only confuse the View menu.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Apply the stored appearance preference (System / Light / Dark).
        // The screenshot-automation pin (-QuoinForceDarkMode YES) wins over
        // the preference inside applyStored, so CI captures stay
        // deterministic.
        AppAppearance.applyStored()
        // The system Close item claims ⌘W, which Quoin uses for Close Tab.
        // Retitle it to what it actually does and move it to ⇧⌘W. (SwiftUI
        // offers no handle on this item; menu surgery after the menu bar
        // is built is the supported-by-precedent workaround.)
        DispatchQueue.main.async { Self.retitleSystemCloseItem() }
    }

    private static func retitleSystemCloseItem() {
        guard let fileMenu = NSApp.mainMenu?.items
            .first(where: { $0.submenu?.items.contains { $0.action == #selector(NSWindow.performClose(_:)) } ?? false })?
            .submenu,
            let close = fileMenu.items.first(where: { $0.action == #selector(NSWindow.performClose(_:)) })
        else { return }
        close.title = "Close Window"
        close.keyEquivalent = "w"
        close.keyEquivalentModifierMask = [.command, .shift]
    }

    /// A `quoin://` deep link waiting to be resolved by a window that holds
    /// security scope on a library root containing its target (#31). Set on the
    /// main actor from `application(_:open:)`, drained by MainWindow. `nil`
    /// between deliveries.
    static var pendingDeepLink: QuoinURLScheme.DeepLink?

    /// A Services selection waiting to become a document (#35). Set on the main
    /// actor from `newDocumentWithSelection(_:userData:error:)`, drained by
    /// MainWindow (either its notification observer, warm, or its `onAppear`,
    /// cold). `nil` between deliveries.
    static var pendingSelectionSeed: NewDocumentSeed.Seed?

    /// Services provider (#35): "New Quoin Document with Selection". macOS calls
    /// this — the selector is the Info.plist `NSMessage` — with the sending
    /// app's selection on `pboard`. We stash a `NewDocumentSeed` and hand off to
    /// the key window (which owns the library + its security scope) via the same
    /// activate-then-post handshake a `quoin://` deep link uses; the window
    /// creates the file in the library, or falls back to a save panel when no
    /// library is configured. Thin by design: all naming/content logic lives in
    /// the unit-tested `NewDocumentSeed` seam.
    @objc func newDocumentWithSelection(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error?.pointee = "No text was available to make a document from." as NSString
            return
        }
        Self.pendingSelectionSeed = NewDocumentSeed.make(fromSelection: text)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: Self.newDocumentWithSelectionNotification, object: nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            // quoin:// deep links (#31) resolve against the library root, not
            // the raw path — route them separately from plain file opens.
            if QuoinURLScheme.isDeepLink(url) {
                guard let link = QuoinURLScheme.parse(url) else {
                    // A malformed deep link is refused, not guessed at.
                    NSSound.beep()
                    continue
                }
                Self.pendingDeepLink = link
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: Self.openDeepLinkNotification, object: nil)
                continue
            }
            // Plain file:// open (Finder double-click / Open With). The slot +
            // notification survive a cold launch where no window observer exists
            // yet; a running app's key window drains it immediately.
            NSApp.activate(ignoringOtherApps: true)
            Self.requestOpen(url)
        }
    }

    /// Handoff / current-activity resume (#36). Another device (or this Mac's
    /// Handoff banner, or a Siri/Spotlight suggestion of the open document)
    /// hands back an `NSUserActivity` whose `userInfo` carries a `quoin://` deep
    /// link. Route it through the SAME `pendingDeepLink` slot that
    /// `application(_:open:)` uses, so the key window resolves it against its own
    /// library root and the sandbox boundary is enforced there. A payload that
    /// is the wrong type, missing, or not a valid `quoin://` link is refused
    /// (return `false`) rather than guessed at.
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        #if canImport(CoreSpotlight)
        // A Spotlight result was tapped (#6). The activity type is the system's
        // CSSearchableItemActionType and carries the tapped item's identifier
        // (our stable, root-scoped ABSOLUTE path) under
        // CSSearchableItemActivityIdentifier. Route it through the SAME
        // pendingDeepLink slot and confinement as application(_:open:) — the
        // owning window resolves the absolute path against its own library root
        // (QuoinURLScheme), so a Spotlight tap can no more escape the sandbox
        // than an external quoin:// link can, and it opens the document the
        // result described rather than a same-named file in another library.
        if userActivity.activityType == CSSearchableItemActionType,
           let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
           let link = QuoinURLScheme.spotlightDeepLink(identifier: identifier) {
            // The identifier is the document's root-scoped absolute path, so the
            // link is `confinedToContainingRoot`: only the window whose library
            // owns that path honors it, never a same-named file in another
            // library (see consumePendingDeepLink).
            Self.pendingDeepLink = link
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: Self.openDeepLinkNotification, object: nil)
            return true
        }
        #endif
        guard userActivity.activityType == QuoinURLScheme.editingActivityType,
              let raw = userActivity.userInfo?[QuoinURLScheme.activityDeepLinkKey] as? String,
              let url = URL(string: raw),
              let link = QuoinURLScheme.parse(url) else {
            return false
        }
        Self.pendingDeepLink = link
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: Self.openDeepLinkNotification, object: nil)
        return true
    }

    /// Dock menu: the recent documents, one click from anywhere (UI #24).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let paths = RecentDocuments.present(
            in: UserDefaults.standard.stringArray(forKey: RecentDocuments.defaultsKey) ?? [],
            limit: 5,
            exists: { FileManager.default.fileExists(atPath: $0) }
        )
        guard !paths.isEmpty else { return nil }
        let menu = NSMenu()
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let item = NSMenuItem(
                title: url.deletingPathExtension().lastPathComponent,
                action: #selector(openRecentFromDock(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openRecentFromDock(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSApp.activate(ignoringOtherApps: true)
        // The URL rides the pending-open slot, so it survives even if no window
        // is key yet (app was fully in the background); the first window to
        // become key or appear drains it — no fixed-delay guess needed.
        Self.requestOpen(url)
    }
}

extension UTType {
    static let markdownDocument = UTType(importedAs: "net.daringfireball.markdown")
}
