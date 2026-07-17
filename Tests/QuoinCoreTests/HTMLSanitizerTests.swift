import XCTest
@testable import QuoinCore

/// Unit tests for the dependency-free raw-HTML scrubber (issue #4). The
/// sanitizer is pure QuoinCore logic; these pin the allowlist policy tightly.
final class HTMLSanitizerTests: XCTestCase {

    // MARK: - Forbidden elements

    func testScriptElementAndContentRemoved() {
        let out = HTMLSanitizer.sanitize("before<script>alert('x')</script>after")
        XCTAssertEqual(out, "beforeafter")
        XCTAssertFalse(out.contains("alert"))
        XCTAssertFalse(out.lowercased().contains("script"))
    }

    func testScriptIsCaseInsensitive() {
        let out = HTMLSanitizer.sanitize("<SCRIPT>evil()</ScRiPt>ok")
        XCTAssertEqual(out, "ok")
    }

    func testStyleElementAndContentRemoved() {
        let out = HTMLSanitizer.sanitize("a<style>@import url(https://evil/x.css);</style>b")
        XCTAssertEqual(out, "ab")
    }

    func testIframeRemovedWithFallbackContent() {
        let out = HTMLSanitizer.sanitize("x<iframe src=\"https://evil\">fallback</iframe>y")
        XCTAssertEqual(out, "xy")
    }

    func testObjectAndEmbedRemoved() {
        XCTAssertEqual(HTMLSanitizer.sanitize("p<object data=\"x.swf\">alt</object>q"), "pq")
        // <embed> is a void tag: only the tag is dropped, trailing text stays.
        XCTAssertEqual(HTMLSanitizer.sanitize("p<embed src=\"x.swf\">q"), "pq")
    }

    func testUnterminatedScriptNukesRemainderNotJustTheTag() {
        // A browser would treat everything after <script> as script source, so
        // an unterminated script must take the rest of the fragment with it.
        let out = HTMLSanitizer.sanitize("safe<script>alert(1)")
        XCTAssertEqual(out, "safe")
    }

    func testUnterminatedIframeDropsOnlyTheTag() {
        // iframe does not swallow following text as script, so only the start
        // tag is dropped when there is no close.
        let out = HTMLSanitizer.sanitize("safe<iframe src=\"https://x\">tail")
        XCTAssertEqual(out, "safetail")
    }

    func testSelfClosingScriptDropsJustTheTag() {
        let out = HTMLSanitizer.sanitize("a<script/>b")
        XCTAssertEqual(out, "ab")
    }

    // MARK: - Event handlers

    func testOnEventHandlerAttributeStripped() {
        let out = HTMLSanitizer.sanitize("<div onclick=\"steal()\" class=\"c\">hi</div>")
        XCTAssertFalse(out.lowercased().contains("onclick"))
        XCTAssertFalse(out.contains("steal"))
        XCTAssertTrue(out.contains("class=\"c\""))
        XCTAssertTrue(out.contains(">hi</div>"))
    }

    func testEventHandlerCaseInsensitiveAndUnquoted() {
        let out = HTMLSanitizer.sanitize("<a OnMouseOver=alert(1) href=\"#\">t</a>")
        XCTAssertFalse(out.lowercased().contains("onmouseover"))
        XCTAssertTrue(out.contains("href=\"#\""))
    }

    // MARK: - Dangerous URL schemes

    func testJavascriptHrefStripped() {
        let out = HTMLSanitizer.sanitize("<a href=\"javascript:alert(1)\">t</a>")
        XCTAssertFalse(out.lowercased().contains("javascript:"))
        XCTAssertEqual(out, "<a>t</a>")
    }

    func testJavascriptSchemeWithEmbeddedWhitespaceStillStripped() {
        // Browsers ignore tabs/newlines when parsing the scheme.
        let out = HTMLSanitizer.sanitize("<a href=\"java\tscript:alert(1)\">t</a>")
        XCTAssertFalse(out.lowercased().contains("script:"))
    }

