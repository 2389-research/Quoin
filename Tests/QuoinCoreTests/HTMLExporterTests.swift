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
}
