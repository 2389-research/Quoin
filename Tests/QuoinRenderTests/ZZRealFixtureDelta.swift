#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

final class ZZRealFixtureDelta: XCTestCase {
    func testPerBlockRevealDeltas() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/renderer/02-inline-and-links.md")
        let source = try String(contentsOf: url, encoding: .utf8)
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let reading = renderer.render(document, activeBlockID: nil, activeCaret: nil, cache: &cache)
        func height(_ a: NSAttributedString) -> CGFloat {
            let s = NSTextStorage(attributedString: a)
            let cs = NSTextContentStorage(); cs.textStorage = s
            let lm = NSTextLayoutManager(); cs.addTextLayoutManager(lm)
            let tc = NSTextContainer(size: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)); lm.textContainer = tc
            lm.ensureLayout(for: cs.documentRange)
            var maxY: CGFloat = 0
            lm.enumerateTextLayoutFragments(from: cs.documentRange.location) { maxY = max(maxY, $0.layoutFragmentFrame.maxY); return true }
            return maxY
        }
        let base = height(reading.attributed)
        for block in document.blocks {
            var c2 = cache
            let revealed = renderer.render(document, activeBlockID: block.id, activeCaret: 5, cache: &c2)
            let delta = height(revealed.attributed) - base
            if abs(delta) > 20 {
                let slice = document.source.substring(in: block.range) ?? ""
                let head = slice.prefix(50).replacingOccurrences(of: "\n", with: "⏎")
                print("FD delta=\(Int(delta))pt kind=\(shortKind(block.kind)) <<\(head)>>")
            }
        }
        print("FD done base=\(Int(base))")
    }
    private func shortKind(_ k: BlockKind) -> String {
        switch k {
        case .paragraph: return "para"
        case .list: return "list"
        case .heading: return "heading"
        case .table: return "table"
        case .codeBlock: return "code"
        case .htmlBlock: return "html"
        default: return "\(k)".components(separatedBy: "(").first ?? "?"
        }
    }
}
#endif
