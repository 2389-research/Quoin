#if canImport(AppIntents)
import AppIntents
import Foundation
import QuoinCore
import UniformTypeIdentifiers

// Quoin's App Intents surface: a small, high-value set of actions that bridge
// the local library into Shortcuts, Spotlight, and Siri WITHOUT compromising
// the local-only architecture. Every mutating intent flows through
// `IntentLibraryAccess` → `DocumentSession`, never a raw file write, so the
// source-of-truth and byte-losslessness invariants hold. The pure resolution +
// append logic lives in QuoinCore (`LibraryQuery`, `DocumentAppend`); these
// structs are the thin, macOS-only shell over it.
//
// The protocol requirements are computed (`static var … { … }`), not stored,
// so they satisfy the get-only requirements under the app target's Swift 6
// language mode without becoming nonisolated mutable global state.

// MARK: - Create Note

@available(macOS 14.0, *)
struct CreateNoteIntent: AppIntent {
    static var title: LocalizedStringResource { "Create Note" }
    static var description: IntentDescription {
        IntentDescription("Create a new note in your Quoin library and open it.", categoryName: "Documents")
    }
    /// Bring Quoin forward and show the new note after creating it.
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Title", default: "Untitled")
    var noteTitle: String

    @Parameter(title: "Body", default: "")
    var body: String

    static var parameterSummary: some ParameterSummary {
        Summary("Create note \(\.$noteTitle) with \(\.$body)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<QuoinDocumentEntity> {
        let ref = try await IntentLibraryAccess.createNote(title: noteTitle, body: body)
        IntentLibraryAccess.openInUI(ref)
        return .result(value: QuoinDocumentEntity(ref))
    }
}

// MARK: - Append Text to Note

@available(macOS 14.0, *)
struct AppendToNoteIntent: AppIntent {
    static var title: LocalizedStringResource { "Append Text to Note" }
    static var description: IntentDescription {
        IntentDescription("Add text to the end of a note in your Quoin library.", categoryName: "Documents")
    }

    @Parameter(title: "Note")
    var note: QuoinDocumentEntity

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Append \(\.$text) to \(\.$note)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<QuoinDocumentEntity> {
        try await IntentLibraryAccess.appendText(text, to: note.ref)
        return .result(value: note)
    }
}

// MARK: - Open Note

@available(macOS 14.0, *)
struct OpenNoteIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Note" }
    static var description: IntentDescription {
        IntentDescription("Open a note from your Quoin library.", categoryName: "Documents")
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Note")
    var note: QuoinDocumentEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$note)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLibraryAccess.openInUI(note.ref)
        return .result()
    }
}

// MARK: - Search Library

@available(macOS 14.0, *)
struct SearchLibraryIntent: AppIntent {
    static var title: LocalizedStringResource { "Search Library" }
    static var description: IntentDescription {
        IntentDescription("Search your Quoin library by note name and content.", categoryName: "Documents")
    }

    @Parameter(title: "Query")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search Quoin for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[QuoinDocumentEntity]> {
        let handle = try IntentLibraryAccess.open()
        defer { handle.release() }
        let tree = IntentLibraryAccess.scan(handle)
        let rootPath = handle.root.standardizedFileURL.path
        // QuickOpen.search is the same fuzzy-title + content-snippet recognizer
        // the ⇧⌘F / ⇧⌘O panels use — one index, one behavior.
        let entities = QuickOpen.search(query: query, in: tree).compactMap { result -> QuoinDocumentEntity? in
            guard let relative = LibraryQuery.relativePath(
                forPath: result.url.standardizedFileURL.path, rootPath: rootPath)
            else { return nil }
            return QuoinDocumentEntity(LibraryQuery.DocumentRef(
                url: result.url, title: result.title, relativePath: relative))
        }
        return .result(value: entities)
    }
}

// MARK: - Export Note

@available(macOS 14.0, *)
enum QuoinExportFormat: String, AppEnum {
    case html
    case markdown
    case plainText

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Export Format")
    }

    static var caseDisplayRepresentations: [QuoinExportFormat: DisplayRepresentation] {
        [
            .html: "HTML",
            .markdown: "Markdown",
            .plainText: "Plain Text",
        ]
    }
}

@available(macOS 14.0, *)
struct ExportNoteIntent: AppIntent {
    static var title: LocalizedStringResource { "Export Note" }
    static var description: IntentDescription {
        IntentDescription("Export a note from your Quoin library as HTML, Markdown, or plain text.", categoryName: "Documents")
    }

    @Parameter(title: "Note")
    var note: QuoinDocumentEntity

    @Parameter(title: "Format", default: .html)
    var format: QuoinExportFormat

    static var parameterSummary: some ParameterSummary {
        Summary("Export \(\.$note) as \(\.$format)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let title = note.title
        let baseURL = note.url.deletingLastPathComponent()
        let format = self.format
        // Render WHILE the library scope is held (HTML inlines local images).
        let rendered: (string: String, ext: String, type: UTType) =
            try await IntentLibraryAccess.withDocument(at: note.ref) { document in
                switch format {
                case .html:
                    return (HTMLExporter.export(document, title: title, baseURL: baseURL), "html", .html)
                case .markdown:
                    return (MarkdownExporter.export(document), "md", .plainText)
                case .plainText:
                    return (PlainTextExporter.export(document), "txt", .plainText)
                }
            }
        let file = IntentFile(
            data: Data(rendered.string.utf8), filename: "\(title).\(rendered.ext)", type: rendered.type)
        return .result(value: file)
    }
}
#endif