    func testVbscriptStripped() {
        let out = HTMLSanitizer.sanitize("<a href=\" VBScript:msgbox(1)\">t</a>")
        XCTAssertFalse(out.lowercased().contains("vbscript:"))
    }

    func testBenignHrefPreserved() {
        let out = HTMLSanitizer.sanitize("<a href=\"https://example.com/page\">t</a>")
        XCTAssertEqual(out, "<a href=\"https://example.com/page\">t</a>")
    }

    func testRelativeAndMailtoHrefPreserved() {
        XCTAssertEqual(HTMLSanitizer.sanitize("<a href=\"#anchor\">t</a>"), "<a href=\"#anchor\">t</a>")
        XCTAssertEqual(HTMLSanitizer.sanitize("<a href=\"mailto:x@y.z\">t</a>"), "<a href=\"mailto:x@y.z\">t</a>")
    }

    // MARK: - Remote resources / tracking pixels

    func testRemoteTrackingPixelSrcDropped() {
        let out = HTMLSanitizer.sanitize("<img src=\"https://tracker.example.com/p.png?id=recipient\" width=\"1\" height=\"1\">")
        XCTAssertFalse(out.contains("tracker.example.com"))
        XCTAssertFalse(out.contains("src="))
        // The inert element (with its non-URL attributes) remains.
        XCTAssertTrue(out.contains("width=\"1\""))
    }

    func testProtocolRelativeRemoteSrcDropped() {
        let out = HTMLSanitizer.sanitize("<img src=\"//tracker.example.com/p.png\">")
        XCTAssertFalse(out.contains("tracker.example.com"))
    }

    func testDataURIImagePreserved() {
        let src = "data:image/png;base64,iVBORw0KGgo="
        let out = HTMLSanitizer.sanitize("<img src=\"\(src)\" alt=\"a\">")
        XCTAssertTrue(out.contains(src))
        XCTAssertTrue(out.contains("alt=\"a\""))
    }

    func testRelativeImageSrcPreserved() {
        let out = HTMLSanitizer.sanitize("<img src=\"assets/pic.png\" alt=\"a\">")
        XCTAssertTrue(out.contains("src=\"assets/pic.png\""))
    }

    func testRemoteSrcsetDropped() {
        let out = HTMLSanitizer.sanitize("<img srcset=\"local.png 1x, https://cdn.example/big.png 2x\">")
        XCTAssertFalse(out.contains("cdn.example"))
        XCTAssertFalse(out.contains("srcset"))
    }

    func testRemoteHrefOnAnchorIsKept() {
        // A link is navigation, not an auto-load, so a remote href on <a> stays.
        let out = HTMLSanitizer.sanitize("<a href=\"https://example.com\">t</a>")
        XCTAssertTrue(out.contains("https://example.com"))
    }

    // MARK: - Remote auto-loading href / redirect vectors (issue #4 review)

    func testRemoteStylesheetLinkHrefDropped() {
        // <link rel=stylesheet href=remote> fetches the CSS on load with no
        // interaction — functionally identical to a tracking pixel.
        let out = HTMLSanitizer.sanitize("<link rel=\"stylesheet\" href=\"https://tracker.example/x.css\">")
        XCTAssertFalse(out.contains("tracker.example"))
        XCTAssertFalse(out.lowercased().contains("href"))
        XCTAssertTrue(out.contains("rel=\"stylesheet\""), "the inert <link> tag stays")
    }

    func testRemotePreloadFontLinkHrefDropped() {
        let out = HTMLSanitizer.sanitize("<link rel=\"preload\" as=\"font\" href=\"https://evil/f.woff2\">")
        XCTAssertFalse(out.contains("evil"))
    }

    func testLocalStylesheetLinkHrefKept() {
        let out = HTMLSanitizer.sanitize("<link rel=\"stylesheet\" href=\"styles/app.css\">")
        XCTAssertTrue(out.contains("href=\"styles/app.css\""))
    }

    func testRemoteBaseHrefDropped() {
        // <base href=remote> rebases every relative URL onto a remote origin.
        let out = HTMLSanitizer.sanitize("<base href=\"https://evil.com/\">")
        XCTAssertFalse(out.contains("evil.com"))
        XCTAssertFalse(out.lowercased().contains("href"))
    }

