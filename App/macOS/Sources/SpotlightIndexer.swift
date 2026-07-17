#if canImport(CoreSpotlight)
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers
import QuoinCore

/// macOS-only Core Spotlight glue (#6). Everything device-specific — building a
/// `CSSearchableItemAttributeSet`, talking to `CSSearchableIndex` — lives here;
/// the field derivation and the stable identifier come from the platform-free
/// `SpotlightIndexing` in QuoinCore.
///
/// Reconciliation is idempotent and incremental. Each pass walks the current
/// library scan and:
///   • (re)indexes documents whose file changed since the last pass (unchanged
///     files are skipped by a cheap modification-date stat — no re-read/parse),
///   • DELETES items for documents that moved or disappeared, diffed against
///     the current scan so no orphan lingers.
/// The per-root identifier → modification-date map is persisted to
/// `UserDefaults`, so the stale-set diff stays correct across launches (a file
/// deleted while the app was closed is still detected and removed).
///
/// Privacy: this indexes into Quoin's PRIVATE, on-device index
/// (`CSSearchableIndex.default()`). Nothing is uploaded and nothing is marked
/// for public/server indexing — the app makes no network request for it.
@MainActor
final class SpotlightIndexer {

    /// identifier → file modification date at last index, for the CURRENT root.
    private var indexed: [String: Date] = [:]
    /// The root whose `indexed` map is currently loaded (nil until first pass).
    private var loadedRootPath: String?
    private var reconcileTask: Task<Void, Never>?

    init() {}

    /// Reconcile the private index against the current library scan. Cheap when
    /// nothing changed (a stat per document). Coalescing: a reconcile already in
    /// flight is superseded, so an FSEvents burst collapses to one pass.
    func reconcile(root: LibraryNode, rootURL: URL) {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let rootPath = rootURL.standardizedFileURL.path

        // Load (or reload, on a library switch) the persisted map for this root.
        if loadedRootPath != rootPath {
            indexed = Self.loadPersisted(rootPath: rootPath)
            loadedRootPath = rootPath
        }

        reconcileTask?.cancel()
        let previous = indexed
        reconcileTask = Task.detached(priority: .utility) {
            let plan = Self.plan(root: root, rootPath: rootPath, previous: previous)
            if Task.isCancelled { return }
            // The default index is a process-wide, thread-safe singleton — fetch
            // it here rather than capturing it across the actor hop.
            let index = CSSearchableIndex.default()
            // Delete first so a move (old id gone, new id added) never briefly
            // duplicates in the index.
            if !plan.staleIdentifiers.isEmpty {
                try? await index.deleteSearchableItems(withIdentifiers: plan.staleIdentifiers)
            }
            if !plan.items.isEmpty {
                try? await index.indexSearchableItems(plan.items)
            }
            if Task.isCancelled { return }
            // Extract the Sendable result before hopping back — the CSSearchableItem
            // array in `plan` never crosses the actor boundary.
            let nextIndexed = plan.nextIndexed
            await MainActor.run { [weak self] in
                guard let self, self.loadedRootPath == rootPath else { return }
                self.indexed = nextIndexed
                Self.persist(nextIndexed, rootPath: rootPath)
            }
        }
    }

    // MARK: - Planning (off the main actor)

    private struct Plan {
        let items: [CSSearchableItem]
        let staleIdentifiers: [String]
        let nextIndexed: [String: Date]
    }

