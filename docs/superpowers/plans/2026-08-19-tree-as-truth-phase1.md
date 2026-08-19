# Tree-as-Truth Editing — Phase 1 (Model + Serializer + Edit Core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the platform-free, Linux-testable editing core — a mutable
block-segment document model with per-block source retention, a byte-lossless
span-retaining serializer, a structural caret, and the pure Return=split /
Backspace=join / insert / delete transforms — that eliminates the string-as-truth
bug class by construction.

**Architecture:** An `EditableDocument` is an ordered list of segments — trivia
(whitespace/blank-lines between blocks) and blocks (each carrying its editable
source text, its kind, its original source span, and a pristine flag). It is
built from a parsed `QuoinDocument` (the Phase 0 span decomposition, now
mutable). Serialization concatenates segments: a pristine block re-emits its
original bytes verbatim (byte-lossless); an edited block emits its live text.
Edits are pure transforms returning a structural caret `EditPosition(NodeID,
offset)` that cannot desync from bytes. No UI, no TextKit, no byte-offset caret.

**Tech Stack:** Swift 6 (QuoinCore, strict concurrency, MUST build+test on
Linux — no AppKit/UIKit), swift-markdown/cmark (existing parser), XCTest.

**Spec:** `docs/superpowers/specs/2026-08-19-tree-as-truth-editing-design.md`
— read it first; this plan implements its Phase 1.

## Global Constraints

- `QuoinCore` is Swift 6 strict-concurrency and **MUST build and test on Linux** —
  no AppKit/UIKit/SwiftUI imports anywhere in this plan. Types are `Sendable`.
- **On-disk format is never changed.** The tree is in-memory only: parse to it,
  serialize from it. This plan does not touch save/load.
- **No new third-party dependency.** swift-markdown/cmark stays the parser; the
  model and serializer are ours.
- **Byte-losslessness is the non-negotiable invariant.** For any document and any
  edit sequence, every byte OUTSIDE edited blocks must be byte-identical to the
  original. This is enforced by fuzz tests, not asserted.
- CRLF: Swift treats `\r\n` as ONE grapheme; all offset math is on UTF-8 **bytes**
  or explicit UTF-16 units, never `Character` counts across line endings.
- Existing model types (verbatim): `QuoinDocument { let source: String; let blocks: [Block]; let footnotes: [Footnote] }`;
  `Block { let kind: BlockKind; let range: ByteRange }`; `ByteRange { let offset: Int; let length: Int }`;
  `MarkdownConverter.parse(_ source: String) -> QuoinDocument`.
- Commit after every task and push to `main` (user directive).
- Package tests: `swift test` at repo root.

## File Structure

**Created (all under `Sources/QuoinCore/EditableDocument/`):**
- `NodeID.swift` — a stable, non-content-hashed identity for blocks.
- `EditableDocument.swift` — the segment model (`Segment`, `EditableBlock`,
  `EditableDocument`) + `build(from:)`.
- `EditableSerializer.swift` — `EditableDocument.serialized()` (span-retaining).
- `EditPosition.swift` — the structural caret.
- `EditTransforms.swift` — `insertText`, `deleteRange`, `splitBlock`,
  `joinWithPrevious`.

**Created (tests, under `Tests/QuoinCoreTests/EditableDocument/`):**
- `EditableDocumentBuildTests.swift`
- `EditableSerializerTests.swift` (+ the byte-lossless corpus fuzz)
- `EditPositionTests.swift`
- `EditTransformInsertDeleteTests.swift`
- `EditTransformSplitTests.swift`
- `EditTransformJoinTests.swift`
- `EditFidelityFuzzTests.swift` (round-trip + untouched-region fuzz)

**Modified:** none (Phase 1 is purely additive; the old path is untouched).

---

### Task 1: `NodeID` and the `EditableDocument` segment model

**Files:**
- Create: `Sources/QuoinCore/EditableDocument/NodeID.swift`
- Create: `Sources/QuoinCore/EditableDocument/EditableDocument.swift`
- Test: `Tests/QuoinCoreTests/EditableDocument/EditableDocumentBuildTests.swift`

