import Foundation

/// The per-window session that survives quit / relaunch / crash (#15): which
/// documents are open as tabs, which is active, the panel chrome, and where the
/// active document was scrolled.
///
/// This is the platform-free, `Codable` heart of window restoration — the app
/// shell (`MainWindow`) only serializes it into `@SceneStorage` and re-hydrates
/// the tabs/panels from it. Keeping the model and its serialize/deserialize +
/// prune + dedupe rules here (with no filesystem or SwiftUI I/O) is what makes
/// them exhaustively unit-testable (`WindowSessionStateTests`), and it is the
/// deliberate alternative to migrating the shell to `DocumentGroup`/`NSDocument`
/// (that document-based rearchitecture — which also governs the future iOS
/// shell — is intentionally DEFERRED; see docs/reference/architecture.md).
///
/// The non-negotiable rule this type enforces: the persisted blob carries only
/// **library-root-relative** document handles (via
/// ``QuoinURLScheme/relativePath(forDocumentPath:relativeTo:)``) — NEVER an
/// absolute path and NEVER a raw security-scoped bookmark. The library bookmark
/// itself lives in the app's per-folder bookmark store, keyed by the window
/// root; restoration re-resolves each relative handle against that root through
/// the same lexical-confinement resolver a `quoin://` deep link uses, so a tab
/// can no more escape the sandbox on restore than a deep link can.
public struct WindowSessionState: Codable, Equatable, Sendable {

    /// Bump when the on-disk shape changes incompatibly. A blob whose version is
    /// NEWER than this build understands is refused on decode (a downgrade can't
    /// misread a future layout), rather than crashing or half-reading it.
    public static let currentVersion = 1

    /// One open document tab.
    public struct Tab: Codable, Equatable, Sendable {
        /// The document's path RELATIVE to the window's library root — the
        /// boundary-safe handle. Never absolute; never a bookmark.
        public var path: String
        /// The heading slug at the top of the viewport when the session was
        /// captured, or `nil` for none. A content-derived, cross-relaunch-stable
        /// handle (block IDs are ephemeral UUIDs) resolved back to a block on
        /// restore. Only meaningful for the active tab (the only one whose
        /// scroll is live), but stored per-tab so a future multi-tab scroll
        /// memory needs no format change.
        public var scrollAnchor: String?

        public init(path: String, scrollAnchor: String? = nil) {
            self.path = path
            self.scrollAnchor = scrollAnchor
        }
    }

    /// The trailing inspector's mode — mirrors `ReaderScreen.InspectorMode`.
    public enum InspectorMode: String, Codable, Sendable {
        case outline, review, properties
    }

    public var version: Int
    public var tabs: [Tab]
    /// Index into `tabs` of the active tab, or `nil` (restore falls back to the
    /// last surviving tab). Clamped/validated on restore.
    public var activeTabIndex: Int?
    public var sidebarVisible: Bool
    public var inspectorVisible: Bool
    public var inspectorMode: InspectorMode

    public init(
        version: Int = WindowSessionState.currentVersion,
        tabs: [Tab] = [],
        activeTabIndex: Int? = nil,
        sidebarVisible: Bool = true,
        inspectorVisible: Bool = true,
        inspectorMode: InspectorMode = .outline
    ) {
        self.version = version
        self.tabs = tabs
        self.activeTabIndex = activeTabIndex
        self.sidebarVisible = sidebarVisible
        self.inspectorVisible = inspectorVisible
        self.inspectorMode = inspectorMode
    }

    // MARK: - Capture (live window state → persistable blob)

    /// Build the session state from a window's live state. `openTabPaths` and
    /// `activeTabPath` are ABSOLUTE document paths; each is folded to a
    /// root-relative handle, and any tab NOT strictly inside `rootPath` is
    /// DROPPED — a one-off file opened via ⌘O from outside the library has no
    /// portable, sandbox-safe handle, so it is not persisted (this is also the
    /// guarantee that no absolute path can ever leak into the blob). With no
    /// root, no tabs are persistable and the returned state carries an empty
    /// tab list (the chrome flags still round-trip).
    ///
    /// `scrollAnchors` maps an absolute tab path to its top-of-viewport heading
    /// slug; a tab with no entry gets `nil`.
    public static func capture(
        rootPath: String?,
        openTabPaths: [String],
        activeTabPath: String?,
        scrollAnchors: [String: String] = [:],
        sidebarVisible: Bool,
        inspectorVisible: Bool,
        inspectorMode: InspectorMode
    ) -> WindowSessionState {
        var tabs: [Tab] = []
        var activeIndex: Int?
        if let rootPath, !rootPath.isEmpty {
            for absolute in openTabPaths {
                guard let relative = QuoinURLScheme.relativePath(
                    forDocumentPath: absolute, relativeTo: rootPath) else { continue }
                if activeTabPath == absolute { activeIndex = tabs.count }
                tabs.append(Tab(path: relative, scrollAnchor: scrollAnchors[absolute]))
            }
        }
        return WindowSessionState(
            tabs: tabs,
            activeTabIndex: activeIndex,
            sidebarVisible: sidebarVisible,
            inspectorVisible: inspectorVisible,
            inspectorMode: inspectorMode
        )
    }

