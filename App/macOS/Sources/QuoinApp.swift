import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
            // Format menu: the whole formatting grammar lives in the menu
            // bar (discoverable), not only behind invisible shortcuts.
            FormatCommands()
            ViewCommands()
            GoCommands()
            ExportCommands()
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

extension FocusedValues {
    var quoinIsEditingBlock: Bool? {
        get { self[QuoinIsEditingBlockKey.self] }
        set { self[QuoinIsEditingBlockKey.self] = newValue }
    }
    var quoinHasDocument: Bool? {
        get { self[QuoinHasDocumentKey.self] }
        set { self[QuoinHasDocumentKey.self] = newValue }
    }
}

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
                let recents = (UserDefaults.standard.stringArray(forKey: "QuoinRecentDocuments") ?? [])
                    .prefix(10)
                    .map { URL(fileURLWithPath: $0) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                ForEach(recents, id: \.path) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        post(AppDelegate.openDocumentNotification, userInfo: ["url": url])
                    }
                }
                if !recents.isEmpty {
                    Divider()
                    Button("Clear Menu") {
                        UserDefaults.standard.removeObject(forKey: "QuoinRecentDocuments")
                        NSDocumentController.shared.clearRecentDocuments(nil)
                    }
                }
            }
            Divider()
            Button("Close Tab") { post(AppDelegate.closeTabNotification) }
                .keyboardShortcut("w", modifiers: .command)
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

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { post(AppDelegate.undoNotification) }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(hasDocument != true)
            Button("Redo") { post(AppDelegate.redoNotification) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(hasDocument != true)
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
/// checkmarked toggles (they're global @AppStorage preferences, so the
/// menu binds the same keys the windows read — state can't lie).
private struct ViewCommands: Commands {
    @AppStorage("QuoinFocusMode") private var isFocusMode = false
    @AppStorage("QuoinTypewriter") private var isTypewriter = false
    @AppStorage("QuoinFocusSentence") private var isSentenceFocus = false
    @AppStorage("QuoinShowStatusBar") private var showStatusBar = true

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
            Toggle("Focus Mode", isOn: $isFocusMode)
            Toggle("Sentence Focus", isOn: $isSentenceFocus)
                .disabled(!isFocusMode)
            Toggle("Typewriter Scrolling", isOn: $isTypewriter)
                .keyboardShortcut("t", modifiers: [.command, .option])
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

/// File ▸ Export…/Print… — enabled only with a document to act on.
private struct ExportCommands: Commands {
    @FocusedValue(\.quoinHasDocument) private var hasDocument

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export…") { post(AppDelegate.exportNotification) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
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

/// Handles Finder "Open With Quoin" for individual files.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let openDocumentNotification = Notification.Name("quoin.openDocument")
    static let toggleSidebarNotification = Notification.Name("quoin.toggleSidebar")
    static let toggleOutlineNotification = Notification.Name("quoin.toggleOutline")
    static let toggleEditSourceNotification = Notification.Name("quoin.toggleEditSource")
    static let moveBlockNotification = Notification.Name("quoin.moveBlock")
    static let openGuideNotification = Notification.Name("quoin.openGuide")
    static let openWelcomeNotification = Notification.Name("quoin.openWelcome")
    static let formatNotification = Notification.Name("quoin.format")
    static let undoNotification = Notification.Name("quoin.undo")
    static let redoNotification = Notification.Name("quoin.redo")
    static let exportNotification = Notification.Name("quoin.export")
    static let printNotification = Notification.Name("quoin.print")
    static let newDocumentNotification = Notification.Name("quoin.newDocument")
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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let sessions = ReaderModel.liveSessionSnapshot()
        guard !sessions.isEmpty else { return .terminateNow }
        Task.detached(priority: .userInitiated) {
            for session in sessions {
                try? await session.saveNow()
            }
            DispatchQueue.main.async {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        // Watchdog: never let a hung save wedge quit for more than 3s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            sender.reply(toApplicationShouldTerminate: true)
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

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(
                name: Self.openDocumentNotification,
                object: nil,
                userInfo: ["url": url]
            )
        }
    }

    /// Dock menu: the recent documents, one click from anywhere (UI #24).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let paths = (UserDefaults.standard.stringArray(forKey: "QuoinRecentDocuments") ?? []).prefix(5)
        guard !paths.isEmpty else { return nil }
        let menu = NSMenu()
        for path in paths where FileManager.default.fileExists(atPath: path) {
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
        // Let a window become key before the (key-window-gated) open fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NotificationCenter.default.post(
                name: Self.openDocumentNotification, object: nil, userInfo: ["url": url])
        }
    }
}

extension UTType {
    static let markdownDocument = UTType(importedAs: "net.daringfireball.markdown")
}
