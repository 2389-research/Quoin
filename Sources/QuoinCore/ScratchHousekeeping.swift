/// Keeps auto-created untitled documents from becoming litter.
public enum ScratchHousekeeping {
    /// A window whose ONLY tab is an untouched untitled document has nothing
    /// worth restoring — persisting it would reopen a blank note forever.
    public static func shouldPersistSession(
        tabCount: Int, onlyTabIsEmptyScratch: Bool
    ) -> Bool {
        !(tabCount == 1 && onlyTabIsEmptyScratch)
    }
}
