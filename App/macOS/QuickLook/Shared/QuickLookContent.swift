import Foundation
import QuoinCore

/// Shared, platform-free helper for the Quick Look thumbnail and preview
/// extensions. It reads the previewed `.md` file under a hard BYTE cap and
/// runs the SHARED QuoinCore parse + bounded-preview reduction (issue #8) so
/// a pathological file can never make Finder/Spotlight hang. The two Quick
/// Look principal classes stay thin — they only turn the bounded document
/// into an image (thumbnail) or HTML (preview).
enum QuickLookContent {

    /// Reads at most `maxBytes + 1` bytes from `url` (so the caller can tell
    /// the file was longer than the budget) and decodes leniently. Never
    /// materialises more than the budget in memory.
    static func boundedSource(at url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data: Data
        if #available(macOS 10.15.4, *) {
            data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        } else {
            data = handle.readData(ofLength: maxBytes + 1)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parse-and-reduce a file into the bounded projection under `bounds`.
    static func boundedDocument(at url: URL, bounds: PreviewBounds) -> BoundedPreviewDocument {
        let source = boundedSource(at: url, maxBytes: bounds.maxInputBytes)
        return BoundedPreview.make(fromSource: source, bounds: bounds)
    }

    /// A display title for the preview: the file name without extension.
    static func title(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Restrictive Content-Security-Policy for the preview HTML. Quick Look
    /// renders the returned HTML in its OWN WebView/host process, outside this
    /// extension's sandbox, so the missing `network.client` entitlement does
    /// NOT block a fetch the page itself initiates. This policy is the enforce-
    /// ment: `default-src 'none'` blocks scripts, iframes, remote images,
    /// remote stylesheets, fonts, and any connect/fetch; only inline styles
    /// (the exporter inlines its `<style>`) and `data:` images/fonts are
    /// allowed — both fully local. Even if raw HTML somehow slipped past the
    /// reducer's neutralisation, it could not reach the network. (Belt: the
    /// `BoundedPreview` reducer already turns raw HTML into inert text.)
    static let previewCSP =
        "default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:"

    /// Renders the bounded document to a self-contained HTML string for the
    /// data-based Quick Look preview. Reuses `HTMLExporter` — the same export
    /// path the app uses. `baseURL` is intentionally nil: the bounded model
    /// has already swapped images for text placeholders, so no sibling file
    /// is ever read (the extension has no entitlement to reach them anyway).
    static func previewHTML(for url: URL) -> String {
        let bounded = boundedDocument(at: url, bounds: .preview)
        var html = HTMLExporter.export(
            bounded.document, title: title(for: url), baseURL: nil,
            contentSecurityPolicy: previewCSP)
        if bounded.blocksTruncated || bounded.inputTruncated {
            // Insert a small notice just before </main> so the reader knows
            // the preview is clipped.
            let notice = "<p class=\"front-matter\"><code>Preview truncated — open in Quoin to see the full document.</code></p>\n"
            if let range = html.range(of: "</main>") {
                html.replaceSubrange(range, with: notice + "</main>")
            }
        }
        return html
    }
}
