#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

final class ZZHR2: XCTestCase {
    func testDiag() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/renderer/01-headings.md")
        let source = try String(contentsOf: url, encoding: .utf8)
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let hr = document.blocks.last { if case .thematicBreak = $0.kind { return true }; return false }!
        print("H2 slice=\((document.source.substring(in: hr.range) ?? "").debugDescription)")
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        var c2 = cache
        let revealed = renderer.render(document, activeBlockID: hr.id, activeCaret: 0, cache: &c2)
        for (name, attr, ranges) in [("read", reading.attributed, reading.blockRanges), ("revl", revealed.attributed, revealed.blockRanges)] {
            let r = ranges[hr.id]!
            let ctx = NSRange(location: max(0, r.location - 2), length: min(attr.length - max(0, r.location - 2), r.length + 8))
            print("H2 \(name) blockRange=\(r) text=\((attr.string as NSString).substring(with: ctx).debugDescription)")
            var loc = ctx.location
            while loc < NSMaxRange(ctx) {
                var er = NSRange()
                let st = attr.attribute(.paragraphStyle, at: loc, effectiveRange: &er) as? NSParagraphStyle
                let f = attr.attribute(.font, at: loc, effectiveRange: nil) as? NSFont
                let t = (attr.string as NSString).substring(with: NSIntersectionRange(er, ctx)).prefix(12).replacingOccurrences(of: "\n", with: "⏎")
                print("H2 \(name) @\(er.location),\(er.length) font=\(Int(f?.pointSize ?? -1)) lhm=\(st?.lineHeightMultiple ?? -1) b=\(Int(st?.paragraphSpacingBefore ?? -1)) a=\(Int(st?.paragraphSpacing ?? -1)) max=\(Int(st?.maximumLineHeight ?? -1)) <<\(t)>>")
                loc = NSMaxRange(er)
            }
        }
    }
}
#endif
