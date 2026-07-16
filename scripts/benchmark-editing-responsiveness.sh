#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="${1:-}"
workspace="$(mktemp -d "${TMPDIR:-/tmp}/quoin-edit-bench.XXXXXX")"
trap 'rm -rf "$workspace"' EXIT

mkdir -p "$workspace/Sources/QuoinEditBench"

cat > "$workspace/Package.swift" <<SWIFT
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "QuoinEditBench",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "Quoin", path: "$repo_root"),
    ],
    targets: [
        .executableTarget(
            name: "QuoinEditBench",
            dependencies: [
                .product(name: "QuoinCore", package: "Quoin"),
                .product(name: "QuoinRender", package: "Quoin"),
            ]
        ),
    ]
)
SWIFT

cat > "$workspace/Sources/QuoinEditBench/main.swift" <<'SWIFT'
import Foundation
import Darwin
import QuoinCore
import QuoinRender

var timings: [String: Double] = [:]

@discardableResult
func measure<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = try work()
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    timings[label] = elapsed
    print("\(label): \(String(format: "%.2f", elapsed)) ms")
    return value
}

func generatedLargeDocument() -> String {
    var out = "# Large Editing Fixture\n \n"
    var chapter = 1
    while out.utf8.count < 1_200_000 {
        out += "## Chapter \(chapter)\n \n"
        for paragraph in 1...18 {
            out += """
            Paragraph \(chapter).\(paragraph) keeps ordinary prose flowing with **bold**, *italic*, `code`, a [link](https://example.com/\(chapter)/\(paragraph)), and enough words to wrap across several visual lines in the editor. It intentionally uses whitespace-only blank lines between paragraphs, matching public-domain ebook markdown that looks blank to readers but is not represented by a literal double-newline pair.
             
            """
        }
        chapter += 1
    }
    return out
}

func isParagraph(_ block: Block) -> Bool {
    if case .paragraph = block.kind { return true }
    return false
}

let source: String
let fixturePath = CommandLine.arguments.dropFirst().first
if let fixturePath {
    source = try String(contentsOf: URL(fileURLWithPath: fixturePath), encoding: .utf8)
} else {
    source = generatedLargeDocument()
}

print("fixture: \(fixturePath ?? "generated")")
print("bytes: \(source.utf8.count)")
print("lines: \(source.split(separator: "\n", omittingEmptySubsequences: false).count)")

let document = measure("parse.initial") {
    MarkdownConverter.parse(source)
}
print("blocks: \(document.blocks.count)")
print("headings: \(document.outline.count)")

let middleBlockStart = document.blocks.count / 2
let editBlock = document.blocks.dropFirst(middleBlockStart).first(where: isParagraph)
    ?? document.blocks.prefix(middleBlockStart).reversed().first(where: isParagraph)
    ?? document.blocks[middleBlockStart]
let editBlockSource = source.substring(in: editBlock.range) ?? ""
let editBlockMidpoint = editBlockSource.index(editBlockSource.startIndex, offsetBy: editBlockSource.count / 2)
let middleUTF8 = editBlock.range.offset + editBlockSource[..<editBlockMidpoint].utf8.count
print("edit_block_bytes: \(editBlock.range.length)")

let renderer = AttributedRenderer(theme: Theme(), baseURL: nil)
var cache: [BlockID: NSAttributedString] = [:]
let rendered = measure("render.cold") {
    renderer.render(document, cache: &cache)
}
print("rendered_utf16: \(rendered.attributed.length)")
print("cache_entries: \(cache.count)")
var activeCache = cache
let activeRendered = measure("render.activateBlock") {
    renderer.render(document, activeBlockID: editBlock.id, activeCaret: nil, cache: &activeCache)
}
print("active_editable_utf16: \(activeRendered.activeEditableRange?.length ?? 0)")

let middleEdit = SourceEdit(range: ByteRange(offset: middleUTF8, length: 0), replacement: "x")
let editApplication = try measure("source.applyEdit") {
    try middleEdit.apply(to: source)
}
let editedSource = editApplication.result
let incremental = try measure("parseAfterEdit.middleInsert") {
    try MarkdownConverter.parseAfterEdit(previous: document, edit: middleEdit)
}
print("parseAfterEdit.strategy: \(incremental.strategy)")
let patchedBlock = incremental.document.blocks.first {
    $0.range.offset <= middleUTF8 && middleUTF8 <= $0.range.offset + $0.range.length
}
let patchedBlockSource = patchedBlock.flatMap { incremental.document.source.substring(in: $0.range) } ?? ""
measure("render.activeBlockPatch.fragment") {
    renderer.renderEditableSourceFragment(patchedBlockSource, caretOffset: nil)
}
let edited = measure("parse.middleInsert") {
    MarkdownConverter.parse(editedSource)
}
let active = edited.blocks.first {
    $0.range.offset <= middleUTF8 && middleUTF8 <= $0.range.offset + $0.range.length
}?.id
let rerendered = measure("render.middleInsert.warmCache") {
    renderer.render(edited, activeBlockID: active, activeCaret: nil, cache: &cache)
}

measure("render.fullStringDiffScan") {
    let old = rendered.attributed.string as NSString
    let new = rerendered.attributed.string as NSString
    let oldLen = old.length
    let newLen = new.length
    let bound = min(oldLen, newLen)
    var prefix = 0
    while prefix < bound, old.character(at: prefix) == new.character(at: prefix) {
        prefix += 1
    }
    var suffix = 0
    let suffixBound = bound - prefix
    while suffix < suffixBound,
          old.character(at: oldLen - 1 - suffix) == new.character(at: newLen - 1 - suffix) {
        suffix += 1
    }
    return prefix + suffix
}

let localThresholds: [(label: String, maxMilliseconds: Double)] = [
    ("source.applyEdit", 20),
    ("parse.initial", 750),
    ("render.cold", 250),
    ("render.activeBlockPatch.fragment", 20),
    ("parse.middleInsert", 750),
    ("render.middleInsert.warmCache", 200),
    ("render.fullStringDiffScan", 40),
]

if ProcessInfo.processInfo.environment["QUOIN_BENCH_ENFORCE"] == "1" {
    let failures = localThresholds.compactMap { threshold -> String? in
        guard let elapsed = timings[threshold.label] else {
            return "\(threshold.label): missing timing"
        }
        guard elapsed <= threshold.maxMilliseconds else {
            return "\(threshold.label): \(String(format: "%.2f", elapsed)) ms > \(String(format: "%.2f", threshold.maxMilliseconds)) ms"
        }
        return nil
    }
    if !failures.isEmpty {
        fputs("Local benchmark threshold failures:\n", stderr)
        for failure in failures {
            fputs("- \(failure)\n", stderr)
        }
        exit(1)
    }
    print("local_thresholds: pass")
} else {
    print("local_thresholds: not enforced (set QUOIN_BENCH_ENFORCE=1)")
}
SWIFT

cd "$workspace"
swift run -c release QuoinEditBench ${fixture:+"$fixture"}
