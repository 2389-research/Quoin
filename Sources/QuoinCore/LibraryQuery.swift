import Foundation

/// Resolves documents within a scanned library tree — the *decidable*,
/// platform-free half of the App Intents document surface. It never touches
/// the filesystem itself: it operates on a `LibraryNode` tree produced by
/// `Library.scan` (the SAME index the sidebar and quick-open use — no second
/// discovery path) and returns lightweight references the app shell turns into
/// `AppEntity` values. Kept in QuoinCore so name/path resolution and its
/// containment rules are unit-testable and build on Linux.
///
/// A document's *portable identity* is its path RELATIVE to the library root
/// (the same shape a `quoin://open?path=…` deep link uses), so an entity id
/// survives the library moving to a different absolute location.
public enum LibraryQuery {

    /// A resolved document: its absolute URL (for I/O in the shell), a display
    /// title, and the root-relative path that is its stable identity.
    public struct DocumentRef: Hashable, Sendable, Identifiable {
        public let url: URL
        public let title: String
        public let relativePath: String

        public var id: String { relativePath }

        public init(url: URL, title: String, relativePath: String) {
            self.url = url
            self.title = title
            self.relativePath = relativePath
        }
    }

    /// The root-relative path for `path` under `rootPath`, or `nil` when it is
    /// not strictly inside the root. Lexical only (no I/O): the trailing slash
    /// stops a sibling whose name merely starts with the root from matching,
    /// and the root itself is not a document.
    public static func relativePath(forPath path: String, rootPath: String) -> String? {
        let root = QuoinURLScheme.normalize(rootPath)
        let doc = QuoinURLScheme.normalize(path)
        guard doc != root, doc.hasPrefix(root + "/") else { return nil }
        let relative = String(doc.dropFirst(root.count + 1))
        return relative.isEmpty ? nil : relative
    }

    /// Every markdown document in the tree, flattened to refs, in tree order
    /// (folders-first, alphabetical — whatever `Library.scan` produced).
    /// `rootPath` anchors the relative-path identities.
    public static func documents(in root: LibraryNode, rootPath: String) -> [DocumentRef] {
        let normalizedRoot = QuoinURLScheme.normalize(rootPath)
        var refs: [DocumentRef] = []
        func walk(_ node: LibraryNode) {
            if node.kind == .document,
               let relative = relativePath(forPath: node.url.standardizedFileURL.path, rootPath: normalizedRoot) {
                refs.append(DocumentRef(url: node.url, title: node.name, relativePath: relative))
            }
            for child in node.children ?? [] { walk(child) }
        }
        walk(root)
        return refs
    }

    /// Resolve refs by their relative-path identity — the App Intents
    /// `entities(for:)` path. Unknown ids are simply omitted (a stale
    /// Shortcuts reference resolves to nothing rather than erroring). Matching
    /// is exact on the normalized relative path.
    public static func documents(
        withRelativePaths ids: [String], in root: LibraryNode, rootPath: String
    ) -> [DocumentRef] {
        let wanted = Set(ids.map { QuoinURLScheme.normalize($0) })
        guard !wanted.isEmpty else { return [] }
        return documents(in: root, rootPath: rootPath).filter {
            wanted.contains(QuoinURLScheme.normalize($0.relativePath))
        }
    }

    /// Rank documents matching a free-text `query` (a title, a filename with
    /// or without `.md`, or a relative path). Exact identity matches win
    /// decisively; then case-insensitive title equality; then the shared
    /// fuzzy-title score (`QuickOpen.fuzzyScore`, the same recognizer quick
    /// open uses). Content is NOT read here — this drives entity disambiguation
    /// and "Open Note", where a title/path match is what a person means;
    /// full-text lives in `QuickOpen.search` (the Search Library intent).
    public static func rank(
        query: String, in root: LibraryNode, rootPath: String, limit: Int = 25
    ) -> [DocumentRef] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let all = documents(in: root, rootPath: rootPath)
        guard !trimmed.isEmpty else { return Array(all.prefix(limit)) }

        let folded = QuickOpen.fold(trimmed)
        // A query that names a file may or may not carry the extension.
        let foldedNoExt = folded.hasSuffix(".md") ? String(folded.dropLast(3)) : folded

        func score(_ ref: DocumentRef) -> Int? {
            let title = QuickOpen.fold(ref.title)
            let relative = QuickOpen.fold(ref.relativePath)
            let relativeNoExt = relative.hasSuffix(".md") ? String(relative.dropLast(3)) : relative
            // Exact identity: full relative path or bare filename.
            if relative == folded || relativeNoExt == foldedNoExt { return 1000 }
            if title == foldedNoExt { return 900 }
            // Prefix on the title reads as "the note I'm typing the start of".
            if title.hasPrefix(foldedNoExt) { return 500 + foldedNoExt.count }
            // Otherwise fall back to the shared subsequence fuzzy score.
            return QuickOpen.fuzzyScore(query: trimmed, candidate: ref.title)
        }

        return all
            .compactMap { ref -> (DocumentRef, Int)? in score(ref).map { (ref, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}