    nonisolated private static func plan(root: LibraryNode, rootPath: String, previous: [String: Date]) -> Plan {
        var items: [CSSearchableItem] = []
        var nextIndexed: [String: Date] = [:]
        var currentIDs = Set<String>()

        func walk(_ node: LibraryNode) {
            switch node.kind {
            case .document:
                // Only `.md` is indexed: the deep-link open path
                // (consumePendingDeepLink) opens `.md` exclusively, so an item
                // for a `.txt`/`.markdown` sibling would surface in Spotlight
                // but refuse to open on tap. Keep the indexed set == openable set.
                guard node.url.pathExtension.lowercased() == "md" else { return }
                let absPath = node.url.standardizedFileURL.path
                // The id is the ROOT-SCOPED absolute path (unique across the
                // app-wide index); the relative path is the display subtitle.
                guard let id = SpotlightIndexing.identifier(
                        forDocumentPath: absPath, relativeTo: rootPath),
                      let relativePath = SpotlightIndexing.relativePath(
                        forDocumentPath: absPath, relativeTo: rootPath)
                else { return }
                currentIDs.insert(id)
                let modDate = (try? node.url.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                if let prior = previous[id], prior == modDate {
                    // Unchanged since last index — keep it, skip the re-read.
                    nextIndexed[id] = prior
                    return
                }
                guard let text = try? String(contentsOf: node.url, encoding: .utf8) else {
                    // Unreadable right now (locked/racing a write): leave the
                    // existing item in place and try again next pass. It stays
                    // in `currentIDs`, so it is NOT swept as stale.
                    if let prior = previous[id] { nextIndexed[id] = prior }
                    return
                }
                let document = MarkdownConverter.parse(text)
                let derived = SpotlightIndexing.indexedDocument(
                    for: document, identifier: id, relativePath: relativePath,
                    filenameStem: node.name)
                items.append(makeItem(derived))
                nextIndexed[id] = modDate
            case .folder:
                node.children?.forEach(walk)
            case .asset:
                break
            }
        }
        walk(root)

        let stale = SpotlightIndexing.staleIdentifiers(
            previouslyIndexed: Set(previous.keys), current: currentIDs)
        return Plan(items: items, staleIdentifiers: stale, nextIndexed: nextIndexed)
    }

    nonisolated private static func makeItem(_ doc: SpotlightIndexing.IndexedDocument) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .plainText)
        attributes.title = doc.title
        attributes.displayName = doc.title
        attributes.contentDescription = doc.snippet
        attributes.textContent = doc.textContent
        // Headings and front-matter values both land as keywords so a search
        // for a heading or a tag surfaces the document.
        let keywords = doc.headings + doc.keywords
        if !keywords.isEmpty { attributes.keywords = keywords }
        // Deliberately NO contentURL: a file URL would let the system open the
        // document directly (via the default handler, outside our confinement),
        // bypassing the deep-link continuation. Omitting it makes a tap arrive
        // as a CSSearchableItemActionType activity we route through the
        // in-library quoin:// resolution.

        let item = CSSearchableItem(
            uniqueIdentifier: doc.identifier,
            domainIdentifier: SpotlightIndexing.domainIdentifier,
            attributeSet: attributes)
        // No expiration: the item lives until we delete it in a reconcile pass.
        item.expirationDate = Date.distantFuture
        return item
    }

    // MARK: - Persistence (per root, so the stale diff survives launches)

    private static let persistPrefix = "quoin.spotlight.indexed."
    /// Registry of persisted root paths, LRU-ordered (oldest first). Bounds the
    /// per-root `indexed.<root>` blobs so they can't accumulate forever as a
    /// user opens many folders over time (none is pruned on library removal —
    /// there is no such lifecycle signal — so we cap by recency instead).
    private static let persistRegistryKey = "quoin.spotlight.roots"
    /// How many roots' maps to retain. Generous — a user with dozens of active
    /// libraries keeps them all; only the long tail of once-opened folders is
    /// swept.
    private static let maxPersistedRoots = 32

    private static func persistKey(rootPath: String) -> String {
        persistPrefix + rootPath
    }

    private static func loadPersisted(rootPath: String) -> [String: Date] {
        guard let raw = UserDefaults.standard.dictionary(forKey: persistKey(rootPath: rootPath))
        else { return [:] }
        var result: [String: Date] = [:]
        for (key, value) in raw {
            if let date = value as? Date { result[key] = date }
        }
        return result
    }

    private static func persist(_ map: [String: Date], rootPath: String) {
        var registry = UserDefaults.standard.stringArray(forKey: persistRegistryKey) ?? []
        if map.isEmpty {
            // This root has no indexed documents: drop its blob AND its registry
            // entry so a removed/empty library leaves nothing behind.
            UserDefaults.standard.removeObject(forKey: persistKey(rootPath: rootPath))
            registry.removeAll { $0 == rootPath }
            setRegistry(registry)
            return
        }
        UserDefaults.standard.set(map, forKey: persistKey(rootPath: rootPath))
        // Touch this root as most-recent and evict the long tail of stale roots.
        let (next, evicted) = SpotlightIndexing.prunedRootRegistry(
            registry, touching: rootPath, limit: maxPersistedRoots)
        for path in evicted {
            UserDefaults.standard.removeObject(forKey: persistKey(rootPath: path))
        }
        setRegistry(next)
    }

    private static func setRegistry(_ registry: [String]) {
        if registry.isEmpty {
            UserDefaults.standard.removeObject(forKey: persistRegistryKey)
        } else {
            UserDefaults.standard.set(registry, forKey: persistRegistryKey)
        }
    }
}
#endif
