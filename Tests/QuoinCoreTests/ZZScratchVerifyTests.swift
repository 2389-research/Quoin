import XCTest
@testable import QuoinCore

final class ZZScratchVerifyTests: XCTestCase {

    // A: typing the byte that COMPLETES a mark inside a plain paragraph —
    // does the fast path fire, and are the suggestion ranges document-absolute?
    func testA_FastPathCreatingAMark() throws {
        let source = "Lead paragraph.\n\nalpha {+x++} tail\n"
        let previous = MarkdownConverter.parse(source)
        let insertAt = source.range(of: "{+x")!
        let offset = source.utf8.distance(from: source.utf8.startIndex,
                                          to: insertAt.lowerBound.samePosition(in: source.utf8)!) + 2
        let edit = SourceEdit(range: ByteRange(offset: offset, length: 0), replacement: "+")
        let result = try MarkdownConverter.parseAfterEdit(previous: previous, edit: edit)
        print("A strategy:", result.strategy)
        let fastMarks = SuggestionResolver.marks(in: result.document)
        let fullMarks = SuggestionResolver.marks(in: MarkdownConverter.parse(result.document.source))
        print("A fast marks:", fastMarks)
        print("A full marks:", fullMarks)
        print("A fast stats:", result.document.stats.suggestionCount,
              "full stats:", MarkdownConverter.parse(result.document.source).stats.suggestionCount)
    }

    // B: typing in a plain paragraph ABOVE a marked paragraph — do the
    // marked paragraph's suggestion ranges shift with the source?
    func testB_FastPathAboveAMarkedParagraph() throws {
        let source = "Lead paragraph here.\n\nWe {~~cannot~>can~~} ship.\n"
        let previous = MarkdownConverter.parse(source)
        let edit = SourceEdit(range: ByteRange(offset: 4, length: 0), replacement: "x")
        let result = try MarkdownConverter.parseAfterEdit(previous: previous, edit: edit)
        print("B strategy:", result.strategy)
        let fastMarks = SuggestionResolver.marks(in: result.document)
        let fullMarks = SuggestionResolver.marks(in: MarkdownConverter.parse(result.document.source))
        print("B fast marks:", fastMarks)
        print("B full marks:", fullMarks)
        if let m = fastMarks.first {
            let resolveEdit = SuggestionResolver.edit(resolving: m.range, in: result.document.source, action: .accept)
            print("B resolve with fast range:", resolveEdit as Any)
        }
    }

    // C: same as B but the stale range lands on a DIFFERENT mark → silent
    // wrong-mark resolution?
    func testC_StaleRangeHitsAnotherMark() throws {
        let source = "Leadxx para.\n\n{--aa--}{--bb--} end.\n"
        let previous = MarkdownConverter.parse(source)
        // Insert 8 bytes into the lead paragraph: stale range of the FIRST
        // mark now points at the SECOND mark's bytes.
        let edit = SourceEdit(range: ByteRange(offset: 4, length: 0), replacement: "12345678")
        let result = try MarkdownConverter.parseAfterEdit(previous: previous, edit: edit)
        print("C strategy:", result.strategy)
        let marks = SuggestionResolver.marks(in: result.document)
        print("C fast marks:", marks)
        if let m = marks.last {
            let resolveEdit = SuggestionResolver.edit(resolving: m.range, in: result.document.source, action: .accept)
            print("C resolving 'second' (bb) mark with stale range:", resolveEdit as Any)
            if let resolveEdit {
                var bytes = Array(result.document.source.utf8)
                bytes.replaceSubrange(resolveEdit.range.offset..<(resolveEdit.range.offset + resolveEdit.range.length),
                                      with: Array(resolveEdit.replacement.utf8))
                print("C after resolve:", String(decoding: bytes, as: UTF8.self))
            }
        }
    }

    // D: CRLF document — endmatter detection and critic scan.
    func testD_CRLF() throws {
        let source = "Body {++x++}{#s1} here.\r\n\r\n---\r\nsuggestions:\r\n  s1: { by: AI }\r\n"
        let document = MarkdownConverter.parse(source)
        print("D metadata:", document.reviewMetadata as Any)
        print("D marks:", SuggestionResolver.marks(in: document))
    }

    // E: front matter + endmatter in one document.
    func testE_FrontMatterPlusEndmatter() throws {
        let source = "---\ntitle: T\n---\n\nBody {++x++}{#s1} here.\n\n---\nsuggestions:\n  s1: { by: AI }\n"
        let document = MarkdownConverter.parse(source)
        print("E metadata:", document.reviewMetadata as Any)
        print("E blocks:", document.blocks.map(\.kind).map { String(describing: $0).prefix(40) })
        print("E marks:", SuggestionResolver.marks(in: document))
    }

    // F: marks in a heading — documented v1 skip; what actually happens?
    func testF_MarkInHeading() throws {
        let source = "## A {--heading--} edit\n\nBody.\n"
        let document = MarkdownConverter.parse(source)
        print("F marks:", SuggestionResolver.marks(in: document))
        print("F outline:", document.outline.map(\.title))
        guard case .heading(_, let inlines, _) = document.blocks[0].kind else { return }
        print("F heading inlines:", inlines)
    }

    // G: dollar amounts near marks — CriticScanner's crude math skip.
    func testG_CurrencyDollars() throws {
        let source = "Price was $5 but {++now $4++} today.\n"
        let document = MarkdownConverter.parse(source)
        print("G marks:", SuggestionResolver.marks(in: document))
        print("G stats:", document.stats.suggestionCount, document.stats.mathCount)
    }

    // H: id collision between comments: and suggestions: maps.
    func testH_IDCollision() throws {
        let source = "A {++x++}{#z1} b {>>note<<}{#z1}.\n\n---\ncomments:\n  z1: { by: alice }\nsuggestions:\n  z1: { by: bob }\n"
        let document = MarkdownConverter.parse(source)
        let items = SuggestionResolver.reviewItems(in: document)
        print("H items:", items.map { ($0.body, $0.by ?? "-") })
    }
}
