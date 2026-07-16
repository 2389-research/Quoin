import Foundation

/// Watches a single file for external changes, including the atomic-save
/// pattern most editors use (write temp file, rename over the original,
/// which replaces the inode). On delete/rename the watcher re-opens the
/// path and keeps going.
///
/// A TRUE rename/move (the watched inode survives at a new path) is
/// followed: the open descriptor's current path is read back with
/// `F_GETPATH`, watching re-arms there, and `onRelocate` reports the new
/// URL — so the session tracks the file instead of polling the dead path
/// forever while autosave resurrects the old filename (launch ledger,
/// data integrity #6).
///
/// Events are debounced (~50 ms) and coalesced before `onChange` fires.
public final class FileWatcher: @unchecked Sendable {

    private var url: URL
    private let queue = DispatchQueue(label: "quoin.filewatcher")
    private let onChange: @Sendable () -> Void
    private let onRelocate: (@Sendable (URL) -> Void)?
    private var isCancelled = false

    #if canImport(Darwin)
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var pendingFire: DispatchWorkItem?
    #endif

    public init(
        url: URL,
        onChange: @escaping @Sendable () -> Void,
        onRelocate: (@Sendable (URL) -> Void)? = nil
    ) {
        self.url = url
        self.onChange = onChange
        self.onRelocate = onRelocate
    }

    deinit {
        #if canImport(Darwin)
        // Direct teardown, NOT `cancel()`. `cancel()` bounces through
        // `queue.async { [weak self] … }`, but by the time that block runs
        // during deallocation `self` is already nil, so the guard returns
        // early, the source is never cancelled, and its cancel handler's
        // `close(fd)` never fires — repeated opens leak descriptors and can
        // exhaust the process's fd table (QoL #34). The dispatch source's
        // cancel is thread-safe and owns the close(); no event handler can be
        // executing, since they capture `[weak self]` and could not have kept
        // us alive to this point.
        isCancelled = true
        if let source {
            source.cancel()               // cancel handler closes the fd
        } else if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
        #endif
    }

    public func start() {
        #if canImport(Darwin)
        queue.async { [weak self] in self?.openAndWatch() }
        #endif
    }

    public func cancel() {
        #if canImport(Darwin)
        queue.async { [weak self] in
            guard let self else { return }
            self.isCancelled = true
            self.tearDown()
        }
        #endif
    }

    #if canImport(Darwin)
    private func openAndWatch() {
        guard !isCancelled else { return }
        tearDown()

        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            // The file may be mid-replace; retry shortly.
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.openAndWatch() }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                // A rename where OUR inode is still live at a new path is a
                // real move — follow it. An atomic replace-over unlinks the
                // watched inode instead, so `F_GETPATH` yields the original
                // path (or fails) and we fall through to re-opening it.
                if events.contains(.rename),
                   let newURL = self.currentPathOfWatchedFile(),
                   // F_GETPATH returns a symlink-resolved path (/private/var/…)
                   // while the caller's URL may not be; compare resolved forms
                   // so an unchanged location is never mistaken for a move.
                   newURL.resolvingSymlinksInPath().path
                       != self.url.resolvingSymlinksInPath().path {
                    self.url = newURL
                    self.openAndWatch()
                    self.onRelocate?(newURL)
                    return
                }
                // Atomic save: the inode is gone. Re-open the path, then
                // report the change once the new file is watchable.
                self.openAndWatch()
                self.scheduleFire()
            } else {
                self.scheduleFire()
            }
        }
        source.setCancelHandler { [fileDescriptor] in
            if fileDescriptor >= 0 { close(fileDescriptor) }
        }
        self.source = source
        source.resume()
    }

    /// The path the watched (still-open) file descriptor currently resolves
    /// to, or nil when the inode is unlinked/unreachable.
    private func currentPathOfWatchedFile() -> URL? {
        guard fileDescriptor >= 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(fileDescriptor, F_GETPATH, &buffer) == 0 else { return nil }
        let path = String(cString: buffer)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func scheduleFire() {
        pendingFire?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.onChange()
        }
        pendingFire = work
        queue.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func tearDown() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }
    #endif
}
