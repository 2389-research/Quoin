import Foundation

/// Files waiting to be opened, batched. N files dropped on the Dock icon must
/// become N tabs in ONE window, so the slot accumulates and exactly one drainer
/// takes the whole batch (issue #41). `hasPending` peeks WITHOUT consuming —
/// the first-run guard needs to know a Finder open is inbound before deciding
/// whether to create an untitled document.
public struct PendingOpenSlot {
    private var urls: [URL] = []

    public init() {}

    public var hasPending: Bool { !urls.isEmpty }

    public mutating func enqueue(_ url: URL) { urls.append(url) }

    /// Takes the whole batch atomically; a second drainer sees nothing.
    public mutating func drain() -> [URL] {
        defer { urls.removeAll() }
        return urls
    }
}
