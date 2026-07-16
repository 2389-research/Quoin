import Foundation

/// One node in the library tree: a markdown document, a folder, or a
/// non-markdown asset (shown grayed, not openable). Folders = directories
/// on disk; nothing here is a database.
public struct LibraryNode: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case folder
        case document
        case asset
    }

    public let url: URL
    public let kind: Kind
    public let name: String
    public var children: [LibraryNode]?

    public var id: URL { url }

    public init(url: URL, kind: Kind, name: String, children: [LibraryNode]? = nil) {
        self.url = url
        self.kind = kind
        self.name = name
        self.children = children
    }

    /// Total markdown documents in this subtree.
    public var documentCount: Int {
        switch kind {
        case .document: return 1
        case .asset: return 0
        case .folder: return (children ?? []).reduce(0) { $0 + $1.documentCount }
        }
    }
}

public enum Library {

    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]
    static let hiddenNames: Set<String> = [".git", ".svn", "node_modules", ".obsidian"]

    /// Builds the library tree for a root folder. Folders first, then
    /// documents, then assets, each alphabetically (case-insensitive).
    /// Hidden files and well-known noise directories are skipped.
    public static func scan(root: URL, fileManager: FileManager = .default, maxDepth: Int = 12) -> LibraryNode {
        LibraryNode(
            url: root,
            kind: .folder,
            name: root.lastPathComponent,
            children: scanChildren(of: root, fileManager: fileManager, depth: 0, maxDepth: maxDepth)
        )
    }

    static func scanChildren(of url: URL, fileManager: FileManager, depth: Int, maxDepth: Int) -> [LibraryNode] {
        guard depth < maxDepth,
              let entries = try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        var nodes: [LibraryNode] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if hiddenNames.contains(name) { continue }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                nodes.append(LibraryNode(
                    url: entry,
                    kind: .folder,
                    name: name,
                    children: scanChildren(of: entry, fileManager: fileManager, depth: depth + 1, maxDepth: maxDepth)
                ))
            } else if markdownExtensions.contains(entry.pathExtension.lowercased()) {
                nodes.append(LibraryNode(
                    url: entry,
                    kind: .document,
                    name: entry.deletingPathExtension().lastPathComponent
                ))
            } else {
                nodes.append(LibraryNode(url: entry, kind: .asset, name: name))
            }
        }
        return nodes.sorted { a, b in
            if rank(a.kind) != rank(b.kind) { return rank(a.kind) < rank(b.kind) }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private static func rank(_ kind: LibraryNode.Kind) -> Int {
        switch kind {
        case .folder: return 0
        case .document: return 1
        case .asset: return 2
        }
    }

    // MARK: - File operations (sidebar drag / rename)

    public enum LibraryError: Error {
        case destinationExists(URL)
    }

    /// Moves a file or folder into a destination directory, preserving the
    /// name. Refuses to overwrite.
    public static func move(_ url: URL, into folder: URL, fileManager: FileManager = .default) throws -> URL {
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw LibraryError.destinationExists(destination)
        }
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }

    /// A collision-free URL in `folder` for `baseName`.`ext`, appending a
    /// " 2", " 3"… suffix until the name is free (design rule: silent, never a
    /// modal). `excluding` is treated as non-colliding, so a rename whose only
    /// clash is the file itself keeps its name. Shared by every "pick an
    /// available filename" site (rename, new document, inserted image).
    public static func uniqueURL(
        baseName: String,
        extension ext: String,
        in folder: URL,
        excluding: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        func url(named name: String) -> URL {
            folder.appendingPathComponent(name).appendingPathExtension(ext)
        }
        let excludedKey = excluding.map(identityKey)
        var candidate = url(named: baseName)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path), identityKey(candidate) != excludedKey {
            candidate = url(named: "\(baseName) \(counter)")
            counter += 1
        }
        return candidate
    }

    /// A volume-agnostic identity for a file: its directory plus a
    /// case-folded, canonically-composed name. On case-insensitive or
    /// normalization-insensitive volumes `Bar.md`, `bar.md`, and an NFD
    /// spelling of the same accented name are the *same file* — so a rename
    /// whose only change is case or Unicode normalization matches `excluding`
    /// and keeps its name instead of collecting a spurious " 2" suffix.
    private static func identityKey(_ url: URL) -> String {
        let directory = url.deletingLastPathComponent().standardizedFileURL.path
        let name = url.lastPathComponent
            .precomposedStringWithCanonicalMapping
            .lowercased()
        return directory + "/" + name
    }

    /// Renames a document, keeping its extension; a name collision gets a
    /// " 2", " 3"… suffix silently (design rule: never a modal).
    public static func rename(_ url: URL, to newName: String, fileManager: FileManager = .default) throws -> URL {
        let candidate = uniqueURL(
            baseName: FilenamePolicy.sanitize(newName), extension: url.pathExtension,
            in: url.deletingLastPathComponent(), excluding: url, fileManager: fileManager
        )
        if candidate == url { return url }
        try fileManager.moveItem(at: url, to: candidate)
        return candidate
    }
}

// MARK: - Quick open

/// Fuzzy title matching + full-text snippets for the ⇧⌘O panel.
public enum QuickOpen {

    public struct Result: Identifiable, Hashable, Sendable {
        public let url: URL
        public let title: String
        /// Snippet around the first content match (empty for title matches).
        public let snippet: String
        public let score: Int

        public var id: URL { url }

        public init(url: URL, title: String, snippet: String, score: Int) {
            self.url = url
            self.title = title
            self.snippet = snippet
            self.score = score
        }
    }

    /// Case- and diacritic-insensitive fold, matching the content-snippet
    /// search so a title and a body hit behave identically ("cafe" finds
    /// "Café" in both). Locale-independent for reproducible ordering.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Subsequence fuzzy match: all query characters appear in order.
    /// Score favors consecutive runs and word-boundary hits.
    public static func fuzzyScore(query: String, candidate: String) -> Int? {
        let q = Array(fold(query))
        let c = Array(fold(candidate))
        guard !q.isEmpty else { return 0 }
        var qi = 0
        var score = 0
        var lastMatch = -2
        for (i, ch) in c.enumerated() {
            guard qi < q.count, ch == q[qi] else { continue }
            score += 1
            if i == lastMatch + 1 { score += 2 }                    // consecutive
            if i == 0 || !c[i - 1].isLetter { score += 3 }          // word start
            lastMatch = i
            qi += 1
        }
        return qi == q.count ? score : nil
    }

    /// Searches the library: fuzzy over titles, substring over contents
    /// (first hit becomes a snippet). Content reads are capped for speed.
    public static func search(
        query: String,
        in root: LibraryNode,
        maxResults: Int = 20,
        contentByteLimit: Int = 262_144
    ) -> [Result] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var results: [Result] = []
        func walk(_ node: LibraryNode) {
            if node.kind == .document {
                if let score = fuzzyScore(query: trimmed, candidate: node.name) {
                    results.append(Result(url: node.url, title: node.name, snippet: "", score: score + 100))
                } else if let snippet = contentSnippet(for: trimmed, in: node.url, byteLimit: contentByteLimit) {
                    results.append(Result(url: node.url, title: node.name, snippet: snippet, score: 10))
                }
            }
            for child in node.children ?? [] { walk(child) }
        }
        walk(root)
        return Array(results.sorted { $0.score > $1.score }.prefix(maxResults))
    }

    static func contentSnippet(for query: String, in url: URL, byteLimit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: byteLimit),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        defer { try? handle.close() }
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        return text[start..<end]
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
