import Foundation

/// Standalone HTML export: one self-contained file, styles inlined from the
/// design tokens. Local images are inlined as base64 `data:` URIs (pass the
/// document's directory as `baseURL` so relative `![](assets/x.png)` paths
/// resolve); remote images and any that cannot be read stay as external
/// `<img src>` references — never a silent drop (issue #3).
///
/// ## Raw HTML policy (issue #4)
///
/// Markdown may carry raw HTML (block and inline). By DEFAULT the exporter
/// PRESERVES it verbatim, which keeps full Markdown fidelity — the low-level
/// contract for callers that want an exact projection (Quick Look already
/// neutralises raw HTML upstream and pins a strict CSP, so it needs nothing
/// here). But raw HTML is also how a `.md` file smuggles `<script>`, remote
/// `<iframe>`/`<object>` embeds, and tracking-pixel `<img>`s past export, at
/// odds with Quoin's local-first/private stance.
///
/// The `sanitizeRawHTML` flag turns on an explicit, documented, dependency-free
/// allowlist scrub (`HTMLSanitizer`): `<script>/<style>/<iframe>/<object>/
/// <embed>` elements, `on*` handlers, `javascript:`/`vbscript:` URLs, and
/// remote auto-loading resources are removed while benign structural HTML
/// stays. When it is on, `javascript:`/`vbscript:` schemes in Markdown-derived
/// link and image destinations are neutralised too. The macOS export sheet and
/// the Shortcuts/iOS standalone-export paths turn this ON by default
/// (private-by-default self-contained files); the sheet offers an opt-out
/// toggle for users who need byte-exact raw HTML.
public enum HTMLExporter {

