#if canImport(AppKit)
import XCTest
import AppKit
import Metal
import QuartzCore
import QuoinCore
@testable import QuoinRender

/// Pixel fidelity for the flip motion overlay: a frozen slice must show
/// EXACTLY the pixels of the region it covers, upright.
///
/// Verified through CARenderer — the REAL compositor — because
/// `CALayer.render(in:)` is a trap here: it reads back in CG bottom-up
/// space and re-interprets `contentsRect` with a bottom origin, so it
/// disagrees with the screen in exactly the ways this test exists to
/// catch (trusting it once produced a "fix" that was mirrored on the
/// actual screen; a CARenderer probe settled the truth: contents and
/// contentsRect are top-origin as displayed). A wrong recipe fails here
/// as either a mirrored band (staircase fixture) or the wrong band
/// entirely — both crater the match ratio.
@MainActor
final class FlipTransitionFidelityTests: XCTestCase {

    func testFrozenSliceIsUprightAndRegistered() throws {
        // Stack in a real (offscreen) window.
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 0), textContainer: container)
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.orderOut(nil) }

        // STRONGLY vertically asymmetric content: a staircase of bullets
        // plus the line number, so every line's ink pattern differs and a
        // mirrored or shifted snapshot cannot score a near-match (uniform
        // "Line N — same words" lines once matched 92% mirrored). Tall
        // enough (300 lines) that the capture overscan region exists on
        // any runner's font metrics.
        var text = ""
        for i in 0..<300 {
            text += String(repeating: "▌", count: i % 13) + " Line \(i) marker \(String(i, radix: 2))\n"
        }
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.textContentStorage?.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.black,
            ]))
        textView.textLayoutManager?.ensureLayout(for: contentStorage.documentRange)
        textView.sizeToFit()
        window.layoutIfNeeded()
        textView.displayIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)

        // Capture + mount slices for a large-delta flip. Reduce Motion is
        // pinned OFF: CI runners report it ON, which legitimately switches
        // the plan to a full-viewport crossfade (covered separately below)
        // and mounts a different overlay than this test dissects.
        let controller = FlipTransitionController(scrollView: scroll, textView: textView)
        controller.reduceMotionOverride = false
        let oldBlockRect = CGRect(x: 0, y: 100, width: 600, height: 150)
        controller.capture(oldBlockRect: oldBlockRect)
        controller.run(newBlockRect: CGRect(x: 0, y: 100, width: 600, height: 40),
                       documentLength: 1_000)
        let overlayContainer = try XCTUnwrap(
            scroll.subviews.first { String(describing: type(of: $0)).contains("OverlayContainer") },
            "slices must mount in the same transaction as the splice")
        // Environment forensics for headless runners (frames tell which
        // slice failed to mount and why).
        print("FLIPFIDELITY slices=\(overlayContainer.subviews.map(\.frame)) "
            + "visible=\(scroll.contentView.documentVisibleRect) "
            + "bounds=\(textView.bounds) scale=\(window.backingScaleFactor)")
        XCTAssertEqual(overlayContainer.subviews.count, 2, "block slice + below slice")

        // Orientation ANCHOR: an NSImageView showing a known image (RED
        // top half, BLUE bottom half), mounted alongside the slices.
        // NSImageView displays upright in any hierarchy, so wherever the
        // red lands in the compositor readout defines which texture row
        // order corresponds to the screen — no coordinate-system lore.
        let anchorImage: CGImage = try {
            let ctx = try XCTUnwrap(CGContext(
                data: nil, width: 20, height: 40, bitsPerComponent: 8,
                bytesPerRow: 20 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))   // CG bottom = image bottom
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 20, width: 20, height: 20))  // CG top = image top
            return try XCTUnwrap(ctx.makeImage())
        }()
        let anchor = NSImageView(frame: NSRect(x: 570, y: 0, width: 20, height: 40))
        anchor.image = NSImage(cgImage: anchorImage, size: NSSize(width: 20, height: 40))
        anchor.imageScaling = .scaleAxesIndependently
        overlayContainer.addSubview(anchor)

        window.display() // commit the layer tree

        // Render the overlay container with the real compositor.
        let width = Int(overlayContainer.bounds.width)
        let containerHeight = Int(overlayContainer.bounds.height)
        let height = Int(oldBlockRect.height)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device — compositor fidelity needs CARenderer")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: containerHeight, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let containerLayer = try XCTUnwrap(overlayContainer.layer)
        let carenderer = CARenderer(mtlTexture: texture, options: nil)
        carenderer.layer = containerLayer
        carenderer.bounds = containerLayer.bounds
        // BGRA readout; row order calibrated by the assertions below (the
        // correct recipe must match under exactly one order).
        var overlayBytes = [UInt8](repeating: 0, count: width * containerHeight * 4)
        func renderOverlayReadout() {
            CATransaction.flush()
            carenderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            carenderer.addUpdate(containerLayer.bounds)
            carenderer.render()
            carenderer.endFrame()
            texture.getBytes(&overlayBytes, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, containerHeight), mipmapLevel: 0)
        }
        // The anchor doubles as a frame-validity probe: a readout where
        // NEITHER of its rows is red is a blank frame — the layer-tree
        // commit lost a race with the compositor readback (seen
        // sporadically under machine load; the same binary passes on
        // rerun). Retry the commit+readback; the fidelity assertions
        // below are untouched, so a genuinely mirrored or misregistered
        // slice still fails every attempt.
        func anchorRedness(atTextureRow row: Int) -> Int {
            var red = 0
            for col in 572..<588 {
                let i = (row * width + col) * 4
                red += Int(overlayBytes[i + 2]) - Int(overlayBytes[i]) // R - B of BGRA
            }
            return red
        }
        for attempt in 0..<4 {
            renderOverlayReadout()
            if anchorRedness(atTextureRow: 8) > 800 || anchorRedness(atTextureRow: 32) > 800 { break }
            print("FLIPFIDELITY blank compositor readback, attempt \(attempt) — retrying")
            window.display()
            // Thread.sleep, NEVER RunLoop.run: run() defers the fade/slide
            // to the next runloop turn, so draining the loop here STARTED
            // them — the retry then measured through a mid-flight slide
            // (below-content rows moving into the band → the sporadic
            // 0.55-correlation "flake"). Sleeping gives the compositor its
            // beat while the animations stay queued.
            Thread.sleep(forTimeInterval: 0.05)
        }

        // Tripwire: the readback must measure the MOUNTED, pre-animation
        // state. If any slice has begun fading or sliding, some path drained
        // the runloop — fail with the mechanism, not a correlation number.
        XCTAssertTrue(overlayContainer.subviews.allSatisfy { $0.alphaValue == 1 },
                      "readback must precede the fade — a drained runloop started the animations")

        // Ground truth for the same document region, straight from the
        // bitmap rep (row 0 = rect top, unambiguous).
        let visible = scroll.contentView.documentVisibleRect
        let documentRect = CGRect(
            x: visible.minX, y: visible.minY + oldBlockRect.minY,
            width: oldBlockRect.width, height: oldBlockRect.height)
        let rep = try XCTUnwrap(textView.bitmapImageRepForCachingDisplay(in: documentRect))
        textView.cacheDisplay(in: documentRect, to: rep)
        let repData = try XCTUnwrap(rep.bitmapData)
        let repScale = rep.pixelsWide / width
        XCTAssertGreaterThanOrEqual(repScale, 1)

        // Per-row INK PROFILES rather than per-pixel equality: the overlay
        // path composites a 2× capture into a 1× texture, so exact bytes
        // differ by resampling — but the staircase fixture's row-by-row
        // ink signature survives any blur, and a mirrored or mis-selected
        // band decorrelates it completely.
        func overlayRowInk(contentRowsInverted: Bool) -> [Double] {
            (0..<height).map { row in
                // Element POSITIONS read straight in the texture; only the
                // content within each element may read inverted (the
                // anchor calibrates which).
                let bandRow = contentRowsInverted ? (height - 1 - row) : row
                let textureRow = Int(oldBlockRect.minY) + bandRow
                var ink = 0.0
                for col in 0..<width {
                    ink += 255.0 - Double(overlayBytes[(textureRow * width + col) * 4 + 2]) // R of BGRA
                }
                return ink
            }
        }
        let referenceRowInk: [Double] = (0..<height).map { row in
            var ink = 0.0
            for col in 0..<width {
                let refIndex = (row * repScale * rep.bytesPerRow)
                    + (col * repScale * (rep.bitsPerPixel / 8))
                ink += 255.0 - Double(repData[refIndex])
            }
            return ink
        }
        func correlation(_ a: [Double], _ b: [Double]) -> Double {
            let n = Double(a.count)
            let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
            var cov = 0.0, va = 0.0, vb = 0.0
            for i in a.indices {
                cov += (a[i] - ma) * (b[i] - mb)
                va += (a[i] - ma) * (a[i] - ma)
                vb += (b[i] - mb) * (b[i] - mb)
            }
            let denominator = (va * vb).squareRoot()
            return denominator > 0 ? cov / denominator : 0
        }

        // Calibrate WITHIN-ELEMENT content orientation from the anchor.
        // The anchor is an NSImageView — definitionally upright on screen
        // with its RED half at the visual top of its frame (texture rows
        // 0..20 of the band at container rows 0..40; positions read
        // straight). If the texture shows red at the band's BOTTOM
        // instead, this readout inverts content within each element, and
        // a screen-upright slice must be compared bottom-up.
        let anchorTopIsRed = anchorRedness(atTextureRow: 8) > 800
        let anchorBottomIsRed = anchorRedness(atTextureRow: 32) > 800
        XCTAssertNotEqual(anchorTopIsRed, anchorBottomIsRed,
                          "anchor must disambiguate the content row order")
        let contentRowsInverted = anchorBottomIsRed

        // Under the calibrated (screen) orientation, the slice must
        // reproduce its region — upright. A mirrored recipe (this shipped
        // during development, twice, in both directions) reads the
        // staircase backwards and decorrelates; a wrong-band recipe
        // matches nothing at all.
        let uprightCorrelation = correlation(
            overlayRowInk(contentRowsInverted: contentRowsInverted), referenceRowInk)
        XCTAssertGreaterThan(uprightCorrelation, 0.97,
                             "the frozen slice must reproduce its region upright on screen " +
                             "(row-ink correlation \(uprightCorrelation))")

        controller.cancel()
        XCTAssertTrue(scroll.subviews.allSatisfy {
            !String(describing: type(of: $0)).contains("OverlayContainer")
        }, "cancel must remove the cover")
    }

    /// Reduce Motion collapses every flip to a single full-viewport
    /// crossfade cover — discovered as a CI-runner surprise (headless
    /// runners report it ON) and pinned here as intended behavior.
    func testReduceMotionMountsASingleFullViewportCover() throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        scroll.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.orderOut(nil) }
        textView.textContentStorage?.textStorage?.setAttributedString(
            NSAttributedString(string: String(repeating: "content line\n", count: 100)))

        let controller = FlipTransitionController(scrollView: scroll, textView: textView)
        controller.reduceMotionOverride = true
        controller.capture(oldBlockRect: CGRect(x: 0, y: 100, width: 600, height: 150))
        controller.run(newBlockRect: CGRect(x: 0, y: 100, width: 600, height: 40),
                       documentLength: 1_000)

        let container = try XCTUnwrap(scroll.subviews.first {
            String(describing: type(of: $0)).contains("OverlayContainer")
        })
        XCTAssertEqual(container.subviews.count, 1, "one cover, no slices")
        let cover = try XCTUnwrap(container.subviews.first)
        XCTAssertEqual(cover.frame.height, scroll.contentView.bounds.height, accuracy: 1,
                       "the cover spans the viewport")
        controller.cancel()
    }

    func testCancelRemovesTheCoverUnconditionally() throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let textView = QuoinTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        scroll.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.orderOut(nil) }
        textView.textContentStorage?.textStorage?.setAttributedString(
            NSAttributedString(string: String(repeating: "x\n", count: 200)))

        let controller = FlipTransitionController(scrollView: scroll, textView: textView)
        controller.capture(oldBlockRect: CGRect(x: 0, y: 50, width: 600, height: 200))
        controller.run(newBlockRect: CGRect(x: 0, y: 50, width: 600, height: 60),
                       documentLength: 1_000)
        controller.cancel()
        XCTAssertTrue(scroll.subviews.allSatisfy {
            !String(describing: type(of: $0)).contains("OverlayContainer")
        })
    }
}
#endif
