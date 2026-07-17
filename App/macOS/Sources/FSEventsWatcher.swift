import Foundation
import CoreServices

/// Recursive directory watching via FSEvents — keeps the library sidebar
/// live when files change outside the app (Finder, other editors, sync).
/// Events are debounced through FSEvents' own latency parameter.
///
/// The FSEvents stream calls back on a context Swift treats as nonisolated, so
/// `onChange` is `@Sendable` — the caller (`LibraryModel`) supplies a closure
/// that hops to the main actor via `MainActor.assumeIsolated`. The watcher
/// object itself is only ever held as a property of the main-actor
/// `LibraryModel` and never sent across an isolation boundary, so it needs no
/// `Sendable` conformance (unlike QuoinCore's `FileWatcher`, which is passed
/// into a `DocumentSession` actor).
final class FSEventsWatcher {

    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void

    init(url: URL, latency: TimeInterval = 0.5, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        )

        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
