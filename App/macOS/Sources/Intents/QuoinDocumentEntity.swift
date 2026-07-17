#if canImport(AppIntents)
import AppIntents
import Foundation
import QuoinCore

/// A markdown document in the user's library, as seen by Shortcuts / Siri.
/// Its identity is the library-root-relative path (the same portable shape a
/// `quoin://open?path=…` deep link uses), so a saved Shortcut keeps working
/// after the library moves to a different absolute location. All resolution
/// runs through the decidable `LibraryQuery` seam in QuoinCore against the
/// shared `Library.scan` index.
@available(macOS 14.0, *)
struct QuoinDocumentEntity: AppEntity, Identifiable {

    /// Root-relative path, e.g. `Notes/Today.md`.
    let id: String
    /// Display title (the filename without extension).
    let title: String
    /// Absolute URL — carried for the intents that do I/O; not shown.
    let url: URL

    init(_ ref: LibraryQuery.DocumentRef) {
        self.id = ref.relativePath
        self.title = ref.title
        self.url = ref.url
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Note")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(id)")
    }

    /// The ref this entity stands for (round-trips id/title/url back into the
    /// QuoinCore value the mutation helpers take).
    var ref: LibraryQuery.DocumentRef {
        LibraryQuery.DocumentRef(url: url, title: title, relativePath: id)
    }

    static var defaultQuery: QuoinDocumentQuery { QuoinDocumentQuery() }
}

/// Resolves ``QuoinDocumentEntity`` values for Shortcuts — by identity
/// (`entities(for:)`), by free-text (`entities(matching:)`, so a user can type
/// a note's name), and a suggested list for pickers.
@available(macOS 14.0, *)
struct QuoinDocumentQuery: EntityQuery, EntityStringQuery {

    @MainActor
    func entities(for identifiers: [String]) async throws -> [QuoinDocumentEntity] {
        IntentLibraryAccess.documents(withRelativePaths: identifiers).map(QuoinDocumentEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [QuoinDocumentEntity] {
        IntentLibraryAccess.rankedDocuments(matching: string).map(QuoinDocumentEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [QuoinDocumentEntity] {
        IntentLibraryAccess.suggestedDocuments().map(QuoinDocumentEntity.init)
    }
}
#endif
