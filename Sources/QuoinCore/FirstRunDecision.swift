/// Whether a window with nothing in it should materialize an untitled document.
/// The first window someone sees must be a DOCUMENT, not a filing decision
/// (docs/design/principles.md) — but only when no other entry path claimed it.
public enum FirstRunDecision {
    public static func shouldCreateUntitled(
        hasOpenTabs: Bool, hasLibrary: Bool, hasPendingOpens: Bool,
        isLaunchRestoration: Bool, reopenedScratchCount: Int
    ) -> Bool {
        if hasOpenTabs || hasPendingOpens { return false }
        if isLaunchRestoration && reopenedScratchCount > 0 { return false }
        return true
    }
}
