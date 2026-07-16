#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

final class ZZListDiag: XCTestCase {
    func testDiag() throws {
        let src = "# Lists\n\n- first item of the list\n- second item of the list\n- third item of the list\n\nTail paragraph.\n"
        let document = MarkdownConverter.parse(src)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let list = document.blocks.first { if case .list = $0.kind { return true }; return false }!.id
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        let revealed = renderer.render(document, activeBlockID: list, activeCaret: 3, cache: &cache)
        for (name, attr) in [("read", reading.attributed), ("revl", revealed.attributed)] {
            print("LD \(name) string: \(attr.string.debugDescription)")
            let storage = NSTextStorage(attributedString: attr)
            let cs = NSTextContentStorage(); cs.textStorage = storage
            let lm = NSTextLayoutManager(); cs.addTextLayoutManager(lm)
            let tc = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
            lm.textContainer = tc
            lm.ensureLayout(for: cs.documentRange)
            lm.enumerateTextLayoutFragments(from: cs.documentRange.location) { frag in
                let r = frag.rangeInElement
                let off = cs.offset(from: cs.documentRange.location, to: r.location)
                let len = cs.offset(from: r.location, to: r.endLocation)
                let t = (attr.string as NSString).substring(with: NSRange(location: off, length: min(len, 24))).replacingOccurrences(of: "\n", with: "⏎")
                print("LD \(name) y=\(Int(frag.layoutFragmentFrame.minY))..\(Int(frag.layoutFragmentFrame.maxY)) <<\(t)>>")
                return true
            }
        }
    }
}
#endif
