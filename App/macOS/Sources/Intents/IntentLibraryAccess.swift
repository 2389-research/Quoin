#if canImport(AppIntents)
import AppKit
import Foundation
import QuoinCore

/// Bridges the App Intents surface to the local library WITHOUT depending on a
/// window's `LibraryModel`. An intent can run while Quoin is in the background
/// or not running at all, so this resolves the most-recent library's
/// *app-scoped security bookmark* — the SAME `UserDefaults` key `LibraryModel`
/// persists — starts access for the duration of one intent, and discovers
/// documents with `Library.scan` (the shared index, never a second discovery
/// path).
///
/// Every mutating operation funnels through `DocumentSession` (atomic,
/// file-coordinated writes), so an intent obeys the same source-of-truth and
/// byte-losslessness invariants as a keystroke. There is no raw
/// `FileManager` write here.
@MainActor
enum IntentLibraryAccess {

    /// Where `LibraryModel.saveBookmarks` stores the most-recent library's
    /// security-scoped bookmark. Kept in sync by string identity — one owner
    /// (LibraryModel) writes it; this only reads it.
    private static let bookmarkKey = "quoin.library.bookmark"

    /// A live, security-scoped handle on the library root for the lifetime of
    /// one intent. `release()` MUST be called (via `defer`) to balance the
    /// `startAccessingSecurityScopedResource` — the security scope is
    /// process-wide, so it survives the `await` hops inside `perform`.
    struct Handle {
        let root: URL
        private let stop: () -> Void

        init(root: URL, stop: @escaping () -> Void) {
            self.root = root
            self.stop = stop
        }

        func release() { stop() }
    }

