#if canImport(AppKit) || canImport(UIKit)
import Foundation
import CoreText
import CoreGraphics
import QuoinCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// RTF and PDF exports, produced from the same attributed rendering as the
/// screen (the element spec doubles as the print stylesheet).
public enum DocumentExporters {

    public enum ExportError: Error {
        case conversionFailed
    }

    // MARK: - RTF

    public static func rtf(from document: QuoinDocument, theme: Theme = Theme()) throws -> Data {
        let renderer = AttributedRenderer(theme: theme)
        let rendered = renderer.render(document)
        let range = NSRange(location: 0, length: rendered.attributed.length)
        guard let data = try? rendered.attributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else {
            throw ExportError.conversionFailed
        }
        return data
    }

    // MARK: - PDF

    /// US Letter with 54pt margins. On macOS, pagination runs through
    /// TextKit so image attachments (math, diagrams, pictures) draw exactly
    /// as they do on screen; the CoreText path remains for other platforms.
    public static func pdf(
        from document: QuoinDocument,
        theme: Theme? = nil,
        title: String = "Document",
        forcedAppearance: PlatformAppearance? = nil
    ) throws -> Data {
        #if canImport(AppKit)
        // A forced appearance pins dynamic colors (and the math/diagram
        // rasterizers via the theme) to light or dark output.
        let resolvedTheme = theme ?? forcedAppearance.map {
            Theme(prefersDark: $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        } ?? Theme()
        #else
        let resolvedTheme = theme ?? Theme()
        #endif
        let renderer = AttributedRenderer(theme: resolvedTheme)

        var pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 54
        let contentSize = pageRect.insetBy(dx: margin, dy: margin).size

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &pageRect, [
                kCGPDFContextTitle: title,
                kCGPDFContextCreator: "Quoin",
              ] as CFDictionary)
        else {
            throw ExportError.conversionFailed
        }

        #if canImport(AppKit)
        // Render + paginate + draw under the forced appearance so dynamic
        // colors resolve to the requested variant.
        func renderAndDraw() {
            let attributed = renderer.render(document).attributed

            // TextKit pagination: one text container per page.
            let storage = NSTextStorage(attributedString: attributed)
            let layoutManager = NSLayoutManager()
            storage.addLayoutManager(layoutManager)

            var containers: [NSTextContainer] = []
            repeat {
                let container = NSTextContainer(containerSize: contentSize)
                container.lineFragmentPadding = 0
                layoutManager.addTextContainer(container)
                containers.append(container)
                _ = layoutManager.glyphRange(for: container) // force layout
                guard containers.count < 2000 else { break }  // runaway backstop
            } while layoutManager.glyphRange(for: containers[containers.count - 1]).upperBound
                < layoutManager.numberOfGlyphs

            for container in containers {
                context.beginPDFPage(nil)
                context.saveGState()
                // TextKit draws in flipped coordinates; PDF is bottom-left.
                context.translateBy(x: margin, y: pageRect.height - margin)
                context.scaleBy(x: 1, y: -1)
                let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphicsContext
                let glyphRange = layoutManager.glyphRange(for: container)
                layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
                layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
                NSGraphicsContext.restoreGraphicsState()
                context.restoreGState()
                context.endPDFPage()
            }
        }

        if let forcedAppearance {
            forcedAppearance.performAsCurrentDrawingAppearance { renderAndDraw() }
        } else {
            renderAndDraw()
        }
        #else
        let attributed = renderer.render(document).attributed
        // CoreText pagination (attachments render as gaps; the TextKit-based
        // path arrives with the iOS app).
        let contentRect = pageRect.insetBy(dx: margin, dy: margin)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var location = 0
        let total = attributed.length
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: contentRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            location += max(visible.length, 1)
        } while location < total
        #endif

        context.closePDF()
        return data as Data
    }

    // MARK: - Print (⌘P — the system meaning, implemented not overridden)

    #if canImport(AppKit)
    /// Runs the print panel with the document paginated by an offscreen
    /// text view — the element spec doubles as the print stylesheet.
    @MainActor
    public static func runPrintOperation(for document: QuoinDocument, theme: Theme = Theme(), jobTitle: String) {
        let rendered = AttributedRenderer(theme: theme).render(document).attributed

        let printInfo = NSPrintInfo()
        printInfo.topMargin = 54
        printInfo.bottomMargin = 54
        printInfo.leftMargin = 54
        printInfo.rightMargin = 54
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false

        let contentWidth = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 1))
        textView.textStorage?.setAttributedString(rendered)
        textView.isVerticallyResizable = true
        textView.sizeToFit()

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.jobTitle = jobTitle
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }
    #endif
}
#endif
