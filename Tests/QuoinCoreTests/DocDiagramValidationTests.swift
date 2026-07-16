import XCTest
@testable import QuoinCore

/// Every Mermaid diagram embedded in the project's Markdown docs must actually
/// render in Quoin — the docs dogfood the engine, so a diagram that falls back
/// to a source card (or shows a literal `\n`) is a visible defect on the public
/// repo. This test extracts every ```mermaid block from README.md and docs/**
/// and drives it through the SAME parser Quoin uses (`MermaidParser`, from
/// MermaidKit), failing with the file, line, and reason for any that don't
/// parse to a supported diagram. It also lints for literal `\n`, which Mermaid
/// renders as text rather than a line break (the correct break is `<br/>`).
final class DocDiagramValidationTests: XCTestCase {

    private struct Block { let file: String; let line: Int; let source: String }

    /// Repo root, derived from this file's location: <root>/Tests/QuoinCoreTests/<this>.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // QuoinCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // root
    }

    private func markdownFiles() -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        let readme = repoRoot.appendingPathComponent("README.md")
        if fm.fileExists(atPath: readme.path) { files.append(readme) }
        let docs = repoRoot.appendingPathComponent("docs")
        if let e = fm.enumerator(at: docs, includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.pathExtension == "md" {
                files.append(url)
            }
        }
        return files
    }

    private func mermaidBlocks(in url: URL) -> [Block] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let rel = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
        var blocks: [Block] = []
        var inBlock = false
        var start = 0
        var buffer: [String] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let stripped = raw.drop { $0 == " " || $0 == "\t" }
            if !inBlock, stripped.hasPrefix("```mermaid") {
                inBlock = true; start = i + 1; buffer = []
            } else if inBlock, stripped.hasPrefix("```") {
                blocks.append(Block(file: rel, line: start, source: buffer.joined(separator: "\n")))
                inBlock = false
            } else if inBlock {
                buffer.append(raw)
            }
        }
        return blocks
    }

    func testEveryDocMermaidDiagramParses() throws {
        let files = markdownFiles()
        XCTAssertFalse(files.isEmpty, "found no markdown files under \(repoRoot.path)")

        var blocks: [Block] = []
        for f in files { blocks.append(contentsOf: mermaidBlocks(in: f)) }
        XCTAssertGreaterThan(blocks.count, 0, "expected to find embedded mermaid diagrams")

        var failures: [String] = []
        for b in blocks {
            if b.source.contains("\\n") {
                failures.append("\(b.file):\(b.line) — literal `\\n` in a label (use `<br/>` for a line break)")
            }
            if MermaidParser.parse(b.source) == nil {
                let head = b.source.split(separator: "\n").first.map(String.init) ?? ""
                failures.append("\(b.file):\(b.line) — does not parse/render natively (falls back to a source card). First line: \(head)")
            }
        }

        if !failures.isEmpty {
            XCTFail("\(failures.count) embedded diagram issue(s):\n  - " + failures.joined(separator: "\n  - "))
        }
    }
}