**Interfaces:**
- Consumes: `QuoinDocument`, `Block`, `BlockKind`, `ByteRange`, `MarkdownConverter.parse`.
- Produces:
  - `struct NodeID: Hashable, Sendable` with `static func fresh() -> NodeID`.
  - `struct EditableBlock: Sendable { let id: NodeID; var kind: BlockKind; var text: String; var sourceSpan: Range<Int>?; var pristine: Bool }`
  - `enum Segment: Sendable { case trivia(String); case block(EditableBlock) }`
  - `struct EditableDocument: Sendable { var segments: [Segment]; static func build(from doc: QuoinDocument) -> EditableDocument; static func build(parsing source: String) -> EditableDocument }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuoinCore

final class EditableDocumentBuildTests: XCTestCase {

    /// The segment model mirrors the Phase 0 decomposition: leading trivia, then
    /// alternating block/trivia. A pristine block carries its exact source text
    /// and span.
    func testBuildDecomposesIntoTriviaAndBlocks() {
        let doc = EditableDocument.build(parsing: "# H\n\nBody\n")
        // Blocks in order with their exact source text.
        let blocks = doc.segments.compactMap { seg -> EditableBlock? in
            if case .block(let b) = seg { return b } else { return nil }
        }
        XCTAssertEqual(blocks.map(\.text), ["# H", "Body"])
        XCTAssertTrue(blocks.allSatisfy(\.pristine))
        // Every block has a source span equal to its text.
        for b in blocks {
            XCTAssertNotNil(b.sourceSpan)
        }
    }

    /// Distinct blocks get distinct identities.
    func testBlocksHaveDistinctIdentities() {
        let doc = EditableDocument.build(parsing: "a\n\nb\n\nc")
        let ids = doc.segments.compactMap { seg -> NodeID? in
            if case .block(let b) = seg { return b.id } else { return nil }
        }
        XCTAssertEqual(Set(ids).count, 3)
    }

    /// Leading and trailing trivia are preserved as segments.
    func testLeadingAndTrailingTriviaPreserved() {
        let doc = EditableDocument.build(parsing: "\n\n# H\n\n")
        guard case .trivia(let lead)? = doc.segments.first else {
            return XCTFail("expected leading trivia")
        }
        XCTAssertEqual(lead, "\n\n")
        guard case .trivia(let tail)? = doc.segments.last else {
            return XCTFail("expected trailing trivia")
        }
        XCTAssertEqual(tail, "\n\n")
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter EditableDocumentBuildTests`
Expected: FAIL — `cannot find 'EditableDocument' in scope`.

- [ ] **Step 3: Implement `NodeID`**

```swift
import Foundation

/// A stable identity for an editable block. NOT content-hashed (unlike
/// `BlockID`): it must survive edits to the block's own content, so split/join
/// and caret tracking can follow a block as its text changes.
public struct NodeID: Hashable, Sendable {
    private let raw: UInt64

    private init(raw: UInt64) { self.raw = raw }

    /// A process-unique counter. Deterministic within a run (no `Date`/random —
    /// which are also unavailable to some sandboxes), monotonic, thread-safe.
    private static let counter = Counter()

    public static func fresh() -> NodeID { NodeID(raw: counter.next()) }

    private final class Counter: @unchecked Sendable {
        private var value: UInt64 = 0
        private let lock = NSLock()
        func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }
}
```

- [ ] **Step 4: Implement the segment model + build**

```swift
import Foundation

public struct EditableBlock: Sendable {
    public let id: NodeID
    public var kind: BlockKind
    /// The block's editable source text (its exact bytes when pristine).
    public var text: String
    /// The file byte range this block was parsed from; nil once it is born or
    /// re-homed in-editor.
    public var sourceSpan: Range<Int>?
    /// False once this block's text has been edited — a pristine block
    /// re-serializes verbatim from `text` (which still equals the source).
    public var pristine: Bool

    public init(id: NodeID, kind: BlockKind, text: String, sourceSpan: Range<Int>?, pristine: Bool) {
        self.id = id; self.kind = kind; self.text = text
        self.sourceSpan = sourceSpan; self.pristine = pristine
    }
}

public enum Segment: Sendable {
    case trivia(String)
    case block(EditableBlock)
}

public struct EditableDocument: Sendable {
    public var segments: [Segment]

    public init(segments: [Segment]) { self.segments = segments }

    public static func build(parsing source: String) -> EditableDocument {
        build(from: MarkdownConverter.parse(source))
    }

    /// The Phase 0 span decomposition, made mutable. Every byte of
    /// `doc.source` lands in exactly one segment: leading trivia, then each
    /// top-level block with the trivia that follows it.
    public static func build(from doc: QuoinDocument) -> EditableDocument {
        let source = doc.source
        // Work in UTF-8 byte space to match ByteRange; slice via a byte view.
        let bytes = Array(source.utf8)
        func slice(_ range: Range<Int>) -> String {
            String(decoding: bytes[range], as: UTF8.self)
        }
        let ordered = doc.blocks
            .map { $0.range }
            .sorted { $0.offset < $1.offset }
        var segments: [Segment] = []
        var cursor = 0
        for r in ordered {
            let start = r.offset
            let end = r.offset + r.length
            if start > cursor {
                segments.append(.trivia(slice(cursor..<start)))
            }
            let text = slice(start..<end)
            // Recover the kind by matching the block at this offset.
            let kind = doc.blocks.first { $0.range.offset == start }?.kind ?? .paragraph(inlines: [])
            segments.append(.block(EditableBlock(
                id: .fresh(), kind: kind, text: text, sourceSpan: start..<end, pristine: true)))
            cursor = end
        }
        if cursor < bytes.count {
            segments.append(.trivia(slice(cursor..<bytes.count)))
        }
        return EditableDocument(segments: segments)
    }
}
```

