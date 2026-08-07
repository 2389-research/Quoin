/// Keeps auto-created untitled documents from becoming litter.
public enum ScratchHousekeeping {
    /// A window whose ONLY tab is an untouched untitled document has nothing
    /// worth restoring — persisting it would reopen a blank note forever.
    public static func shouldPersistSession(
        tabCount: Int, onlyTabIsEmptyScratch: Bool
    ) -> Bool {
        !(tabCount == 1 && onlyTabIsEmptyScratch)
    }

    /// Whether an untitled scratch file has nothing worth keeping and may be
    /// discarded: its `contents` are empty after trimming whitespace/newlines.
    ///
    /// Read-failure safety is the whole point of the `?? false`: `contents` is
    /// `nil` when the file could not be read as UTF-8 (invalid bytes, a
    /// transient I/O error at launch), and an UNREADABLE file must be KEPT — a
    /// real document that momentarily fails to read must NEVER be purged. This
    /// is the single source of truth for the emptiness predicate the on-close
    /// GC and the launch-time purge share (deferred-commitment safety net).
    public static func isDiscardableEmptyScratch(contents: String?) -> Bool {
        contents?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false
    }
}
