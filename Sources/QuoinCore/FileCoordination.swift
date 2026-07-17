import Foundation

/// Coordinated file access (#32): wraps document reads and writes in
/// `NSFileCoordinator` so a library synced through iCloud / Dropbox / Drive
/// doesn't race the sync daemon. Uncoordinated writes racing the daemon spawn
/// "conflicted copy" files; a coordinated write serializes against the
/// daemon's own accesses. A coordinated *read* additionally pulls down an
/// undownloaded iCloud placeholder (`.icloud`) before the accessor runs, so a
/// not-yet-synced file opens instead of failing as "unreadable".
///
/// On platforms without a sync daemon (Linux corelibs-foundation) coordination
/// is meaningless, so this degrades to a direct accessor call — same bytes.
enum FileCoordination {

    /// Coordinated read of `url`'s contents.
    ///
    /// `filePresenter` (the session's own `NSFilePresenter`, when registered)
    /// is passed through so the coordinator excludes it — a coordinator never
    /// messages the presenter it was initialized with, so our own reads don't
    /// churn our own presenter callbacks. Typed `AnyObject?` to keep this one
    /// signature Linux-buildable (`NSFilePresenter` is Darwin-only); it is
    /// downcast inside the Darwin branch and ignored elsewhere.
    static func read(_ url: URL, filePresenter: AnyObject? = nil) throws -> Data {
        #if canImport(Darwin)
        var coordinatorError: NSError?
        var accessorResult: Result<Data, Error>?
        let coordinator = NSFileCoordinator(filePresenter: filePresenter as? NSFilePresenter)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { actualURL in
            accessorResult = Result { try Data(contentsOf: actualURL) }
        }
        if let coordinatorError { throw coordinatorError }
        guard let accessorResult else { throw CocoaError(.fileReadUnknown) }
        return try accessorResult.get()
        #else
        return try Data(contentsOf: url)
        #endif
    }

    /// Coordinated atomic write of `data` to `url`.
    ///
    /// `filePresenter` is excluded from coordination the same way as in
    /// `read` — our own coordinated write never echoes back to our own
    /// presenter's `presentedItemDidChange`. (The kqueue `FileWatcher` still
    /// sees the write; that echo is absorbed by `selfWriteHash`.)
    static func writeAtomic(_ data: Data, to url: URL, filePresenter: AnyObject? = nil) throws {
        #if canImport(Darwin)
        var coordinatorError: NSError?
        var accessorError: Error?
        let coordinator = NSFileCoordinator(filePresenter: filePresenter as? NSFilePresenter)
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { actualURL in
            do { try data.write(to: actualURL, options: .atomic) }
            catch { accessorError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let accessorError { throw accessorError }
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
