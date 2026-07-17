import Foundation
import QuickLookUI
import UniformTypeIdentifiers
import QuoinCore

/// Data-based Quick Look preview provider for Markdown documents (issue #8).
///
/// Thin by design: it hands the file to the shared `QuickLookContent`, which
/// parses it under the preview byte budget and reuses `HTMLExporter` to emit a
/// self-contained HTML representation. Diagrams/math are placeholders and
/// images are text references, so the preview opens instantly and never runs
/// the full Mermaid/Vinculum layout or reads a sibling file.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let html = QuickLookContent.previewHTML(for: url)
        let data = Data(html.utf8)

        let reply = QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 800, height: 1000)
        ) { (_: QLPreviewReply) in
            data
        }
        reply.title = QuickLookContent.title(for: url)
        reply.stringEncoding = .utf8
        return reply
    }
}
