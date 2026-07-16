import Foundation

/// App-global registry mapping a document's on-disk identity to the single
/// `ReaderModel` — and thus the single `DocumentSession` — that edits it.
///
/// Launch-ledger #12: a file opened in two windows (or reached through two URL
/// forms) used to spawn two `DocumentSession`s — two autosavers ping-ponging
/// bytes over each other, silent corruption. Keying by the file's RESOLVED,
/// standardized URL (symlinks and `/private` prefixes collapsed, trailing
/// slashes normalized) and ref-counting across every open tab in every window
/// guarantees exactly one live session per file. The last tab to let go of a
/// file stops its model (final flush + unwatch) and drops it.
///
/// It also underpins ledger #22: because the model outlives the transient
/// `ReaderScreen`, switching tabs no longer tears the session down — re-entry
/// re-projects from the cached model instead of re-reading from disk, so undo
/// history survives.
@MainActor
final class OpenDocumentStore {
    static let shared = OpenDocumentStore()

    private final class Entry {
        let model: ReaderModel
        var refs: Int
        init(model: ReaderModel) {
            self.model = model
            self.refs = 1
        }
    }

    /// Keyed by the normalized identity URL, never the raw one.
    private var entries: [URL: Entry] = [:]

    /// The identity key: two path forms of the same file (a symlink, a `/var`
    /// vs `/private/var` prefix, a trailing slash) must collapse to one key so
    /// they can never open as two sessions.
    static func key(for url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Whether two URLs name the same file on disk.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        key(for: a) == key(for: b)
    }

    /// The model currently backing `url`, if a tab holds it open.
    func model(for url: URL) -> ReaderModel? {
        entries[Self.key(for: url)]?.model
    }

    /// Take a reference to `url`'s model, creating and starting it on the first
    /// reference (from any window). Every call must be balanced with
    /// `release(_:)` when the holding tab closes.
    @discardableResult
    func acquire(_ url: URL) -> ReaderModel {
        let key = Self.key(for: url)
        if let entry = entries[key] {
            entry.refs += 1
            return entry.model
        }
        let model = ReaderModel()
        model.onFileRenamed = { [weak self] newURL in
            self?.rekey(from: url, to: newURL)
        }
        model.start(fileURL: url, initialText: "")
        entries[key] = Entry(model: model)
        return model
    }

    /// Drop a reference; the last release stops the model (flush + unwatch) and
    /// forgets it. A no-op when the file isn't held (defensive against a double
    /// release racing a rename).
    func release(_ url: URL) {
        let key = Self.key(for: url)
        guard let entry = entries[key] else { return }
        entry.refs -= 1
        if entry.refs <= 0 {
            entry.model.stop()
            entries[key] = nil
        }
    }

    /// A first-H1 rename moved the file on disk: move the entry to its new
    /// identity key and broadcast so every window updates the tab's URL. The
    /// model's `fileURL` (and its session) already relocated before this fires.
    func rekey(from old: URL, to new: URL) {
        let oldKey = Self.key(for: old)
        let newKey = Self.key(for: new)
        guard oldKey != newKey, let entry = entries[oldKey] else { return }
        entries[oldKey] = nil
        // Re-point the rename handler at the NEW identity for the next rename.
        entry.model.onFileRenamed = { [weak self] next in
            self?.rekey(from: new, to: next)
        }
        entries[newKey] = entry
        NotificationCenter.default.post(
            name: Self.documentRenamedNotification,
            object: nil,
            userInfo: ["old": old, "new": new]
        )
    }

    /// Posted after a document renames itself on disk (first-H1 rename). Windows
    /// observe it to re-point any tab pointing at `old` to `new`.
    static let documentRenamedNotification = Notification.Name("OpenDocumentStore.documentRenamed")
}
