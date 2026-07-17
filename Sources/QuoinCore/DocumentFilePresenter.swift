import Foundation

/// A thread-safe, `Sendable` holder for the session's registered file
/// presenter (#32). It exists so `DocumentSession`'s nonisolated deinit can
/// deregister the presenter: `NSFileCoordinator` retains a registered
/// presenter strongly, so the presenter's own deinit is not a reliable
/// backstop; the session must call `removeFilePresenter` on teardown, and a
/// nonisolated deinit may only touch `Sendable` state. On Linux it is an inert
/// empty box (no `NSFilePresenter` exists there).
final class FilePresenterHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var presenter: AnyObject?

    /// The currently registered presenter, or nil. Typed `AnyObject?` so this
    /// compiles on Linux; callers downcast to `NSFilePresenter` on Darwin.
    var current: AnyObject? {
        lock.lock()
        defer { lock.unlock() }
        return presenter
    }

    func set(_ newPresenter: AnyObject?) {
        lock.lock()
        presenter = newPresenter
        lock.unlock()
    }

    /// Deregisters the held presenter from `NSFileCoordinator` and clears it.
    /// Idempotent and safe to call from any thread (including a deinit).
    func removeAndClear() {
        lock.lock()
        let held = presenter
        presenter = nil
        lock.unlock()
        #if canImport(Darwin)
        if let held = held as? NSFilePresenter {
            NSFileCoordinator.removeFilePresenter(held)
        }
        #endif
    }
}

#if canImport(Darwin)

/// Formal `NSFilePresenter` adoption (#32) for the one open document.
///
/// Registering the app as a presenter makes it a first-class participant in
/// file coordination: the iCloud / Dropbox / Drive sync daemon and any other
/// coordinating writer now coordinate *around* our accesses — relinquish /
/// reacquire, deletion accommodation — and announce their writes through the
/// coordinated channel instead of racing us.
///
/// It **complements**, it does not replace, `FileWatcher`. The kqueue watcher
/// stays the reliable detector for *uncoordinated* writers — a plain `vim` /
/// `sed` save that never touches `NSFileCoordinator`, which a presenter is not
/// guaranteed to hear. Both channels funnel into the same idempotent
/// `DocumentSession.reloadFromDisk()`, whose source-hash guard collapses a
/// duplicate signal into a no-op, so the two never double-apply one change.
///
/// Callbacks arrive on `presentedItemOperationQueue`, OFF the session actor.
/// Each hops onto the actor with a non-blocking `Task { await … }` so the
/// operation queue never stalls and can always service coordination messages —
/// a blocked presenter queue is the classic file-coordination deadlock.
///
/// Self-write recognition is unaffected: session-initiated reads and writes
/// pass THIS presenter to their `NSFileCoordinator`, which by contract never
/// echoes those operations back to it — and the belt-and-suspenders
/// `selfWriteHash` still absorbs the kqueue echo of our own save.
final class DocumentFilePresenter: NSObject, NSFilePresenter {

    /// Weak so the presenter never keeps the session (and its document) alive;
    /// the session owns the presenter and deregisters it on close / deinit.
    private weak var session: DocumentSession?

    private let queue: OperationQueue

    /// `presentedItemURL` is read by the coordination machinery on arbitrary
    /// threads, so the backing URL is lock-guarded.
    private let lock = NSLock()
    private var _url: URL

    init(session: DocumentSession, url: URL) {
        self.session = session
        self._url = url
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1   // serial: observe changes in order
        q.name = "quoin.filepresenter"
        self.queue = q
        super.init()
    }

    /// Backstop deregistration: the session unregisters explicitly on close
    /// (`stopWatching`), but if the session is torn down without that — its
    /// only strong reference dropped — this fires and cleans up the
    /// coordinator's registry so nothing leaks or keeps receiving callbacks.
    /// `removeFilePresenter` is idempotent, so a double call is harmless.
    deinit {
        NSFileCoordinator.removeFilePresenter(self)
    }

    var presentedItemURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return _url
    }

    var presentedItemOperationQueue: OperationQueue { queue }

    /// A coordinated writer changed the file's contents.
    func presentedItemDidChange() {
        let session = self.session
        Task { await session?.presenterDidObserveChange() }
    }

    /// The file was moved / renamed through coordination.
    func presentedItemDidMove(to newURL: URL) {
        lock.lock()
        _url = newURL
        lock.unlock()
        let session = self.session
        Task { await session?.presenterDidObserveMove(to: newURL) }
    }

    /// The file is about to be deleted through coordination. We hold no
    /// exclusive claim, so we permit it immediately (`completionHandler(nil)`)
    /// and let the session's vanish path — shared with the watcher — detach.
    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        let session = self.session
        Task { await session?.presenterDidObserveDeletion() }
        completionHandler(nil)
    }
}
#endif