    func testRemoteSvgImageHrefDropped() {
        // SVG <image> auto-loads from href/xlink:href, not src.
        XCTAssertFalse(HTMLSanitizer.sanitize("<image href=\"https://tracker/p.png\">").contains("tracker"))
        XCTAssertFalse(HTMLSanitizer.sanitize("<image xlink:href=\"https://tracker/p.png\">").contains("tracker"))
    }

    func testMetaRefreshToRemoteURLDropped() {
        // <meta http-equiv=refresh content="0;url=remote"> auto-navigates
        // off-device with zero interaction.
        let out = HTMLSanitizer.sanitize("<meta http-equiv=\"refresh\" content=\"0;url=https://evil.com\">")
        XCTAssertFalse(out.contains("evil.com"))
        XCTAssertFalse(out.lowercased().contains("content="))
    }

    func testMetaRefreshCaseInsensitiveAndQuotedURLDropped() {
        let out = HTMLSanitizer.sanitize("<META HTTP-EQUIV=\"Refresh\" CONTENT=\"5; URL='//evil.com/x'\">")
        XCTAssertFalse(out.contains("evil.com"))
    }

    func testLocalMetaRefreshPreserved() {
        // A same-page or relative refresh never leaves the device — keep it.
        let out = HTMLSanitizer.sanitize("<meta http-equiv=\"refresh\" content=\"5\">")
        XCTAssertTrue(out.contains("content=\"5\""))
        let rel = HTMLSanitizer.sanitize("<meta http-equiv=\"refresh\" content=\"0;url=page2.html\">")
        XCTAssertTrue(rel.contains("page2.html"))
    }

    // MARK: - Dangerous navigation schemes on links (issue #4 review)

    func testDataHTMLDocumentLinkNeutralised() {
        // data:text/html navigates to a document that runs script in this origin.
        let out = HTMLSanitizer.sanitize("<a href=\"data:text/html,<script>alert(1)</script>\">x</a>")
        XCTAssertFalse(out.lowercased().contains("data:text/html"))
        XCTAssertEqual(out, "<a>x</a>")
    }

    func testDataSvgDocumentLinkNeutralised() {
        let out = HTMLSanitizer.sanitize("<a href=\"data:image/svg+xml,<svg onload='x'/>\">x</a>")
        XCTAssertFalse(out.lowercased().contains("data:image/svg"))
    }

    func testDataImageOnImgSrcStillPreserved() {
        // A data:image loaded as an <img> is inert — navigation-scheme stripping
        // must NOT touch the image allowlist.
        let png = "data:image/png;base64,iVBORw0KGgo="
        XCTAssertTrue(HTMLSanitizer.sanitize("<img src=\"\(png)\">").contains(png))
        let svg = "data:image/svg+xml;base64,PHN2Zy8+"
        XCTAssertTrue(HTMLSanitizer.sanitize("<img src=\"\(svg)\">").contains(svg))
    }

    // MARK: - Benign HTML preserved

    func testBenignStructuralHTMLPreserved() {
        let html = "<table><tr><td><span class=\"x\"><strong>hi</strong> <em>there</em></span></td></tr></table>"
        XCTAssertEqual(HTMLSanitizer.sanitize(html), html)
    }

    func testHTMLCommentPreserved() {
        let html = "<!-- a benign comment --><p>ok</p>"
        XCTAssertEqual(HTMLSanitizer.sanitize(html), html)
    }

    func testInlineStyleAttributeDropped() {
        // Sanitize mode drops `style` wholesale: inline CSS can auto-fetch
        // off-device via url(...), and detecting that reliably means parsing
        // CSS. A private export forgoes cosmetic inline styling for the
        // "fetches nothing off-device" guarantee.
        XCTAssertEqual(HTMLSanitizer.sanitize("<span style=\"color:red\">x</span>"),
                       "<span>x</span>")
    }