- [ ] **Step 5: Run the test**

Run: `swift test --filter EditableDocumentBuildTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/QuoinCore/EditableDocument/NodeID.swift Sources/QuoinCore/EditableDocument/EditableDocument.swift Tests/QuoinCoreTests/EditableDocument/EditableDocumentBuildTests.swift
git commit -m "Tree-as-truth Phase 1: EditableDocument segment model + build-from-parse"
git push origin main
```

---

### Task 2: The span-retaining serializer + byte-lossless corpus fuzz

**Files:**
- Create: `Sources/QuoinCore/EditableDocument/EditableSerializer.swift`
- Test: `Tests/QuoinCoreTests/EditableDocument/EditableSerializerTests.swift`

**Interfaces:**
- Consumes: `EditableDocument`, `Segment`, `EditableBlock`.
- Produces: `func EditableDocument.serialized() -> String`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuoinCore

final class EditableSerializerTests: XCTestCase {

    /// The core invariant: build → serialize is byte-identical to the source,
    /// across the same corpus Phase 0 validated (fixtures + edge cases). This is
    /// the same proof, now through the real mutable model.
    func testSerializeRoundTripIsByteIdenticalOverCorpus() {
        for (name, source) in Self.corpus() {
            let rebuilt = EditableDocument.build(parsing: source).serialized()
            XCTAssertEqual(Array(rebuilt.utf8), Array(source.utf8),
                           "\(name): build → serialize is NOT byte-identical")
        }
    }

    /// A trivially small, explicit case.
    func testSerializeSmallDocument() {
        let s = "# H\n\nBody\n"
        XCTAssertEqual(EditableDocument.build(parsing: s).serialized(), s)
    }

    // Shared corpus: repo fixtures + the pathological edge cases from Phase 0.
    static func corpus() -> [(String, String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let fixtures = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "md" }
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) } } ?? []
        let edges: [(String, String)] = [
            ("empty", ""), ("blank-only", "\n\n\n"), ("crlf", "# H\r\n\r\nA.\r\n"),
            ("no-trailing", "# H"), ("many-trailing", "x\n\n\n\n\n"),
            ("front-matter", "---\ntitle: Hi\n---\n\n# B\n"),
            ("footnote", "A.[^1]\n\n[^1]: def.\n"), ("nested-list", "- a\n  - b\n- c\n"),
            ("table", "| a | b |\n| - | - |\n| 1 | 2 |\n"),
            ("fenced", "```swift\nlet x = 1\n```\n"), ("quote", "> a\n> b\n"),
            ("unicode", "# café ☕️\n\nrésumé\n"), ("html", "<div>\n x\n</div>\n\nt\n"),
        ]
        return fixtures + edges
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter EditableSerializerTests`
Expected: FAIL — `value of type 'EditableDocument' has no member 'serialized'`.

- [ ] **Step 3: Implement the serializer**

```swift
public extension EditableDocument {
    /// Concatenate the segments. A pristine block re-emits its retained source
    /// bytes verbatim (byte-lossless); an edited block emits its live `text`.
    /// Trivia is emitted verbatim. (For Phase 1 a block's `text` IS its source
    /// slice whether pristine or edited, so this is a plain concatenation; the
    /// `pristine` distinction becomes load-bearing in Phase 1's later
    /// inline-canonicalization work and is kept explicit here so that hook
    /// exists.)
    func serialized() -> String {
        var out = ""
        out.reserveCapacity(segments.reduce(0) { acc, seg in
            switch seg {
            case .trivia(let t): return acc + t.utf8.count
            case .block(let b): return acc + b.text.utf8.count
            }
        })
        for seg in segments {
            switch seg {
            case .trivia(let t): out += t
            case .block(let b): out += b.text
            }
        }
        return out
    }
}
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter EditableSerializerTests`
Expected: PASS. The corpus fuzz proves byte-losslessness through the model.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuoinCore/EditableDocument/EditableSerializer.swift Tests/QuoinCoreTests/EditableDocument/EditableSerializerTests.swift
git commit -m "Tree-as-truth Phase 1: span-retaining serializer + byte-lossless corpus fuzz"
git push origin main
```

