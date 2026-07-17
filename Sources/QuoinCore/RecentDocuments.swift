import Foundation

/// The recent-documents list model (#16): a most-recently-used list of
/// document paths that backs the File ▸ Open Recent menu, the dock-recents
/// menu, and quick open's empty-query list.
///
/// Platform-free and no-I/O so the ordering, de-duplication, and cap rules are
/// unit-testable without a filesystem or an app target — the shell only
/// persists the returned array (`UserDefaults`) and maps paths to `URL`s. Every
/// open — Finder "Open With", File ▸ Open…, sidebar click, deep link, Open
/// Recent itself — routes through the same `recording` call, so both
/// Finder-opened and library-opened documents appear here and reopen through
/// the one open path.
public enum RecentDocuments {

    /// The `UserDefaults` key the persisted list lives under. Centralized here
    /// so every reader/writer (LibraryModel, the Open Recent menu, the dock
    /// menu) shares one string instead of re-spelling it.
    public static let defaultsKey = "QuoinRecentDocuments"

    /// How many entries are persisted. Menus show fewer (they pass their own
    /// smaller `limit` to ``present(in:limit:exists:)``).
    public static let storageLimit = 20

    /// Most-recently-used update: move `path` to the front of `list`,
    /// de-duplicated (so a reopen promotes rather than duplicates), capped at
    /// `limit`. Pure — the caller persists the result.
    public static func recording(
        _ path: String, into list: [String], limit: Int = storageLimit
    ) -> [String] {
        var paths = list
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        return Array(paths.prefix(limit))
    }

    /// The presentable subset of `list`: entries whose files still exist, in
    /// order, de-duplicated defensively, capped at `limit`. `exists` is
    /// injected (rather than calling `FileManager` directly) so the pruning is
    /// testable off disk — a stale entry (file deleted/moved) never shows in a
    /// menu, and never reopens to a dead path.
    public static func present(
        in list: [String], limit: Int = storageLimit, exists: (String) -> Bool
    ) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in list where exists(path) && seen.insert(path).inserted {
            out.append(path)
            if out.count == limit { break }
        }
        return out
    }
}