    func testInlineStyleRemoteURLDropped() {
        // The MEDIUM finding: a CSS background url() is a zero-interaction
        // tracking pixel. It must not survive a sanitized export.
        let out = HTMLSanitizer.sanitize(
            "<div style=\"background:url(https://tracker.example/x.png)\">hi</div>")
        XCTAssertEqual(out, "<div>hi</div>")
        XCTAssertFalse(out.contains("tracker.example"))
    }

    // MARK: - Comment-close bypasses (HIGH finding)

    func testAbruptCloseEmptyCommentDoesNotHideScript() {
        // `<!-->` is an abrupt-closed empty comment; the browser then parses
        // `<script>` as live markup. The sanitizer must close the comment at
        // the same point and strip the script.
        let out = HTMLSanitizer.sanitize("<!--><script>alert(1)</script><p>ok</p>")
        XCTAssertFalse(out.lowercased().contains("<script"))
        XCTAssertFalse(out.contains("alert(1)"))
        XCTAssertTrue(out.contains("<p>ok</p>"))
    }

    func testAbruptCloseDashEmptyCommentDoesNotHideScript() {
        let out = HTMLSanitizer.sanitize("<!---><script>alert(1)</script>done")
        XCTAssertFalse(out.lowercased().contains("<script"))
        XCTAssertFalse(out.contains("alert(1)"))
        XCTAssertTrue(out.contains("done"))
    }

    func testCommentEndBangDoesNotHideScript() {
        // `--!>` is the comment-end-bang terminator; markup after it is live.
        let out = HTMLSanitizer.sanitize("<!-- x --!><script>alert(1)</script>tail")
        XCTAssertFalse(out.lowercased().contains("<script"))
        XCTAssertFalse(out.contains("alert(1)"))
        XCTAssertTrue(out.contains("tail"))
    }

    func testUnterminatedCommentStaysInert() {
        // No terminator at all: a browser treats the rest as comment (inert),
        // so passing it through verbatim is safe — nothing executes.
        let out = HTMLSanitizer.sanitize("<!-- <script>alert(1)</script>")
        XCTAssertEqual(out, "<!-- <script>alert(1)</script>")
    }

    // MARK: - Entity-encoded scheme (LOW, but a live XSS vector)

    func testEntityEncodedJavascriptHrefDropped() {
        // A browser decodes `&#106;` → `j`, making this a live javascript: link.
        let out = HTMLSanitizer.sanitize("<a href=\"&#106;avascript:alert(1)\">x</a>")
        XCTAssertFalse(out.contains("avascript:alert"))
        XCTAssertEqual(out, "<a>x</a>")
    }

    func testHexEntityEncodedJavascriptHrefDropped() {
        let out = HTMLSanitizer.sanitize("<a href=\"&#x6a;avascript:alert(1)\">x</a>")
        XCTAssertEqual(out, "<a>x</a>")
    }

    // MARK: - SVG <use> remote reference (LOW, off-device fetch)

    func testSVGUseRemoteHrefDropped() {
        let out = HTMLSanitizer.sanitize("<use xlink:href=\"https://evil.example/x.svg#a\"/>")
        XCTAssertFalse(out.contains("evil.example"))
    }

    func testSVGUseLocalFragmentPreserved() {
        // A same-document fragment reference fetches nothing — keep it.
        let html = "<use xlink:href=\"#icon\"></use>"
        XCTAssertEqual(HTMLSanitizer.sanitize(html), html)
    }

    func testLoneAngleBracketIsLiteralText() {
        // `< 6` / `> 2` are not tag starts (no name letter follows `<`), so
        // they pass through untouched.
        XCTAssertEqual(HTMLSanitizer.sanitize("5 < 6 and 7 > 2"), "5 < 6 and 7 > 2")
    }

    func testEmptyAndPlainTextUnchanged() {
        XCTAssertEqual(HTMLSanitizer.sanitize(""), "")
        XCTAssertEqual(HTMLSanitizer.sanitize("just text"), "just text")
    }

    func testSingleQuotedAttributeRequotedNotDropped() {
        let out = HTMLSanitizer.sanitize("<a href='https://example.com'>t</a>")
        XCTAssertEqual(out, "<a href=\"https://example.com\">t</a>")
    }
}