---

### Task 3: The structural caret `EditPosition`

**Files:**
- Create: `Sources/QuoinCore/EditableDocument/EditPosition.swift`
- Test: `Tests/QuoinCoreTests/EditableDocument/EditPositionTests.swift`

**Interfaces:**
- Consumes: `EditableDocument`, `NodeID`, `EditableBlock`.
- Produces:
  - `struct EditPosition: Hashable, Sendable { let block: NodeID; let offsetUTF16: Int }`
  - `func EditableDocument.blockIndex(of: NodeID) -> Int?`
  - `func EditableDocument.block(_ id: NodeID) -> EditableBlock?`
  - `func EditableDocument.isValid(_ pos: EditPosition) -> Bool`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuoinCore

final class EditPositionTests: XCTestCase {

    private func firstBlockID(_ d: EditableDocument) -> NodeID {
        for s in d.segments { if case .block(let b) = s { return b.id } }
        fatalError("no block")
    }

    func testValidPositionInsideBlock() {
        let d = EditableDocument.build(parsing: "Hello\n\nWorld")
        let id = firstBlockID(d)
        XCTAssertTrue(d.isValid(EditPosition(block: id, offsetUTF16: 0)))
        XCTAssertTrue(d.isValid(EditPosition(block: id, offsetUTF16: 5)))   // end of "Hello"
    }

    func testOffsetPastBlockEndIsInvalid() {
        let d = EditableDocument.build(parsing: "Hello\n\nWorld")
        let id = firstBlockID(d)
        XCTAssertFalse(d.isValid(EditPosition(block: id, offsetUTF16: 6)))
    }

    func testUnknownBlockIsInvalid() {
        let d = EditableDocument.build(parsing: "Hello")
        XCTAssertFalse(d.isValid(EditPosition(block: .fresh(), offsetUTF16: 0)))
    }