    /// Resolve the library root and begin security-scoped access, or throw a
    /// user-facing error. The caller owns the returned handle and must
    /// `release()` it.
    static func open() throws -> Handle {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            throw QuoinIntentError.noLibrary
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            throw QuoinIntentError.libraryUnavailable
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw QuoinIntentError.libraryUnavailable
        }
        let accessing = url.startAccessingSecurityScopedResource()
        return Handle(root: url) {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// Scan the tree for a handle — the shared `Library.scan` index.
    static func scan(_ handle: Handle) -> LibraryNode {
        Library.scan(root: handle.root)
    }

    /// Resolve document refs by their relative-path identity within the
    /// currently-configured library.
    static func documents(withRelativePaths ids: [String]) -> [LibraryQuery.DocumentRef] {
        guard let handle = try? open() else { return [] }
        defer { handle.release() }
        return LibraryQuery.documents(
            withRelativePaths: ids,
            in: scan(handle),
            rootPath: handle.root.standardizedFileURL.path)
    }

    /// Rank documents matching a free-text query (title / filename / relative
    /// path) — powers entity string-search and disambiguation.
    static func rankedDocuments(matching query: String, limit: Int = 25) -> [LibraryQuery.DocumentRef] {
        guard let handle = try? open() else { return [] }
        defer { handle.release() }
        return LibraryQuery.rank(
            query: query,
            in: scan(handle),
            rootPath: handle.root.standardizedFileURL.path,
            limit: limit)
    }

    /// Suggested documents for pickers: the whole library, capped.
    static func suggestedDocuments(limit: Int = 50) -> [LibraryQuery.DocumentRef] {
        guard let handle = try? open() else { return [] }
        defer { handle.release() }
        return Array(LibraryQuery.documents(
            in: scan(handle),
            rootPath: handle.root.standardizedFileURL.path).prefix(limit))
    }

    // MARK: - Mutations (all through DocumentSession — atomic, coordinated)

    /// Create a note named `title` (sanitized to a safe, collision-free
    /// filename) seeded with `body`, written atomically through a
    /// `DocumentSession`. Returns the resolved ref for the created file.
    static func createNote(title: String, body: String) async throws -> LibraryQuery.DocumentRef {
        let handle = try open()
        defer { handle.release() }
        let base = FilenamePolicy.sanitize(title)
        let url = Library.uniqueURL(baseName: base, extension: "md", in: handle.root)
        // A fresh file: seed with the body, giving it a single trailing newline
        // (the POSIX text convention) when non-empty. Byte-losslessness doesn't
        // bind for a brand-new file.
        let content: String
        if body.isEmpty {
            content = ""
        } else {
            let normalized = body
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            content = normalized.hasSuffix("\n") ? normalized : normalized + "\n"
        }
        let session = DocumentSession(source: content, fileURL: url)
        do {
            try await session.saveNow()
        } catch {
            throw QuoinIntentError.createFailed(url.lastPathComponent)
        }
        guard let relative = LibraryQuery.relativePath(
            forPath: url.standardizedFileURL.path,
            rootPath: handle.root.standardizedFileURL.path)
        else {
            throw QuoinIntentError.createFailed(url.lastPathComponent)
        }
        return LibraryQuery.DocumentRef(
            url: url,
            title: url.deletingPathExtension().lastPathComponent,
            relativePath: relative)
    }

    /// Append `text` to the note at `ref`, through a `DocumentSession` (the
    /// append edit is computed in-actor and applied via the same pipeline as a
    /// keystroke — undoable and byte-lossless), then flushed to disk. The
    /// library scope is held for the whole operation so the sandboxed read +
    /// atomic write are permitted. Throws when the file is gone, unreadable, or
    /// the text is empty.
    static func appendText(_ text: String, to ref: LibraryQuery.DocumentRef) async throws {
        let handle = try open()
        defer { handle.release() }
        guard FileManager.default.fileExists(atPath: ref.url.path) else {
            throw QuoinIntentError.documentNotFound(ref.title)
        }
        guard let session = try? DocumentSession.open(fileURL: ref.url) else {
            throw QuoinIntentError.unreadable(ref.title)
        }
        guard try await session.appendText(text) != nil else {
            throw QuoinIntentError.emptyAppendText
        }
        do {
            try await session.saveNow()
        } catch {
            throw QuoinIntentError.unreadable(ref.title)
        }
    }

    /// Read the parsed document at `ref` and run `body` on it WHILE the library
    /// scope is still held — export renderers (e.g. `HTMLExporter`, which
    /// inlines local images by reading them) need the sandbox access to stay
    /// open through the render, not just the read. Throws when the file is gone
    /// or unreadable.
    static func withDocument<T>(
        at ref: LibraryQuery.DocumentRef, _ body: (QuoinDocument) -> T
    ) async throws -> T {
        let handle = try open()
        defer { handle.release() }
        guard FileManager.default.fileExists(atPath: ref.url.path) else {
            throw QuoinIntentError.documentNotFound(ref.title)
        }
        guard let session = try? DocumentSession.open(fileURL: ref.url) else {
            throw QuoinIntentError.unreadable(ref.title)
        }
        return body(await session.document)
    }

    // MARK: - Opening in the UI

    /// Open `ref` in Quoin's UI by handing its boundary-safe `quoin://` deep
    /// link to LaunchServices — the exact path an external deep link takes
    /// (`AppDelegate.application(_:open:)`), so all the confinement (lexical
    /// resolve, existence + markdown check, live security scope) applies
    /// unchanged, warm or cold. A no-op when no library is configured or the
    /// ref somehow falls outside the library root (`deepLink` returns nil). The
    /// building only needs the root PATH, so the handle is released immediately.
    static func openInUI(_ ref: LibraryQuery.DocumentRef) {
        guard let handle = try? open() else { return }
        let rootPath = handle.root.standardizedFileURL.path
        handle.release()
        guard let link = QuoinURLScheme.deepLink(
            forDocumentPath: ref.url.standardizedFileURL.path,
            relativeTo: rootPath)
        else { return }
        NSWorkspace.shared.open(link)
    }
}
#endif
