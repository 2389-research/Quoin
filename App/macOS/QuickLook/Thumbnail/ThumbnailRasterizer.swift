import CoreGraphics
import CoreText
import Foundation
import QuoinCore

/// Extension-safe thumbnail rasteriser for the Quick Look thumbnail provider
/// (issue #8).
///
/// Why this exists instead of reusing QuoinRender's `AttributedRenderer`:
/// macOS requires an app-extension — and EVERY library it links — to be built
/// `APPLICATION_EXTENSION_API_ONLY = YES`. QuoinRender touches app-only AppKit
/// (`NSApp`, print, pasteboard), so an extension cannot link it. The genuinely
/// shared, unit-tested logic (parse + `BoundedPreview` reduction + placeholder
/// policy) still runs from QuoinCore; only the final glyph draw is done here
/// with CoreText (fully extension-safe) over the SAME bounded block model.
///
/// It is deliberately a thin, single-pass projection — a stack of styled lines
/// from each block's plain text — not a second Markdown renderer: it does no
/// inline restyling, no layout of the embeds the bounded model already
/// replaced with placeholders.
enum ThumbnailRasterizer {

    /// Renders the top of the bounded document into a `size`-point card at
    /// `scale` device pixels/point. Returns nil only if the bitmap context
    /// can't be created.
    static func cgImage(for bounded: BoundedPreviewDocument, size: CGSize, scale: CGFloat) -> CGImage? {
        guard size.width > 0, size.height > 0, scale > 0 else { return nil }

        let pixelWidth = Int((size.width * scale).rounded())
        let pixelHeight = Int((size.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.scaleBy(x: scale, y: scale)

        // Paper fill.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))

        let margin = max(4, min(size.width, size.height) * 0.06)
        let inset = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)

        let attributed = attributedProjection(of: bounded, fontScale: size.height / 110.0)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        // Text frames fill from the top of the path rect downward; content
        // that overflows the card is simply not drawn (a natural crop).
        let path = CGPath(rect: inset, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)

        return context.makeImage()
    }

    // MARK: - Projection

    private static let dark = CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    private static let gray = CGColor(red: 0.34, green: 0.34, blue: 0.37, alpha: 1)
    private static let faint = CGColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1)

    /// Builds the stacked-line attributed string. `fontScale` grows type with
    /// the requested thumbnail size so a large card isn't all whitespace.
    private static func attributedProjection(of bounded: BoundedPreviewDocument, fontScale: CGFloat) -> NSAttributedString {
        let scale = max(0.7, min(fontScale, 3.0))
        let out = NSMutableAttributedString()
        appendBlocks(bounded.document.blocks, into: out, scale: scale, indent: 0)
        if out.length == 0 {
            // Blank/near-blank document: show the title-ish placeholder so the
            // card isn't an empty white square.
            appendLine("Empty document", into: out, size: 9 * scale,
                       bold: false, mono: false, color: faint, spacingAfter: 0, indent: 0)
        }
        return out
    }

    private static func appendBlocks(_ blocks: [Block], into out: NSMutableAttributedString, scale: CGFloat, indent: CGFloat) {
        for block in blocks {
            switch block.kind {
            case .heading(let level, let inlines, _):
                let size: CGFloat = level <= 1 ? 15 : level == 2 ? 12.5 : level == 3 ? 11 : 10
                appendLine(inlines.plainText, into: out, size: size * scale,
                           bold: true, mono: false, color: dark, spacingAfter: 4 * scale, indent: indent)

            case .paragraph(let inlines):
                appendLine(inlines.plainText, into: out, size: 8.5 * scale,
                           bold: false, mono: false, color: gray, spacingAfter: 5 * scale, indent: indent)

            case .codeBlock(_, let code):
                appendLine(code, into: out, size: 8 * scale,
                           bold: false, mono: true, color: gray, spacingAfter: 5 * scale, indent: indent)

            case .list(let items, let ordered, let start):
                for (offset, item) in items.enumerated() {
                    let marker = ordered ? "\(start + offset). " : "• "
                    let text = marker + item.blocks.compactMap(lineText).joined(separator: " ")
                    appendLine(text, into: out, size: 8.5 * scale,
                               bold: false, mono: false, color: gray, spacingAfter: 2 * scale, indent: indent + 8)
                }

            case .blockQuote(let children), .callout(_, let children):
                appendBlocks(children, into: out, scale: scale, indent: indent + 10)

            case .table(let header, let rows, _):
                let head = header.map { $0.inlines.plainText }.joined(separator: "  ·  ")
                appendLine(head, into: out, size: 8 * scale,
                           bold: true, mono: false, color: gray, spacingAfter: 2 * scale, indent: indent)
                for row in rows.prefix(3) {
                    let line = row.map { $0.inlines.plainText }.joined(separator: "  ·  ")
                    appendLine(line, into: out, size: 8 * scale,
                               bold: false, mono: false, color: faint, spacingAfter: 2 * scale, indent: indent)
                }

            case .thematicBreak:
                appendLine("———", into: out, size: 8 * scale,
                           bold: false, mono: false, color: faint, spacingAfter: 4 * scale, indent: indent)

            case .frontMatter, .reviewEndmatter, .tableOfContents, .htmlBlock, .diagram, .mathBlock:
                // Front/endmatter is metadata; TOC/HTML are noise at thumbnail
                // scale; mermaid/math never reach here (BoundedPreview already
                // swapped them for placeholder code blocks).
                break
            }
        }
    }

    private static func lineText(for block: Block) -> String? {
        switch block.kind {
        case .paragraph(let i), .heading(_, let i, _):
            return i.plainText
        case .codeBlock(_, let code):
            return code
        default:
            return nil
        }
    }

    private static func appendLine(
        _ raw: String, into out: NSMutableAttributedString,
        size: CGFloat, bold: Bool, mono: Bool, color: CGColor,
        spacingAfter: CGFloat, indent: CGFloat
    ) {
        let text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let name: CFString = mono ? "Menlo" as CFString
            : (bold ? "HelveticaNeue-Bold" as CFString : "HelveticaNeue" as CFString)
        let font = CTFontCreateWithName(name, size, nil)

        let paragraph = paragraphStyle(spacingAfter: spacingAfter, indent: indent)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        out.append(NSAttributedString(string: text + "\n", attributes: attrs))
    }

    private static func paragraphStyle(spacingAfter: CGFloat, indent: CGFloat) -> CTParagraphStyle {
        var spacing = spacingAfter
        var head = indent
        var mode = CTLineBreakMode.byTruncatingTail
        // The setting `value` pointers must stay valid for the whole
        // CTParagraphStyleCreate call, so build the array and create the style
        // INSIDE the nested pointer scopes — never after they return.
        return withUnsafeMutablePointer(to: &spacing) { sp in
            withUnsafeMutablePointer(to: &head) { hp in
                withUnsafeMutablePointer(to: &mode) { mp in
                    let settings = [
                        CTParagraphStyleSetting(spec: .paragraphSpacing,
                                                valueSize: MemoryLayout<CGFloat>.size, value: sp),
                        CTParagraphStyleSetting(spec: .headIndent,
                                                valueSize: MemoryLayout<CGFloat>.size, value: hp),
                        CTParagraphStyleSetting(spec: .firstLineHeadIndent,
                                                valueSize: MemoryLayout<CGFloat>.size, value: hp),
                        CTParagraphStyleSetting(spec: .lineBreakMode,
                                                valueSize: MemoryLayout<CTLineBreakMode>.size, value: mp),
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
    }
}