    func testBlockLookup() {
        let d = EditableDocument.build(parsing: "a\n\nb")
        let id = firstBlockID(d)
        XCTAssertEqual(d.block(id)?.text, "a")
        XCTAssertEqual(d.blockIndex(of: id), 0)
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter EditPositionTests`
Expected: FAIL — `cannot find 'EditPosition' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// A caret as a STRUCTURAL position — a block identity plus a UTF-16 offset
/// within that block's text. It cannot desync from bytes the way a document
/// byte offset can, because it names the block directly.
public struct EditPosition: Hashable, Sendable {
    public let block: NodeID
    public let offsetUTF16: Int
    public init(block: NodeID, offsetUTF16: Int) {
        self.block = block; self.offsetUTF16 = offsetUTF16
    }
}

public extension EditableDocument {
    func blockIndex(of id: NodeID) -> Int? {
        segments.firstIndex { if case .block(let b) = $0 { return b.id == id }; return false }
    }

    func block(_ id: NodeID) -> EditableBlock? {
        for s in segments { if case .block(let b) = s, b.id == id { return b } }
        return nil
    }

    func isValid(_ pos: EditPosition) -> Bool {
        guard let b = block(pos.block) else { return false }
        return pos.offsetUTF16 >= 0 && pos.offsetUTF16 <= (b.text as NSString).length
    }
}
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter EditPositionTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/QuoinCore/EditableDocument/EditPosition.swift Tests/QuoinCoreTests/EditableDocument/EditPositionTests.swift
git commit -m "Tree-as-truth Phase 1: structural caret EditPosition"
git push origin main
```

---

### Task 4: `insertText` and `deleteRange` transforms

**Files:**
- Create: `Sources/QuoinCore/EditableDocument/EditTransforms.swift`
- Test: `Tests/QuoinCoreTests/EditableDocument/EditTransformInsertDeleteTests.swift`

**Interfaces:**
- Consumes: `EditableDocument`, `EditPosition`, `EditableBlock`, `NodeID`.
- Produces (mutating on `EditableDocument`, each returns the new caret):
  - `mutating func insertText(_ s: String, at pos: EditPosition) -> EditPosition`
  - `mutating func deleteRange(inBlock id: NodeID, _ range: Range<Int>) -> EditPosition`
  - private helper `mutating func withBlock<T>(_ id: NodeID, _ body: (inout EditableBlock) -> T) -> T?`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuoinCore

final class EditTransformInsertDeleteTests: XCTestCase {

    private func firstBlockID(_ d: EditableDocument) -> NodeID {
        for s in d.segments { if case .block(let b) = s { return b.id } }
        fatalError()
    }

    func testInsertTextMutatesBlockAndReturnsCaretAfterInsert() {
        var d = EditableDocument.build(parsing: "Helo\n\nWorld")
        let id = firstBlockID(d)
        let caret = d.insertText("l", at: EditPosition(block: id, offsetUTF16: 3))
        XCTAssertEqual(d.block(id)?.text, "Hell" + "o")  // "Hello"
        XCTAssertEqual(caret, EditPosition(block: id, offsetUTF16: 4))
        XCTAssertEqual(d.serialized(), "Hello\n\nWorld", "untouched region preserved")
    }

    func testInsertMarksOnlyTheEditedBlockDirty() {
        var d = EditableDocument.build(parsing: "a\n\nb")
        let id = firstBlockID(d)
        _ = d.insertText("X", at: EditPosition(block: id, offsetUTF16: 1))
        XCTAssertEqual(d.block(id)?.pristine, false)
        // The OTHER block stays pristine and verbatim.
        let others = d.segments.compactMap { s -> EditableBlock? in
            if case .block(let b) = s, b.id != id { return b } else { return nil }
        }
        XCTAssertTrue(others.allSatisfy(\.pristine))
        XCTAssertEqual(d.serialized(), "aX\n\nb")
    }

    func testDeleteRangeRemovesTextAndReturnsCaretAtStart() {
        var d = EditableDocument.build(parsing: "Hello\n\nWorld")
        let id = firstBlockID(d)
        let caret = d.deleteRange(inBlock: id, 1..<3)   // remove "el"
        XCTAssertEqual(d.block(id)?.text, "Hlo")
        XCTAssertEqual(caret, EditPosition(block: id, offsetUTF16: 1))
        XCTAssertEqual(d.serialized(), "Hlo\n\nWorld")
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter EditTransformInsertDeleteTests`
Expected: FAIL — no member `insertText`.

- [ ] **Step 3: Implement**

```swift
import Foundation

public extension EditableDocument {
    /// Run `body` against the block with `id` in place. Returns nil if absent.
    @discardableResult
    mutating func withBlock<T>(_ id: NodeID, _ body: (inout EditableBlock) -> T) -> T? {
        for i in segments.indices {
            if case .block(var b) = segments[i], b.id == id {
                let result = body(&b)
                b.pristine = false          // any withBlock mutation dirties it
                segments[i] = .block(b)
                return result
            }
        }
        return nil
    }

    mutating func insertText(_ s: String, at pos: EditPosition) -> EditPosition {
        guard isValid(pos) else { return pos }
        withBlock(pos.block) { b in
            let ns = b.text as NSString
            b.text = ns.replacingCharacters(in: NSRange(location: pos.offsetUTF16, length: 0), with: s)
        }
        return EditPosition(block: pos.block, offsetUTF16: pos.offsetUTF16 + (s as NSString).length)
    }

    mutating func deleteRange(inBlock id: NodeID, _ range: Range<Int>) -> EditPosition {
        withBlock(id) { b in
            let ns = b.text as NSString
            guard range.lowerBound >= 0, range.upperBound <= ns.length else { return }
            b.text = ns.replacingCharacters(
                in: NSRange(location: range.lowerBound, length: range.count), with: "")
        }
        return EditPosition(block: id, offsetUTF16: range.lowerBound)
    }
}
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter EditTransformInsertDeleteTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/QuoinCore/EditableDocument/EditTransforms.swift Tests/QuoinCoreTests/EditableDocument/EditTransformInsertDeleteTests.swift
git commit -m "Tree-as-truth Phase 1: insertText / deleteRange transforms"
git push origin main
```

---

### Task 5: `splitBlock` (Return)

**Files:**
- Modify: `Sources/QuoinCore/EditableDocument/EditTransforms.swift`
- Test: `Tests/QuoinCoreTests/EditableDocument/EditTransformSplitTests.swift`

**Interfaces:**
- Consumes: `insertText`/`deleteRange` infrastructure, `Segment`, `EditableBlock`.
- Produces: `mutating func splitBlock(at pos: EditPosition) -> EditPosition`.
  Splits the block at the caret into two blocks joined by a `\n\n` trivia; the
  new caret is at offset 0 of the second block. Splitting at a block's END makes
  the second block EMPTY (an empty paragraph node — the caret has a real home,
  no virtual line). Both resulting blocks are dirty.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuoinCore

final class EditTransformSplitTests: XCTestCase {

    private func firstBlockID(_ d: EditableDocument) -> NodeID {
        for s in d.segments { if case .block(let b) = s { return b.id } }
        fatalError()
    }
    private func texts(_ d: EditableDocument) -> [String] {
        d.segments.compactMap { if case .block(let b) = $0 { return b.text } else { return nil } }
    }

    /// Return in the MIDDLE of a paragraph splits it into two, caret in the new
    /// second block, joined by a canonical blank line.
    func testSplitMidBlock() {
        var d = EditableDocument.build(parsing: "HelloWorld")
        let id = firstBlockID(d)
        let caret = d.splitBlock(at: EditPosition(block: id, offsetUTF16: 5))
        XCTAssertEqual(texts(d), ["Hello", "World"])
        XCTAssertEqual(caret.offsetUTF16, 0)
        XCTAssertEqual(d.block(caret.block)?.text, "World")
        XCTAssertEqual(d.serialized(), "Hello\n\nWorld")
    }

    /// Return at the END of a block makes a real EMPTY paragraph the caret lives
    /// in — no virtual line, and it serializes to the trailing blank line.
    func testSplitAtEndMakesEmptyParagraph() {
        var d = EditableDocument.build(parsing: "Hello")
        let id = firstBlockID(d)
        let caret = d.splitBlock(at: EditPosition(block: id, offsetUTF16: 5))
        XCTAssertEqual(texts(d), ["Hello", ""])
        XCTAssertEqual(d.block(caret.block)?.text, "")
        XCTAssertEqual(caret.offsetUTF16, 0)
        // An empty trailing paragraph serializes as the blank line after content.
        XCTAssertEqual(d.serialized(), "Hello\n\n")
    }

    /// Both halves are marked dirty (their text changed / they were born).
    func testSplitDirtiesBothHalves() {
        var d = EditableDocument.build(parsing: "abcd")
        let id = firstBlockID(d)
        let caret = d.splitBlock(at: EditPosition(block: id, offsetUTF16: 2))
        XCTAssertEqual(d.block(id)?.pristine, false)
        XCTAssertEqual(d.block(caret.block)?.pristine, false)
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter EditTransformSplitTests`
Expected: FAIL — no member `splitBlock`.

- [ ] **Step 3: Implement**

```swift
public extension EditableDocument {
    /// Return: split the caret's block into [before] and [after], inserting a
    /// canonical "\n\n" trivia between them. The new caret sits at offset 0 of
    /// the AFTER block. An end-of-block split leaves AFTER empty — a real empty
    /// paragraph node, not a virtual line.
    mutating func splitBlock(at pos: EditPosition) -> EditPosition {
        guard isValid(pos), let segIndex = blockIndex(of: pos.block),
              case .block(let original) = segments[segIndex] else { return pos }
        let ns = original.text as NSString
        let before = ns.substring(to: pos.offsetUTF16)
        let after = ns.substring(from: pos.offsetUTF16)

        var head = original
        head.text = before
        head.sourceSpan = nil          // edited: no longer a verbatim span
        head.pristine = false

        let tail = EditableBlock(
            id: .fresh(), kind: original.kind, text: after, sourceSpan: nil, pristine: false)

        segments.replaceSubrange(segIndex...segIndex, with: [
            .block(head), .trivia("\n\n"), .block(tail),
        ])
        return EditPosition(block: tail.id, offsetUTF16: 0)
    }
}
```

(`blockIndex(of:)` is the segment-index lookup defined in Task 3 — reuse it, do
not add a second lookup helper.)

- [ ] **Step 4: Run the test**

Run: `swift test --filter EditTransformSplitTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/QuoinCore/EditableDocument/EditTransforms.swift Tests/QuoinCoreTests/EditableDocument/EditTransformSplitTests.swift
git commit -m "Tree-as-truth Phase 1: splitBlock (Return) — real empty paragraph, no virtual line"
git push origin main
```

---

### Task 6: `joinWithPrevious` (Backspace-at-start)

**Files:**
- Modify: `Sources/QuoinCore/EditableDocument/EditTransforms.swift`
- Test: `Tests/QuoinCoreTests/EditableDocument/EditTransformJoinTests.swift`

**Interfaces:**
- Consumes: `splitBlock` infrastructure, `blockIndex(of:)` (Task 3).
- Produces: `mutating func joinWithPrevious(_ id: NodeID) -> EditPosition?`.
  Merges the block into its immediately-preceding block (dropping the trivia
  between them); the caret lands at the join (the end of the predecessor's
  original text). Returns nil when there is no preceding block (first block).
  This is the exact inverse of `splitBlock`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuoinCore

final class EditTransformJoinTests: XCTestCase {

    private func blockIDs(_ d: EditableDocument) -> [NodeID] {
        d.segments.compactMap { if case .block(let b) = $0 { return b.id } else { return nil } }
    }
    private func texts(_ d: EditableDocument) -> [String] {
        d.segments.compactMap { if case .block(let b) = $0 { return b.text } else { return nil } }
    }

    /// Backspace at the start of the second block merges it into the first, at
    /// the join. THE bug this whole re-arch fixes: it can never delete a
    /// predecessor character, because it operates on whole blocks.
    func testJoinMergesIntoPredecessorAtTheJoin() {
        var d = EditableDocument.build(parsing: "# How to do things\n\nclint")
        let second = blockIDs(d)[1]
        let caret = d.joinWithPrevious(second)
        XCTAssertEqual(texts(d), ["# How to do thingsclint"])
        XCTAssertEqual(caret?.offsetUTF16, ("# How to do things" as NSString).length,
                       "caret at the join — after 'things', before 'clint'")
        XCTAssertEqual(d.serialized(), "# How to do thingsclint")
    }

    /// Joining an EMPTY second block (the empty paragraph a Return made) simply
    /// removes it and the blank line, caret at the predecessor's end. One
    /// Backspace undoes one Return.
    func testJoinEmptyParagraphUndoesTheReturn() {
        var d = EditableDocument.build(parsing: "Hello")
        // Build a real empty trailing paragraph by splitting at the end first.
        let first = blockIDs(d)[0]
        let caret0 = d.splitBlock(at: EditPosition(block: first, offsetUTF16: 5))
        XCTAssertEqual(texts(d), ["Hello", ""])
        // Now Backspace at the start of the empty paragraph.
        let caret = d.joinWithPrevious(caret0.block)
        XCTAssertEqual(texts(d), ["Hello"])
        XCTAssertEqual(caret?.offsetUTF16, 5)
        XCTAssertEqual(d.serialized(), "Hello")
    }

    /// The FIRST block has no predecessor: join is a no-op returning nil.
    func testJoinFirstBlockIsNil() {
        var d = EditableDocument.build(parsing: "a\n\nb")
        XCTAssertNil(d.joinWithPrevious(blockIDs(d)[0]))
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `swift test --filter EditTransformJoinTests`
Expected: FAIL — no member `joinWithPrevious`.

- [ ] **Step 3: Implement**

```swift
public extension EditableDocument {
    /// Backspace at a block's start: merge it into the immediately-preceding
    /// block. The trivia between them is dropped; the caret lands at the end of
    /// the predecessor's ORIGINAL text (the join). The exact inverse of
    /// splitBlock. Returns nil for the first block (no predecessor).
    mutating func joinWithPrevious(_ id: NodeID) -> EditPosition? {
        guard let segIndex = blockIndex(of: id),
              case .block(let current) = segments[segIndex] else { return nil }
        // Find the nearest preceding BLOCK segment; everything between it and us
        // (a single trivia) is the separator to drop.
        var prevIndex = segIndex - 1
        while prevIndex >= 0 {
            if case .block = segments[prevIndex] { break }
            prevIndex -= 1
        }
        guard prevIndex >= 0, case .block(var prev) = segments[prevIndex] else { return nil }

        let joinOffset = (prev.text as NSString).length
        prev.text += current.text
        prev.sourceSpan = nil
        prev.pristine = false
        // Replace [prev ... current] (prev, the trivia(s) between, current) with
        // just the merged prev.
        segments.replaceSubrange(prevIndex...segIndex, with: [.block(prev)])
        return EditPosition(block: prev.id, offsetUTF16: joinOffset)
    }
}
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter EditTransformJoinTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/QuoinCore/EditableDocument/EditTransforms.swift Tests/QuoinCoreTests/EditableDocument/EditTransformJoinTests.swift
git commit -m "Tree-as-truth Phase 1: joinWithPrevious (Backspace) — whole-block merge, never eats a char"
git push origin main
```

---

### Task 7: Round-trip + edit-fidelity fuzz (the elimination proof)

**Files:**
- Test: `Tests/QuoinCoreTests/EditableDocument/EditFidelityFuzzTests.swift`

**Interfaces:**
- Consumes: all Phase 1 transforms + `serialized()`.
- Produces: no new API — the property proof that the bug class is gone.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuoinCore

/// The elimination proof. These are the exact behaviors that were broken in the
/// string-as-truth model; here they hold by construction.
final class EditFidelityFuzzTests: XCTestCase {

    private func blockIDs(_ d: EditableDocument) -> [NodeID] {
        d.segments.compactMap { if case .block(let b) = $0 { return b.id } else { return nil } }
    }

    /// Return then Backspace at the same seam is the IDENTITY — byte-identical to
    /// the original. (In the old model this corrupted the heading.)
    func testSplitThenJoinIsIdentity() {
        for source in ["# How to do things", "Hello", "a\n\nb\n\nc", "# H\n\nbody\n"] {
            var d = EditableDocument.build(parsing: source)
            for id in blockIDs(d) {
                let len = (d.block(id)!.text as NSString).length
                for offset in [0, len / 2, len] {
                    var work = d
                    let caret = work.splitBlock(at: EditPosition(block: id, offsetUTF16: offset))
                    let back = work.joinWithPrevious(caret.block)
                    XCTAssertEqual(work.serialized(), d.serialized(),
                                   "split@\(offset) then join not identity for \(source.debugDescription)")
                    XCTAssertNotNil(back)
                }
            }
        }
    }

    /// The headline scenario, end to end: type a heading, Return, type, delete it
    /// back, Backspace to the heading — the heading is NEVER corrupted.
    func testHeadingReturnTypeDeleteBackspaceKeepsHeadingIntact() {
        var d = EditableDocument.build(parsing: "# How to do things")
        let heading = blockIDs(d)[0]
        let afterReturn = d.splitBlock(at: EditPosition(
            block: heading, offsetUTF16: ("# How to do things" as NSString).length))
        // Type "clint" into the new empty paragraph.
        var caret = afterReturn
        for ch in "clint" { caret = d.insertText(String(ch), at: caret) }
        XCTAssertEqual(d.serialized(), "# How to do things\n\nclint")
        // Delete "clint" back to empty.
        caret = d.deleteRange(inBlock: caret.block, 0..<("clint" as NSString).length)
        // Backspace at the start of the now-empty paragraph → join into heading.
        _ = d.joinWithPrevious(caret.block)
        XCTAssertEqual(d.serialized(), "# How to do things",
                       "the heading survives byte-for-byte — no eaten 'g'")
    }

    /// An edit to ONE block leaves every other block byte-identical (retained
    /// spans re-emit verbatim).
    func testEditingOneBlockLeavesOthersByteIdentical() {
        var d = EditableDocument.build(parsing: "alpha\n\nbeta\n\ngamma")
        let ids = blockIDs(d)
        _ = d.insertText("X", at: EditPosition(block: ids[1], offsetUTF16: 2))  // "beta" -> "beXta"
        XCTAssertEqual(d.serialized(), "alpha\n\nbeXta\n\ngamma")
    }
}
```

- [ ] **Step 2: Run it and watch it fail (or pass — it should already hold)**

Run: `swift test --filter EditFidelityFuzzTests`
Expected: PASS. Unlike the earlier tasks these assert PROPERTIES of the already-built
transforms; if any fails, it exposes a real defect in Tasks 4–6 — fix the transform,
never weaken the assertion.

- [ ] **Step 3: Run the whole suite**

Run: `swift test`
Expected: PASS — the new suites plus every existing test (Phase 1 is additive).

- [ ] **Step 4: Commit**

```bash
git add Tests/QuoinCoreTests/EditableDocument/EditFidelityFuzzTests.swift
git commit -m "Tree-as-truth Phase 1: round-trip + edit-fidelity fuzz — the bug-class elimination proof"
git push origin main
```

---

## Final verification

- [ ] `swift test` — full suite green, including all seven new `EditableDocument` suites.
- [ ] The byte-lossless corpus fuzz (Task 2) passes through the real mutable model.
- [ ] `testSplitThenJoinIsIdentity` and `testHeadingReturnTypeDeleteBackspaceKeepsHeadingIntact`
      pass — the exact corruptions from this session are impossible in the new model.
- [ ] No AppKit/UIKit import entered `QuoinCore` (Linux-clean): `grep -rn "import AppKit\|import UIKit" Sources/QuoinCore/EditableDocument/` returns nothing.
- [ ] Update the spec's Phase 1 line to reference this plan as delivered.

## What Phase 1 deliberately leaves for later

- **Inline structure / canonical serialization of edited inline runs** — Phase 1
  edits block text as a flat string; the `pristine` hook exists for when edited
  inline runs need canonical re-emission. Not needed to eliminate the bug class.
- **Footnote definitions as editable block nodes** — Phase 0 showed footnote
  defs are the one non-whitespace content outside the block model. Phase 1 keeps
  them in trivia, so they are BYTE-PRESERVED (re-emitted verbatim) but not yet
  editable as blocks. Promoting them to first-class nodes (the spec's "close the
  Phase 0 gap") is a focused follow-up; byte-losslessness does not depend on it.
- **List/quote marker continuation** (`wrap`/`unwrap`) — Return inside a list
  continues the marker. A Phase 1 continuation; the split/join core it builds on
  is done here.
- **The TextKit 2 bridge and the caret↔screen mapping** — Phase 2.
- **Making the tree authoritative in a live window / retiring the old path and the
  interim guard** — Phase 3.
