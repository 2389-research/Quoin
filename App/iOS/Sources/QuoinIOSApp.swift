import SwiftUI
import UniformTypeIdentifiers

@main
struct QuoinIOSApp: App {
    var body: some Scene {
        DocumentGroup(viewing: MarkdownFileDocument.self) { configuration in
            IOSReaderScreen(
                fileURL: configuration.fileURL,
                initialText: configuration.document.text
            )
        }
    }
}

extension UTType {
    static let markdownDocument = UTType(importedAs: "net.daringfireball.markdown")
}

/// Read-only document wrapper: the Files-app browser opens documents; the
/// only write path is the session's byte-precise checkbox toggle.
struct MarkdownFileDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.markdownDocument, .plainText, .text]
    }

    let text: String

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