    // MARK: - Serialize / deserialize

    /// A compact, deterministic JSON string for `@SceneStorage`. Sorted keys so
    /// an unchanged session serializes byte-identically (no spurious scene-state
    /// churn) and tests can assert on the text.
    public func serialized() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    /// Decode a serialized blob. Returns `nil` for empty/garbage input or a blob
    /// stamped with a version this build doesn't understand (forward-incompatible)
    /// — the caller treats `nil` as "no session to restore" and starts clean.
    public init?(serialized: String) {
        guard !serialized.isEmpty, let data = serialized.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(WindowSessionState.self, from: data),
              decoded.version <= WindowSessionState.currentVersion else { return nil }
        self = decoded
    }

    // MARK: - Restore (blob → live tabs, pruned)

    /// The absolute tab paths to reopen after re-resolving against a concrete
    /// library root, with the active one identified.
    public struct RestoredTabs: Equatable {
        /// Absolute paths, in tab order, that survived pruning.
        public let orderedPaths: [String]
        /// The active tab's absolute path, or `nil` when nothing survives.
        public let activePath: String?

        public init(orderedPaths: [String], activePath: String?) {
            self.orderedPaths = orderedPaths
            self.activePath = activePath
        }
    }

    /// Resolve each stored relative handle against `rootPath` back to an absolute
    /// path, dropping any tab that:
    ///   * resolves OUTSIDE the root (defensive — the handle is relative, but a
    ///     `..` that climbs out is refused by the same lexical resolver a deep
    ///     link uses),
    ///   * no longer `exists` (moved/renamed/deleted since the session was
    ///     saved), or
    ///   * duplicates an already-resolved tab (two handles that normalize to one
    ///     file collapse to a single tab — never two sessions over one file).
    ///
    /// The active tab follows its stored handle; if that tab was pruned, the
    /// active falls back to the last surviving tab (matching the shell's
    /// close-focuses-a-neighbor feel). `exists` is injected so pruning is tested
    /// off the filesystem.
    public func restoredTabs(rootPath: String, exists: (String) -> Bool) -> RestoredTabs {
        let activeRelative: String? = activeTabIndex.flatMap {
            tabs.indices.contains($0) ? tabs[$0].path : nil
        }
        var orderedPaths: [String] = []
        var seen = Set<String>()
        var activePath: String?
        for tab in tabs {
            guard let resolved = QuoinURLScheme.resolvedPath(
                forRawPath: tab.path, relativeTo: rootPath),
                exists(resolved),
                seen.insert(SessionRouting.canonicalKey(resolved)).inserted else { continue }
            orderedPaths.append(resolved)
            if activePath == nil, tab.path == activeRelative { activePath = resolved }
        }
        if activePath == nil { activePath = orderedPaths.last }
        return RestoredTabs(orderedPaths: orderedPaths, activePath: activePath)
    }
}

/// The "is this file already open — route to the existing session, or open a new
/// one?" decision (#15), pure and testable apart from the running app.
///
/// A file reached a second time (Finder double-click, a Spotlight tap, the same
/// path in two forms, a library click) must land on the EXISTING tab/window,
/// never spawn a second `DocumentSession` — two autosavers over one file is the
/// ledger-#12 corruption. The shell decides live identity with the filesystem
/// (`OpenDocumentStore.sameFile`, which resolves symlinks); this seam captures
/// the *lexical* half of that rule (`.`/`..` collapse + case folding on the
/// case-insensitive default volume) so the routing decision is unit-tested
/// without a disk.
public enum SessionRouting {

    /// Where an open should go.
    public enum Decision: Equatable, Sendable {
        /// Focus the already-open tab at this index (in the given order).
        case focusExisting(index: Int)
        /// Nothing matches — open a new tab/session.
        case openNew
    }

    /// Decide where opening `path` should route, given the currently-open
    /// document paths in tab order. Identity is lexical: paths are normalized
    /// (`.`/`..` collapsed) and, by default, case-folded — the macOS default
    /// volume (APFS) is case-INSENSITIVE, so `Todo.md` and `todo.md` are ONE
    /// file and must route to one tab. Pass `caseSensitive: true` for a
    /// case-sensitive volume, where the two ARE distinct.
    public static func decide(
        opening path: String, amongOpen openPaths: [String], caseSensitive: Bool = false
    ) -> Decision {
        let target = canonicalKey(path, caseSensitive: caseSensitive)
        for (index, open) in openPaths.enumerated()
        where canonicalKey(open, caseSensitive: caseSensitive) == target {
            return .focusExisting(index: index)
        }
        return .openNew
    }

    /// The lexical identity key for a path: normalized, and (by default) lowercased.
    public static func canonicalKey(_ path: String, caseSensitive: Bool = false) -> String {
        let normalized = QuoinURLScheme.normalize(path)
        return caseSensitive ? normalized : normalized.lowercased()
    }
}
