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

    // MARK: - Benign HTML preserved

    func testBenignStructuralHTMLPreserved() {
        let html = "<table><tr><td><span class=\"x\"><strong>hi</strong> <em>there</em></span></td></tr></table>"
        XCTAssertEqual(HTMLSanitizer.sanitize(html), html)
    }

    func testHTMLCommentPreserved() {
        let html = "<!-- a benign comment --><p>ok</p>"
        XCTAssertEqual(HTMLSanitizer.sanitize(html), html)
    }

    func testInlineStyleAttributePreserved() {
        let html = "<span style=\"color:red\">x</span>"
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