    /// Renders `document` to one self-contained HTML file.
    ///
    /// - Parameters:
    ///   - contentSecurityPolicy: when non-nil, a
    ///     `<meta http-equiv="Content-Security-Policy">` with this policy is
    ///     emitted in `<head>`. The interactive app export leaves this nil (the
    ///     user WANTS remote images to resolve in their browser); the Quick Look
    ///     preview passes a restrictive policy so a hostile file's raw HTML can
    ///     never make Quick Look's WebView fetch a remote resource (issue #8).
    ///   - sanitizeRawHTML: when true, raw HTML is run through `HTMLSanitizer`
    ///     and dangerous URL schemes are stripped from Markdown link/image
    ///     destinations (issue #4). Defaults to false (raw HTML preserved for
    ///     Markdown fidelity); the app's standalone-export entry points pass
    ///     true so saved files are private by default.
    public static func export(
        _ document: QuoinDocument,
        title: String = "Document",
        baseURL: URL? = nil,
        contentSecurityPolicy: String? = nil,
        sanitizeRawHTML: Bool = false
    ) -> String {
        var body = ""
        render(document.blocks, document: document, baseURL: baseURL, sanitize: sanitizeRawHTML, into: &body)

        if !document.footnotes.isEmpty {
            body += "<hr>\n<section class=\"footnotes\">\n"
            for footnote in document.footnotes {
                body += "<div id=\"fn-\(escape(footnote.id))\"><sup>\(footnote.index)</sup> "
                var content = ""
                render(footnote.blocks, document: document, baseURL: baseURL, sanitize: sanitizeRawHTML, into: &content)
                body += content + "</div>\n"
            }
            body += "</section>\n"
        }

        let cspMeta = contentSecurityPolicy.map {
            "<meta http-equiv=\"Content-Security-Policy\" content=\"\(escapeAttribute($0))\">\n"
        } ?? ""

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        \(cspMeta)<title>\(escape(title))</title>
        <style>\(stylesheet)</style>
        </head>
        <body>
        <main>
        \(body)</main>
        </body>
        </html>
        """
    }

    // MARK: - Blocks

    private static func render(_ blocks: [Block], document: QuoinDocument, baseURL: URL?, sanitize: Bool, into out: inout String) {
        for block in blocks {
            switch block.kind {
            case .heading(let level, let inlines, let slug):
                let tag = "h\(min(max(level, 1), 6))"
                out += "<\(tag) id=\"\(escape(slug))\">\(render(inlines, baseURL: baseURL, sanitize: sanitize))</\(tag)>\n"
            case .paragraph(let inlines):
                out += "<p>\(render(inlines, baseURL: baseURL, sanitize: sanitize))</p>\n"
            case .codeBlock(let language, let code):
                let lang = language.map { " class=\"language-\(escape($0))\"" } ?? ""
                out += "<pre><code\(lang)>\(escape(code))</code></pre>\n"
            case .mermaid(let source):
                out += "<pre class=\"mermaid-source\"><code>\(escape(source))</code></pre>\n"
            case .mathBlock(let latex):
                out += "<p class=\"math-display\">\\[\(escape(latex))\\]</p>\n"
            case .table(let header, let rows, let alignments):
                out += renderTable(header: header, rows: rows, alignments: alignments, baseURL: baseURL, sanitize: sanitize)
            case .list(let items, let ordered, let start):
                let tag = ordered ? "ol" : "ul"
                let startAttr = ordered && start != 1 ? " start=\"\(start)\"" : ""
                out += "<\(tag)\(startAttr)>\n"
                for item in items {
                    if let task = item.task {
                        let checked = task == .checked ? " checked" : ""
                        out += "<li class=\"task\"><input type=\"checkbox\" disabled\(checked)> "
                    } else {
                        out += "<li>"
                    }
                    var inner = ""
                    render(item.blocks, document: document, baseURL: baseURL, sanitize: sanitize, into: &inner)
                    // Unwrap a single paragraph so simple items stay tight.
                    if item.blocks.count == 1, inner.hasPrefix("<p>"), inner.hasSuffix("</p>\n") {
                        inner = String(inner.dropFirst(3).dropLast(5))
                    }
                    out += inner + "</li>\n"
                }
                out += "</\(tag)>\n"
            case .blockQuote(let children):
                var inner = ""
                render(children, document: document, baseURL: baseURL, sanitize: sanitize, into: &inner)
                out += "<blockquote>\n\(inner)</blockquote>\n"
            case .callout(let kind, let children):
                var inner = ""
                render(children, document: document, baseURL: baseURL, sanitize: sanitize, into: &inner)
                out += "<aside class=\"callout callout-\(kind.rawValue)\"><p class=\"callout-title\">\(kind.title)</p>\n\(inner)</aside>\n"
            case .frontMatter(let yaml):
                out += "<pre class=\"front-matter\"><code>\(escape(yaml))</code></pre>\n"
            case .reviewEndmatter(let yaml):
                out += "<pre class=\"review-endmatter\"><code>\(escape(yaml))</code></pre>\n"
            case .tableOfContents:
                out += "<nav class=\"toc\">\n<ul>\n"
                for heading in document.outline {
                    out += "<li class=\"toc-\(heading.level)\"><a href=\"#\(escape(heading.slug))\">\(escape(heading.title))</a></li>\n"
                }
                out += "</ul>\n</nav>\n"
            case .thematicBreak:
                out += "<hr>\n"
            case .htmlBlock(let html):
                out += (sanitize ? HTMLSanitizer.sanitize(html) : html) + "\n"
            }
        }
    }

    private static func renderTable(header: [TableCell], rows: [[TableCell]], alignments: [TableAlignment], baseURL: URL?, sanitize: Bool) -> String {
        func align(_ index: Int) -> String {
            guard index < alignments.count else { return "" }
            switch alignments[index] {
            case .left: return " style=\"text-align:left\""
            case .center: return " style=\"text-align:center\""
            case .right: return " style=\"text-align:right\""
            case .none: return ""
            }
        }
        var out = "<table>\n<thead><tr>"
        for (i, cell) in header.enumerated() {
            out += "<th\(align(i))>\(render(cell.inlines, baseURL: baseURL, sanitize: sanitize))</th>"
        }
        out += "</tr></thead>\n<tbody>\n"
        for row in rows {
            out += "<tr>"
            for (i, cell) in row.enumerated() {
                out += "<td\(align(i))>\(render(cell.inlines, baseURL: baseURL, sanitize: sanitize))</td>"
            }
            out += "</tr>\n"
        }
        out += "</tbody>\n</table>\n"
        return out
    }

    // MARK: - Inlines

    private static func render(_ inlines: [Inline], baseURL: URL?, sanitize: Bool) -> String {
        var out = ""
        for inline in inlines {
            switch inline {
            case .text(let text):
                out += escape(text)
            case .code(let code):
                out += "<code>\(escape(code))</code>"
            case .emphasis(let children):
                out += "<em>\(render(children, baseURL: baseURL, sanitize: sanitize))</em>"
            case .strong(let children):
                out += "<strong>\(render(children, baseURL: baseURL, sanitize: sanitize))</strong>"
            case .strikethrough(let children):
                out += "<del>\(render(children, baseURL: baseURL, sanitize: sanitize))</del>"
            case .highlight(let children, let color):
                out += "<mark class=\"hl-\(color.rawValue)\">\(render(children, baseURL: baseURL, sanitize: sanitize))</mark>"
            case .link(let destination, let children):
                // Under the sanitize policy, a `javascript:`/`vbscript:` link
                // destination — or a `data:` document that would execute on
                // click (`data:text/html`, xhtml, svg) — is neutralised to an
                // inert anchor (issue #4).
                let raw = destination ?? "#"
                let href = (sanitize && HTMLSanitizer.isDangerousNavigationScheme(raw)) ? "#" : escapeAttribute(raw)
                out += "<a href=\"\(href)\">\(render(children, baseURL: baseURL, sanitize: sanitize))</a>"
            case .image(let source, let alt):
                out += renderImage(source: source, alt: alt, baseURL: baseURL, sanitize: sanitize)
            case .math(let latex):
                out += "<span class=\"math-inline\">\\(\(escape(latex))\\)</span>"
            case .footnoteReference(let id, let index):
                out += "<sup class=\"fn-ref\"><a href=\"#fn-\(escapeAttribute(id))\">\(index)</a></sup>"
            case .suggestion(let kind, _, _):
                // Canonical CriticMarkup HTML (toolkit conventions).
                switch kind {
                case .insertion(let children):
                    out += "<ins>\(render(children, baseURL: baseURL, sanitize: sanitize))</ins>"
                case .deletion(let children):
                    out += "<del>\(render(children, baseURL: baseURL, sanitize: sanitize))</del>"
                case .substitution(let old, let new):
                    out += "<del>\(render(old, baseURL: baseURL, sanitize: sanitize))</del><ins>\(render(new, baseURL: baseURL, sanitize: sanitize))</ins>"
                case .comment(let text):
                    out += "<span class=\"critic comment\">\(escape(text))</span>"
                case .highlight(let children):
                    out += "<mark class=\"critic\">\(render(children, baseURL: baseURL, sanitize: sanitize))</mark>"
                }
            case .softBreak:
                out += " "
            case .lineBreak:
                out += "<br>"
            case .html(let raw):
                out += sanitize ? HTMLSanitizer.sanitize(raw) : raw
            }
        }
        return out
    }

    // MARK: - Images

    /// Local images inline as base64 `data:` URIs so the exported file is
    /// self-contained; remote images (and any local file we cannot read)
    /// degrade to an external `<img src>` reference rather than a silent drop.
    /// Resolution mirrors the on-screen renderer: absolute `/…` paths and
    /// paths relative to `baseURL` (the document directory).
    private static func renderImage(source: String?, alt: String, baseURL: URL?, sanitize: Bool) -> String {
        let altAttr = escapeAttribute(alt)
        guard let source, !source.isEmpty else {
            return "<img src=\"\" alt=\"\(altAttr)\">"
        }
        // Under the sanitize policy, a `javascript:`/`vbscript:` image source is
        // neutralised to an empty src (issue #4).
        if sanitize, HTMLSanitizer.isDangerousScheme(source) {
            return "<img src=\"\" alt=\"\(altAttr)\">"
        }
        // Already-embedded or remote: keep verbatim (local-only policy never
        // fetches remote bytes, so we cannot inline them).
        if source.hasPrefix("data:")
            || source.hasPrefix("http://") || source.hasPrefix("https://") {
            return "<img src=\"\(escapeAttribute(source))\" alt=\"\(altAttr)\">"
        }
        let fileURL: URL?
        if source.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: source)
        } else if let baseURL {
            fileURL = baseURL.appendingPathComponent(source).standardizedFileURL
        } else {
            fileURL = nil
        }
        if let fileURL, let uri = dataURI(for: fileURL) {
            return "<img src=\"\(uri)\" alt=\"\(altAttr)\">"
        }
        // No base directory or unreadable/missing file: keep the original
        // reference so the image is explicit, never silently gone.
        return "<img src=\"\(escapeAttribute(source))\" alt=\"\(altAttr)\">"
    }

    private static func dataURI(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mime = mimeType(forPathExtension: url.pathExtension.lowercased())
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private static func mimeType(forPathExtension ext: String) -> String {
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "avif": return "image/avif"
        case "ico": return "image/x-icon"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Escaping

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Design-token styles per the element spec (Graphite direction).
    private static let stylesheet = """
    :root{color-scheme:light}
    body{margin:0;background:#fff;color:#333;font:14px/1.7 -apple-system,'SF Pro Text',system-ui,sans-serif}
    main{max-width:680px;margin:0 auto;padding:48px 24px}
    h1{font-size:26px;line-height:1.25;font-weight:700;color:#1d1d1f;margin:32px 0 12px}
    h2{font-size:20px;line-height:1.3;font-weight:700;color:#1d1d1f;margin:28px 0 10px}
    h3{font-size:16px;line-height:1.35;font-weight:600;color:#1d1d1f;margin:22px 0 8px}
    h4,h5,h6{font-size:14px;font-weight:600;color:rgba(29,29,31,.55);margin:16px 0 8px}
    p{margin:0 0 12px}
    strong{color:#1d1d1f}
    del{color:rgba(29,29,31,.45)}
    mark{background:#d9f59b;border-radius:3px;padding:0 2px}
    mark.hl-pink{background:#f7d9f0}
    mark.hl-yellow{background:#fdeeaa}
    mark.hl-blue{background:#cfe6fb}
    mark.hl-orange{background:#fedbc6}
    a{color:#2a6fdb;text-decoration:underline;text-decoration-color:rgba(42,111,219,.35)}
    code{font:12.5px ui-monospace,'SF Mono',monospace;background:#f2f2f4;border-radius:4px;padding:1px 5px}
    pre{background:#1e2430;border-radius:8px;padding:12px 16px;overflow-x:auto}
    pre code{background:none;color:#d6dce6;font-size:12px;line-height:1.6;padding:0}
    blockquote{border-left:3px solid rgba(0,0,0,.15);margin:0 0 12px;padding-left:16px;color:rgba(29,29,31,.55);font-style:italic}
    .callout{border-radius:8px;padding:10px 14px;margin:0 0 12px;border:1px solid}
    .callout-title{font-size:12.5px;font-weight:600;margin-bottom:4px}
    .callout-note{background:rgba(10,132,255,.04);border-color:rgba(10,132,255,.15)}
    .callout-note .callout-title{color:#0a84ff}
    .callout-tip{background:rgba(48,209,88,.04);border-color:rgba(48,209,88,.15)}
    .callout-tip .callout-title{color:#28a745}
    .callout-important{background:rgba(175,82,222,.04);border-color:rgba(175,82,222,.15)}
    .callout-important .callout-title{color:#8944ab}
    .callout-warning{background:rgba(255,159,10,.04);border-color:rgba(255,159,10,.15)}
    .callout-warning .callout-title{color:#c77c02}
    .callout-caution{background:rgba(255,69,58,.04);border-color:rgba(255,69,58,.15)}
    .callout-caution .callout-title{color:#d92d20}
    .callout-danger{background:rgba(255,69,58,.04);border-color:rgba(255,69,58,.15)}
    .callout-danger .callout-title{color:#d92d20}
    table{border-collapse:collapse;margin:0 0 12px;width:100%}
    th{font-weight:600;border-bottom:1.5px solid rgba(29,29,31,.15);padding:6px 10px;text-align:left}
    td{border-bottom:1px solid rgba(29,29,31,.07);padding:6px 10px;font-variant-numeric:tabular-nums}
    ul,ol{margin:0 0 12px;padding-left:24px}
    li.task{list-style:none;margin-left:-20px}
    hr{border:none;border-top:1px solid rgba(29,29,31,.12);margin:20px 0}
    img{max-width:100%;border-radius:8px}
    .front-matter{background:#f2f2f4;border-radius:6px}
    .front-matter code{color:rgba(29,29,31,.55);font-size:10.5px}
    .footnotes{font-size:12px;line-height:1.6;color:rgba(29,29,31,.55)}
    .fn-ref a{text-decoration:none}
    .toc ul{list-style:none;padding-left:0}
    .toc-2{padding-left:16px}.toc-3,.toc-4,.toc-5,.toc-6{padding-left:34px}
    @media print{pre{-webkit-print-color-adjust:exact;print-color-adjust:exact}}
    """
}
