import XCTest
@testable import QuoinCore

final class HTMLExporterTests: XCTestCase {

    func testStandaloneDocumentStructure() {
        let doc = MarkdownConverter.parse("# Title\n\nBody text.")
        let html = HTMLExporter.export(doc, title: "My Doc")
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("<title>My Doc</title>"))
        XCTAssertTrue(html.contains("<style>"))
        XCTAssertTrue(html.contains("<h1 id=\"title\">Title</h1>"))
        XCTAssertTrue(html.contains("<p>Body text.</p>"))
        // Self-contained: no external references.
        XCTAssertFalse(html.contains("src=\"http"))
        XCTAssertFalse(html.contains("<link"))
    }

    func testEscaping() {
        // Note: `<word>` would be inline HTML per cmark and pass through
        // raw — that's correct markdown semantics. Bare operators are text.
        let doc = MarkdownConverter.parse("compare 5 < 6 & 7 > 2 here.")
        let html = HTMLExporter.export(doc)
        XCTAssertTrue(html.contains("compare 5 &lt; 6 &amp; 7 &gt; 2 here."))
    }

    func testRichConstructs() {
        let doc = MarkdownConverter.parse("""
        **bold** and ==marked== and `code`

        > [!TIP]
        > useful

        | a | b |
        |:--|--:|
        | 1 | 2 |

        - [x] done task

        Claim.[^n]

        [^n]: Note text.
        """)
        let html = HTMLExporter.export(doc)
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<mark class=\"hl-lime\">marked</mark>"))
        XCTAssertTrue(html.contains("<code>code</code>"))
        XCTAssertTrue(html.contains("callout-tip"))
        XCTAssertTrue(html.contains("<th style=\"text-align:left\">a</th>"))
        XCTAssertTrue(html.contains("<td style=\"text-align:right\">2</td>"))
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled checked>"))
        XCTAssertTrue(html.contains("fn-ref"))
        XCTAssertTrue(html.contains("Note text."))
    }

    func testEveryCalloutKindHasStyling() {
        // Each CalloutKind must emit a class that the stylesheet actually defines,
        // or the callout exports unstyled (regression: important/caution were bare).
        for kind in CalloutKind.allCases {
            let doc = MarkdownConverter.parse("> [!\(kind.rawValue.uppercased())]\n> body")
            let html = HTMLExporter.export(doc)
            XCTAssertTrue(html.contains("callout-\(kind.rawValue)"),
                          "\(kind.rawValue) callout class not emitted")
            XCTAssertTrue(html.contains(".callout-\(kind.rawValue){"),
                          "\(kind.rawValue) callout has no CSS rule")
        }
    }

    func testCodeBlockKeepsLanguageAndEscapes() {
        let doc = MarkdownConverter.parse("```swift\nlet x = a < b\n```")
        let html = HTMLExporter.export(doc)
        XCTAssertTrue(html.contains("language-swift"))
        XCTAssertTrue(html.contains("let x = a &lt; b"))
    }

    // A 1×1 PNG (valid header + IDAT), enough to prove file bytes are inlined.
    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    func testLocalImageInlinesAsDataURI() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-html-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let assets = dir.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Self.onePixelPNG.write(to: assets.appendingPathComponent("pixel.png"))

        let doc = MarkdownConverter.parse("![a pixel](assets/pixel.png)")
        let html = HTMLExporter.export(doc, baseURL: dir)
        // The local image is embedded, not left as an external reference.
        XCTAssertTrue(html.contains("data:image/png;base64,"),
                      "local image should inline as a data URI")
        XCTAssertTrue(html.contains(Self.onePixelPNG.base64EncodedString()),
                      "the actual file bytes should be embedded")
        XCTAssertFalse(html.contains("src=\"assets/pixel.png\""),
                       "the relative reference should not survive")
        XCTAssertTrue(html.contains("alt=\"a pixel\""))
    }

    func testMissingLocalImageKeepsReferenceNotSilentDrop() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quoin-html-missing-\(UUID().uuidString)")
        let doc = MarkdownConverter.parse("![gone](assets/nope.png)")
        let html = HTMLExporter.export(doc, baseURL: dir)
        // Cannot embed a nonexistent file, but the reference is still explicit.
        XCTAssertTrue(html.contains("src=\"assets/nope.png\""))
        XCTAssertFalse(html.contains("data:"))
    }

    func testRemoteImageStaysExternalReference() {
        let doc = MarkdownConverter.parse("![r](https://example.com/x.png)")
        let html = HTMLExporter.export(doc, baseURL: nil)
        XCTAssertTrue(html.contains("src=\"https://example.com/x.png\""))
    }

    func testTOCLinks() {
        let doc = MarkdownConverter.parse("[TOC]\n\n# One\n\n## Two")
        let html = HTMLExporter.export(doc)
        XCTAssertTrue(html.contains("<a href=\"#one\">One</a>"))
        XCTAssertTrue(html.contains("<a href=\"#two\">Two</a>"))
    }

    // MARK: - Raw HTML export policy (issue #4)

    /// DOCUMENTED DEFAULT: the low-level exporter PRESERVES raw HTML verbatim
    /// (Markdown fidelity). The app's standalone-export entry points opt into
    /// sanitize=true for private-by-default files; this pins the API contract.
    func testRawHTMLPreservedByDefault() {
        let doc = MarkdownConverter.parse("<div onclick=\"x()\">hi</div>")
        let html = HTMLExporter.export(doc)  // default: sanitizeRawHTML == false
        XCTAssertTrue(html.contains("<div onclick=\"x()\">hi</div>"),
                      "default export must preserve raw HTML verbatim for fidelity")
    }

    func testSanitizeRemovesScriptBlock() {
        let doc = MarkdownConverter.parse("<script>alert('pwn')</script>")
        let html = HTMLExporter.export(doc, sanitizeRawHTML: true)
        XCTAssertFalse(html.contains("<script"), "script element must not survive sanitized export")
        XCTAssertFalse(html.contains("alert('pwn')"), "script content must not survive")
    }

    func testSanitizeStripsEventHandlerFromRawBlock() {
        let doc = MarkdownConverter.parse("<div onclick=\"steal()\" class=\"c\">hi</div>")
        let html = HTMLExporter.export(doc, sanitizeRawHTML: true)
        XCTAssertFalse(html.lowercased().contains("onclick"))
        XCTAssertFalse(html.contains("steal()"))
        XCTAssertTrue(html.contains("class=\"c\""), "benign attributes are kept")
    }

    func testSanitizeNeutralisesRemoteTrackingPixelInRawHTML() {
        let doc = MarkdownConverter.parse("<img src=\"https://tracker.example.com/p.png?id=me\">")
        let html = HTMLExporter.export(doc, sanitizeRawHTML: true)
        XCTAssertFalse(html.contains("tracker.example.com"),
                       "remote tracking-pixel src must be dropped in sanitized export")
    }

    func testSanitizeStripsInlineRawHTMLEventHandler() {
        let doc = MarkdownConverter.parse("Hello <b onmouseover=\"x()\">there</b> friend.")
        let html = HTMLExporter.export(doc, sanitizeRawHTML: true)
        XCTAssertFalse(html.lowercased().contains("onmouseover"))
        XCTAssertTrue(html.contains("<b>there</b>"), "the benign inline tag stays")
    }

    func testSanitizeNeutralisesJavascriptLinkDestination() {
        let doc = MarkdownConverter.parse("[click me](javascript:alert(1))")
        let html = HTMLExporter.export(doc, sanitizeRawHTML: true)
        XCTAssertFalse(html.lowercased().contains("javascript:"),
                       "javascript: markdown link must be neutralised under sanitize")
        XCTAssertTrue(html.contains("<a href=\"#\">click me</a>"))
    }

    func testJavascriptLinkPreservedWhenNotSanitizing() {
        // Default fidelity mode keeps whatever the Markdown said.
        let doc = MarkdownConverter.parse("[click me](javascript:alert(1))")
        let html = HTMLExporter.export(doc)
        XCTAssertTrue(html.contains("javascript:alert(1)"))
    }

    func testSanitizePreservesBenignRawHTML() {
        let doc = MarkdownConverter.parse("<div class=\"note\"><span>ok</span></div>")
        let html = HTMLExporter.export(doc, sanitizeRawHTML: true)
        XCTAssertTrue(html.contains("<div class=\"note\"><span>ok</span></div>"),
                      "benign structural raw HTML must be preserved even when sanitizing")
    }

    func testSanitizeNeutralisesJavascriptImageDestination() {
        // HTMLExporter.renderImage neutralises a javascript: Markdown image
        // source to an empty src under sanitize (issue #4).
        let doc = MarkdownConverter.parse("![alt](javascript:alert(1))")
        let html = HTMLExporter.export(doc, sanitizeRawHTML: true)
        XCTAssertFalse(html.lowercased().contains("javascript:"),
                       "javascript: markdown image source must be neutralised under sanitize")
        XCTAssertTrue(html.contains("<img src=\"\" alt=\"alt\">"))
    }

    func testSanitizePreservesRemoteMarkdownImage() {
        // Deliberate scope: author-authored remote Markdown images stay external
        // even under sanitize (the interactive export WANTS them to resolve).
        // Pins the contract so the remote-neutralization logic can't silently
        // start dropping visible image refs.
        let doc = MarkdownConverter.parse("![r](https://example.com/x.png)")
        let html = HTMLExporter.export(doc, baseURL: nil, sanitizeRawHTML: true)
        XCTAssertTrue(html.contains("src=\"https://example.com/x.png\""),
                      "remote Markdown image must be preserved even under sanitize")
    }

    func testSanitizeLeavesGeneratedMarkdownConstructsIntact() {
        // Sanitize is raw-HTML-only: normal Markdown still exports fully.
        let doc = MarkdownConverter.parse("**bold** and `code` and a [link](https://x.com).")
        let html = HTMLExporter.export(doc, sanitizeRawHTML: true)
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<code>code</code>"))
        XCTAssertTrue(html.contains("<a href=\"https://x.com\">link</a>"))
    }
}
