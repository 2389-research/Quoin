# Phase 0 — Editor Foundations & Test Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the substrate-agnostic foundations for the editable-islands rearchitecture — a `QuoinEditorKit` target, the stable-anchor/edit-scope value types, a renderer height-metrics API, and (the point of the whole phase) a **headless end-to-end test harness** that drives a real `NSTextView` through `NSTextInputClient` with a revision/quiescence barrier and an insertion-bar-height gate. No visible app change.

**Architecture:** A new `QuoinEditorKit` SwiftPM target (depends on `QuoinCore` + `QuoinRender`) holds pure value types (`UTF8IndexMap`, `ByteAnchor`, `BoundaryID`, `IslandUnit`, `BlockListModel`) and the AppKit-guarded harness. The types reuse the existing `BlockID` (content-hash + occurrence, already stable across reparse) and the existing `DocumentSession.contentRevision`; the harness adds its own monotonic `appliedRevision` counter because the session's revision does not bump on every edit. The harness reuses the offscreen-window NSTextView pattern already proven in `CaretLineAnchorTests` — no separate host app.

**Tech Stack:** Swift (Package.swift SwiftPM), AppKit + TextKit 2, XCTest. Spec: `docs/superpowers/specs/2026-08-11-editable-islands-design.md`.

## Global Constraints

- Platforms: macOS 14 / iOS 17 / visionOS 1 (from `Package.swift`); the harness is AppKit-only and runs on the macOS CI runner (guard AppKit code `#if canImport(AppKit)`).
- `QuoinEditorKit` uses **Swift 5 language mode** (matches `QuoinRender`, which it links; avoids the staged `sending self` concurrency migration). Pure value types stay `Sendable`.
- Reuse, do NOT redefine: `BlockID` (`Sources/QuoinCore/Model.swift:207`, `init(contentHash:occurrence:)`), `Block { id: BlockID; kind: BlockKind; range: ByteRange }`, `QuoinDocument` (has `.blocks: [Block]` and `.source`), `ByteRange { offset: Int; length: Int }`, `EditMapping.utf8Offset(inText:utf16Offset:)` / `EditMapping.utf16Offset(inText:utf8Offset:)`, `DocumentSession.contentRevision`.
- Byte offsets in the model are **UTF-8**; `NSTextView`/`NSString` offsets are **UTF-16**. Every byte↔storage mapping goes through `UTF8IndexMap` (Task 2) or `EditMapping`.
- No new third-party dependencies (dependency policy).
- Revert `Package.resolved` churn before each commit (`git checkout Package.resolved`). Commit + push to `main` after each task. Commit-message trailers:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_013hf6D4MU3MgzEXSY3qZXEv`.
- Package tests: `swift test` at repo root (run UNPIPED — a piped `swift test | tail` reports the pipe's exit code). This phase changes **no** existing behavior; the full existing suite must stay green.

## File Structure

- `Package.swift` — add the `QuoinEditorKit` target + product + `QuoinEditorKitTests` test target.
- `Sources/QuoinEditorKit/UTF8IndexMap.swift` — byte↔UTF-16 offset mapping for one island's text.
- `Sources/QuoinEditorKit/Anchors.swift` — `ByteAnchor`, `BoundaryID`, `SelectionAnchorRange`.
- `Sources/QuoinEditorKit/IslandUnit.swift` — `IslandUnitID`, `IslandUnit`, `BlockListModel`.
- `Sources/QuoinEditorKit/EditorTestHarness.swift` — the AppKit-guarded headless harness (offscreen window + NSTextView + `NSTextInputClient` drivers + `appliedRevision` barrier + caret-rect reader + `assertInsertionBar`).
- `Sources/QuoinRender/AttributedRenderer+Metrics.swift` — the block height/line-tops metrics API (new file in the existing target).
- `Tests/QuoinEditorKitTests/*` — one test file per source unit.

---

### Task 1: `QuoinEditorKit` target scaffold

**Files:**
- Modify: `Package.swift`
- Create: `Sources/QuoinEditorKit/QuoinEditorKit.swift`
- Test: `Tests/QuoinEditorKitTests/ScaffoldTests.swift`

**Interfaces:**
- Produces: a `QuoinEditorKit` library target (depends on `QuoinCore`, `QuoinRender`) + `QuoinEditorKitTests`, both Swift 5 mode; an `enum QuoinEditorKit { static let version = "0.0.0-phase0" }` so the target has a symbol and the test proves linkage.

- [ ] **Step 1: Write the failing test**

`Tests/QuoinEditorKitTests/ScaffoldTests.swift`:
```swift
import XCTest
@testable import QuoinEditorKit

final class ScaffoldTests: XCTestCase {
    func testTargetLinks() {
        XCTAssertEqual(QuoinEditorKit.version, "0.0.0-phase0")
    }
}
```

- [ ] **Step 2: Run — verify it fails**

Run: `swift test --filter QuoinEditorKitTests`
Expected: FAIL to build — "no such module 'QuoinEditorKit'".

- [ ] **Step 3: Create the target source + wire Package.swift**

`Sources/QuoinEditorKit/QuoinEditorKit.swift`:
```swift
/// The editable-islands editor layer (rearchitecture, Phase 0+). Holds the
/// substrate-agnostic edit-orchestration types and the headless test harness.
public enum QuoinEditorKit {
    public static let version = "0.0.0-phase0"
}
```
In `Package.swift`: add to `products` `.library(name: "QuoinEditorKit", targets: ["QuoinEditorKit"])`, and to `targets`:
```swift
.target(
    name: "QuoinEditorKit",
    dependencies: ["QuoinCore", "QuoinRender"],
    path: "Sources/QuoinEditorKit",
    swiftSettings: [.swiftLanguageMode(.v5)]
),
.testTarget(
    name: "QuoinEditorKitTests",
    dependencies: ["QuoinEditorKit", "QuoinCore", "QuoinRender"],
    path: "Tests/QuoinEditorKitTests",
    swiftSettings: [.swiftLanguageMode(.v5)]
),
```

- [ ] **Step 4: Run — verify it passes**

Run: `swift test --filter QuoinEditorKitTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add Package.swift Sources/QuoinEditorKit Tests/QuoinEditorKitTests
git commit -m "Phase 0: add QuoinEditorKit target scaffold"
git push origin main
```

---

### Task 2: `UTF8IndexMap` (byte ↔ UTF-16 for one island)

**Files:**
- Create: `Sources/QuoinEditorKit/UTF8IndexMap.swift`
- Test: `Tests/QuoinEditorKitTests/UTF8IndexMapTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct UTF8IndexMap: Sendable {
      public init(_ text: String)
      public var utf8Count: Int { get }
      public var utf16Count: Int { get }
      public func utf16(fromUTF8 byteOffset: Int) -> Int?   // nil if out of range or mid-scalar
      public func utf8(fromUTF16 utf16Offset: Int) -> Int?
  }
  ```
  Later phases map an island's local caret (UTF-16, from `NSTextView`) to a document byte offset and back through this.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import QuoinEditorKit

final class UTF8IndexMapTests: XCTestCase {
    func testAsciiRoundTrip() {
        let m = UTF8IndexMap("# Hi")
        XCTAssertEqual(m.utf8Count, 4); XCTAssertEqual(m.utf16Count, 4)
        XCTAssertEqual(m.utf16(fromUTF8: 2), 2)
        XCTAssertEqual(m.utf8(fromUTF16: 2), 2)
        XCTAssertEqual(m.utf16(fromUTF8: 4), 4)   // end
        XCTAssertNil(m.utf16(fromUTF8: 5))        // out of range
    }
    func testMultibyteAndAstral() {
        // "é" = 2 UTF-8 bytes, 1 UTF-16 unit; "😀" = 4 UTF-8 bytes, 2 UTF-16 units.
        let m = UTF8IndexMap("é😀")
        XCTAssertEqual(m.utf8Count, 6); XCTAssertEqual(m.utf16Count, 3)
        XCTAssertEqual(m.utf16(fromUTF8: 2), 1)   // after "é"
        XCTAssertEqual(m.utf16(fromUTF8: 6), 3)   // end
        XCTAssertNil(m.utf16(fromUTF8: 1))        // mid-"é" → not representable
        XCTAssertEqual(m.utf8(fromUTF16: 1), 2)
        XCTAssertNil(m.utf8(fromUTF16: 2))        // mid-astral (low surrogate) → nil
    }
}
```

- [ ] **Step 2: Run — verify it fails**

Run: `swift test --filter UTF8IndexMapTests`
Expected: FAIL — `UTF8IndexMap` undefined.

- [ ] **Step 3: Implement**

```swift
import Foundation

public struct UTF8IndexMap: Sendable {
    // byteAtUTF16[i] = UTF-8 offset of the start of UTF-16 unit i; last entry = utf8Count.
    private let byteAtUTF16: [Int]
    // utf16AtByte[b] = UTF-16 offset when b is a scalar boundary, else -1.
    private let utf16AtByte: [Int]

    public init(_ text: String) {
        var byteAt: [Int] = []
        var u16At = [Int](repeating: -1, count: text.utf8.count + 1)
        var byte = 0, u16 = 0
        for scalar in text.unicodeScalars {
            let sBytes = String(scalar).utf8.count
            let sU16 = scalar.value > 0xFFFF ? 2 : 1
            u16At[byte] = u16
            for _ in 0..<sU16 { byteAt.append(byte) }   // both surrogate slots map to the scalar start byte…
            // …but only the FIRST UTF-16 unit of a scalar is a valid utf8 boundary:
            byte += sBytes; u16 += sU16
        }
        byteAt.append(byte)          // end
        u16At[byte] = u16            // end is a boundary
        // Mark low-surrogate slots invalid for utf8(fromUTF16:): a scalar of 2
        // units has its second slot pointing at the same start byte — reject it.
        // Rebuild byteAt so only true unit-starts resolve; store -1 for the low half.
        var fixed = [Int](repeating: -1, count: u16 + 1)
        var b2 = 0, u2 = 0
        for scalar in text.unicodeScalars {
            fixed[u2] = b2
            let sU16 = scalar.value > 0xFFFF ? 2 : 1
            b2 += String(scalar).utf8.count; u2 += sU16   // leaves the low-surrogate slot at -1
        }
        fixed[u2] = b2
        self.byteAtUTF16 = fixed
        self.utf16AtByte = u16At
    }

    public var utf8Count: Int { utf16AtByte.count - 1 }
    public var utf16Count: Int { byteAtUTF16.count - 1 }

    public func utf16(fromUTF8 byteOffset: Int) -> Int? {
        guard byteOffset >= 0, byteOffset < utf16AtByte.count else { return nil }
        let v = utf16AtByte[byteOffset]
        return v >= 0 ? v : nil
    }
    public func utf8(fromUTF16 utf16Offset: Int) -> Int? {
        guard utf16Offset >= 0, utf16Offset < byteAtUTF16.count else { return nil }
        let v = byteAtUTF16[utf16Offset]
        return v >= 0 ? v : nil
    }
}
```
NOTE: implementer — verify the surrogate/mid-scalar `nil` cases against the test; if the two-pass construction is awkward, a single pass that fills both tables with `-1` sentinels for non-boundary slots is fine, as long as the test passes exactly.

- [ ] **Step 4: Run — verify it passes**

Run: `swift test --filter UTF8IndexMapTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/UTF8IndexMap.swift Tests/QuoinEditorKitTests/UTF8IndexMapTests.swift
git commit -m "Phase 0: UTF8IndexMap (byte<->UTF-16 for island-local mapping)"
git push origin main
```

---

### Task 3: `ByteAnchor` + `BoundaryID` anchor types

**Files:**
- Create: `Sources/QuoinEditorKit/Anchors.swift`
- Test: `Tests/QuoinEditorKitTests/AnchorsTests.swift`

**Interfaces:**
- Consumes: `BlockID` (QuoinCore).
- Produces:
  ```swift
  public struct BoundaryID: Hashable, Sendable {
      public enum Kind: Sendable { case interBlock, blockStart, blockEnd }
      public let left: BlockID?; public let right: BlockID?; public let kind: Kind
      public init(left: BlockID?, right: BlockID?, kind: Kind)
  }
  public struct ByteAnchor: Hashable, Sendable {
      public enum Kind: Hashable, Sendable { case byte(Int); case boundary(BoundaryID) }
      public enum Affinity: Sendable { case before, after }
      public var kind: Kind; public var affinity: Affinity
      public var goalColumn: Int?; public var revision: Int
      public init(kind: Kind, affinity: Affinity, goalColumn: Int?, revision: Int)
      public static func byte(_ offset: Int, affinity: Affinity, revision: Int, goalColumn: Int?) -> ByteAnchor
  }
  public struct SelectionAnchorRange: Hashable, Sendable {
      public var start: ByteAnchor; public var end: ByteAnchor
      public var isCaret: Bool { get }   // start == end
      public init(start: ByteAnchor, end: ByteAnchor)
  }
  ```
  Phase 0 defines the types + trivial invariants only; cross-reparse *resolution* is Phase 2/3.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import QuoinCore
@testable import QuoinEditorKit

final class AnchorsTests: XCTestCase {
    func testCaretByteAnchor() {
        let a = ByteAnchor.byte(5, affinity: .after, revision: 3, goalColumn: nil)
        let sel = SelectionAnchorRange(start: a, end: a)
        XCTAssertTrue(sel.isCaret)
        if case .byte(let n) = a.kind { XCTAssertEqual(n, 5) } else { XCTFail() }
        XCTAssertEqual(a.revision, 3)
    }
    func testBoundaryEquatableAcrossEqualNeighbors() {
        let l = BlockID(contentHash: 1, occurrence: 0)
        let r = BlockID(contentHash: 2, occurrence: 0)
        let b1 = BoundaryID(left: l, right: r, kind: .interBlock)
        let b2 = BoundaryID(left: l, right: r, kind: .interBlock)
        XCTAssertEqual(b1, b2)
        XCTAssertNotEqual(b1, BoundaryID(left: l, right: nil, kind: .blockEnd))
    }
    func testRangeSelectionNotCaret() {
        let s = ByteAnchor.byte(2, affinity: .after, revision: 0, goalColumn: nil)
        let e = ByteAnchor.byte(7, affinity: .after, revision: 0, goalColumn: nil)
        XCTAssertFalse(SelectionAnchorRange(start: s, end: e).isCaret)
    }
}
```

- [ ] **Step 2: Run — verify it fails.** `swift test --filter AnchorsTests` → undefined types.

- [ ] **Step 3: Implement** `Sources/QuoinEditorKit/Anchors.swift`

```swift
import QuoinCore

public struct BoundaryID: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case interBlock, blockStart, blockEnd }
    public let left: BlockID?; public let right: BlockID?; public let kind: Kind
    public init(left: BlockID?, right: BlockID?, kind: Kind) { self.left = left; self.right = right; self.kind = kind }
}

public struct ByteAnchor: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case byte(Int); case boundary(BoundaryID) }
    public enum Affinity: Hashable, Sendable { case before, after }
    public var kind: Kind; public var affinity: Affinity
    public var goalColumn: Int?; public var revision: Int
    public init(kind: Kind, affinity: Affinity, goalColumn: Int?, revision: Int) {
        self.kind = kind; self.affinity = affinity; self.goalColumn = goalColumn; self.revision = revision
    }
    public static func byte(_ offset: Int, affinity: Affinity, revision: Int, goalColumn: Int?) -> ByteAnchor {
        ByteAnchor(kind: .byte(offset), affinity: affinity, goalColumn: goalColumn, revision: revision)
    }
}

public struct SelectionAnchorRange: Hashable, Sendable {
    public var start: ByteAnchor; public var end: ByteAnchor
    public init(start: ByteAnchor, end: ByteAnchor) { self.start = start; self.end = end }
    public var isCaret: Bool { start == end }
}
```

- [ ] **Step 4: Run — verify it passes.** `swift test --filter AnchorsTests` → PASS.

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/Anchors.swift Tests/QuoinEditorKitTests/AnchorsTests.swift
git commit -m "Phase 0: ByteAnchor / BoundaryID / SelectionAnchorRange anchor types"
git push origin main
```

---

### Task 4: `IslandUnit` + `BlockListModel`

**Files:**
- Create: `Sources/QuoinEditorKit/IslandUnit.swift`
- Test: `Tests/QuoinEditorKitTests/IslandUnitTests.swift`

**Interfaces:**
- Consumes: `BlockID`, `BlockKind`, `Block`, `QuoinDocument`, `ByteRange` (QuoinCore).
- Produces:
  ```swift
  public struct IslandUnitID: Hashable, Sendable { }           // opaque, minted monotonically
  public struct IslandUnit: Sendable {
      public let id: IslandUnitID          // stable while editing — NOT the content-hash BlockID
      public var byteRange: Range<Int>     // UTF-8, half-open
      public var originBlockID: BlockID    // the block active at open time (may change as content edits)
      public init(id: IslandUnitID, byteRange: Range<Int>, originBlockID: BlockID)
  }
  public struct BlockRecord: Sendable, Hashable {
      public let blockID: BlockID; public let kind: BlockKind; public var byteRange: Range<Int>
      public init(blockID: BlockID, kind: BlockKind, byteRange: Range<Int>)
  }
  public struct BlockListModel: Sendable {
      public private(set) var records: [BlockRecord]
      public init(document: QuoinDocument)                     // builds records from document.blocks
      public func record(at byteOffset: Int) -> BlockRecord?   // the block whose range contains the offset
      public mutating func mintIsland(at byteOffset: Int) -> IslandUnit?   // fresh id + the containing block's range
  }
  ```
- WHY `IslandUnitID` is separate from `BlockID`: `BlockID` is a content hash — it CHANGES the moment the user edits the block's text. The active edit scope must NOT be re-keyed mid-keystroke, so `IslandUnit` carries its own monotonic id (this is the concrete guard behind the spec's "island identity persists across non-structural type morphing").

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import QuoinCore
@testable import QuoinEditorKit

final class IslandUnitTests: XCTestCase {
    func testRecordsFromDocument() {
        let doc = MarkdownConverter.parse("# Heading\n\nA paragraph.")
        let model = BlockListModel(document: doc)
        XCTAssertEqual(model.records.count, doc.blocks.count)
        // The record at an offset inside the heading is the heading block.
        let rec = model.record(at: 2)
        XCTAssertEqual(rec?.blockID, doc.blocks[0].id)
    }
    func testMintIslandGetsFreshIdAndBlockRange() {
        let doc = MarkdownConverter.parse("# Heading\n\nA paragraph.")
        var model = BlockListModel(document: doc)
        let i1 = model.mintIsland(at: 2)
        let i2 = model.mintIsland(at: 2)   // same offset, but a NEW island identity each mint
        XCTAssertNotNil(i1); XCTAssertNotNil(i2)
        XCTAssertNotEqual(i1!.id, i2!.id, "each activation mints a fresh IslandUnitID")
        XCTAssertEqual(i1!.originBlockID, doc.blocks[0].id)
        XCTAssertEqual(i1!.byteRange, doc.blocks[0].range.offset ..< (doc.blocks[0].range.offset + doc.blocks[0].range.length))
    }
    func testOutOfRangeOffset() {
        let doc = MarkdownConverter.parse("# Heading")
        var model = BlockListModel(document: doc)
        XCTAssertNil(model.record(at: 9_999))
        XCTAssertNil(model.mintIsland(at: 9_999))
    }
}
```

- [ ] **Step 2: Run — verify it fails.** `swift test --filter IslandUnitTests` → undefined.

- [ ] **Step 3: Implement** `Sources/QuoinEditorKit/IslandUnit.swift`

```swift
import QuoinCore

public struct IslandUnitID: Hashable, Sendable {
    private let raw: Int
    private static let counter = Counter()
    fileprivate init(raw: Int) { self.raw = raw }
    static func mint() -> IslandUnitID { IslandUnitID(raw: counter.next()) }
    // A tiny thread-safe monotonic source (islands are minted on the main actor in
    // practice; the lock keeps the type self-contained and Sendable-safe).
    final class Counter: @unchecked Sendable {
        private var value = 0; private let lock = NSLock()
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }
}

public struct IslandUnit: Sendable {
    public let id: IslandUnitID
    public var byteRange: Range<Int>
    public var originBlockID: BlockID
    public init(id: IslandUnitID, byteRange: Range<Int>, originBlockID: BlockID) {
        self.id = id; self.byteRange = byteRange; self.originBlockID = originBlockID
    }
}

public struct BlockRecord: Sendable, Hashable {
    public let blockID: BlockID; public let kind: BlockKind; public var byteRange: Range<Int>
    public init(blockID: BlockID, kind: BlockKind, byteRange: Range<Int>) {
        self.blockID = blockID; self.kind = kind; self.byteRange = byteRange
    }
}

public struct BlockListModel: Sendable {
    public private(set) var records: [BlockRecord]
    public init(document: QuoinDocument) {
        records = document.blocks.map {
            BlockRecord(blockID: $0.id, kind: $0.kind,
                        byteRange: $0.range.offset ..< ($0.range.offset + $0.range.length))
        }
    }
    public func record(at byteOffset: Int) -> BlockRecord? {
        records.first { $0.byteRange.contains(byteOffset) }
    }
    public mutating func mintIsland(at byteOffset: Int) -> IslandUnit? {
        guard let rec = record(at: byteOffset) else { return nil }
        return IslandUnit(id: .mint(), byteRange: rec.byteRange, originBlockID: rec.blockID)
    }
}
```
NOTE: `BlockKind` must be `Hashable` for `BlockRecord: Hashable` — confirm (it is used in `Block: Hashable`). If a `BlockKind` associated value is non-Hashable, drop `Hashable` from `BlockRecord` and adjust the test (compare fields).

- [ ] **Step 4: Run — verify it passes.** `swift test --filter IslandUnitTests` → PASS.

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/IslandUnit.swift Tests/QuoinEditorKitTests/IslandUnitTests.swift
git commit -m "Phase 0: IslandUnit (edit scope, own identity) + BlockListModel"
git push origin main
```

---

### Task 5: Renderer block height-metrics API

**Files:**
- Create: `Sources/QuoinRender/AttributedRenderer+Metrics.swift`
- Test: `Tests/QuoinRenderTests/BlockMetricsTests.swift`

**Interfaces:**
- Consumes: `AttributedRenderer`, `Block`, `QuoinDocument` (QuoinRender/QuoinCore).
- Produces (on `AttributedRenderer`, `#if canImport(AppKit)`):
  ```swift
  public func measuredHeight(of block: Block, in document: QuoinDocument, width: CGFloat) -> CGFloat
  public func lineTops(of block: Block, in document: QuoinDocument, width: CGFloat) -> [CGFloat]
  ```
  `BlockRenderCell` (Phase 1) uses `measuredHeight` for its deterministic row height (the cell-sizing contract); `lineTops` feeds click-to-caret line mapping (Phase 2). Reuses the existing `render(block:depth:document:)` KEEP renderer + a TextKit-2 layout pass (mirror the `measureHeight` helper already in `RevealFidelityTests`).

- [ ] **Step 1: Write the failing test**

```swift
#if canImport(AppKit)
import XCTest
import QuoinCore
@testable import QuoinRender

final class BlockMetricsTests: XCTestCase {
    func testHeadingHeightIsPositiveAndStable() {
        let doc = MarkdownConverter.parse("# A heading\n\nBody.")
        let r = AttributedRenderer()
        let h1 = r.measuredHeight(of: doc.blocks[0], in: doc, width: 600)
        let h2 = r.measuredHeight(of: doc.blocks[0], in: doc, width: 600)
        XCTAssertGreaterThan(h1, 10)
        XCTAssertEqual(h1, h2, accuracy: 0.01, "deterministic for the cell-sizing contract")
    }
    func testTallerBlockMeasuresTaller() {
        let doc = MarkdownConverter.parse("Short.\n\nA much longer paragraph that will certainly wrap onto multiple lines when laid out at a narrow width so its measured height exceeds the short one.")
        let r = AttributedRenderer()
        let short = r.measuredHeight(of: doc.blocks[0], in: doc, width: 200)
        let long = r.measuredHeight(of: doc.blocks[1], in: doc, width: 200)
        XCTAssertGreaterThan(long, short)
    }
    func testLineTopsMonotonic() {
        let doc = MarkdownConverter.parse("Line wrapping paragraph long enough to produce several lines at a narrow width for the tops array to have more than one entry here.")
        let tops = AttributedRenderer().lineTops(of: doc.blocks[0], in: doc, width: 160)
        XCTAssertGreaterThan(tops.count, 1)
        XCTAssertEqual(tops, tops.sorted())
    }
}
#endif
```

- [ ] **Step 2: Run — verify it fails.** `swift test --filter BlockMetricsTests` → undefined methods.

- [ ] **Step 3: Implement** — mirror the existing `measureHeight` TextKit-2 pattern in `RevealFidelityTests` (NSTextStorage → NSTextContentStorage → NSTextLayoutManager → `ensureLayout` → sum fragment heights / collect fragment `minY`s). Render the block via the existing `render(block:depth:document:)`.

```swift
#if canImport(AppKit)
import AppKit
import QuoinCore

extension AttributedRenderer {
    public func measuredHeight(of block: Block, in document: QuoinDocument, width: CGFloat) -> CGFloat {
        layoutFragments(of: block, in: document, width: width).reduce(0) { $0 + $1.height }
    }
    public func lineTops(of block: Block, in document: QuoinDocument, width: CGFloat) -> [CGFloat] {
        layoutFragments(of: block, in: document, width: width).map(\.minY)
    }
    private func layoutFragments(of block: Block, in document: QuoinDocument, width: CGFloat) -> [CGRect] {
        let attributed = render(block: block, depth: 0, document: document)
        let storage = NSTextStorage(attributedString: attributed)
        let cs = NSTextContentStorage(); cs.textStorage = storage
        let lm = NSTextLayoutManager(); cs.addTextLayoutManager(lm)
        lm.textContainer = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        lm.ensureLayout(for: cs.documentRange)
        var frames: [CGRect] = []
        lm.enumerateTextLayoutFragments(from: cs.documentRange.location) { f in
            frames.append(f.layoutFragmentFrame); return true
        }
        return frames
    }
}
#endif
```
NOTE: confirm `render(block:depth:document:)` is accessible (it is `public`/internal in `AttributedRenderer`; use `@testable import` visibility if internal — the extension is in-target so internal is fine). If per-line tops need padding/line-fragment y offsets adjusted, match what a real cell would draw; the test only requires monotonic, >1 entries.

- [ ] **Step 4: Run — verify it passes.** `swift test --filter BlockMetricsTests` → PASS.

- [ ] **Step 5: Commit**
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinRender/AttributedRenderer+Metrics.swift Tests/QuoinRenderTests/BlockMetricsTests.swift
git commit -m "Phase 0: renderer block height/line-tops metrics API (cell-sizing contract)"
git push origin main
```

---

### Task 6: The headless test harness (the gate)

**Files:**
- Create: `Sources/QuoinEditorKit/EditorTestHarness.swift`
- Test: `Tests/QuoinEditorKitTests/HarnessSmokeTests.swift`

**Interfaces:**
- Produces (`#if canImport(AppKit)`, `@MainActor`):
  ```swift
  @MainActor public final class EditorTestHarness {
      public init(width: CGFloat = 600)
      public var textView: NSTextView { get }        // a REAL editable NSTextView in an offscreen window
      public private(set) var appliedRevision: Int    // monotonic; bumps on each driven edit
      // Drivers — go through NSTextInputClient / NSResponder so the real input path runs:
      public func type(_ s: String)                   // insertText
      public func pressReturn()                        // insertNewline
      public func pressBackspace()                     // deleteBackward
      public func move(_ sel: Selector)                // moveRight/Left/Up/Down(_: )
      public func setText(_ s: String)                 // seed island source
      // Quiescence + reads:
      public func quiesce()                            // ensureLayout + pump runloop to settle
      public var caretRect: CGRect { get }             // firstRect for the current insertion point (window coords)
      public func assertInsertionBar(minHeight: CGFloat, file: StaticString, line: UInt)  // the 2pt-dot gate
  }
  ```
  In Phase 2 the harness's `textView` is swapped for the real island cell's text view and the same drivers/asserts drive end-to-end scenarios. Phase 0 proves the *mechanism* against a plain `NSTextView`.
- WHY a private `appliedRevision`, not `DocumentSession.contentRevision`: the session revision does not bump on every ordinary edit; the harness needs a barrier that ticks on every driven edit. Phase 2 wires the orchestrator's real applied-revision in; Phase 0's counter bumps in each driver.

- [ ] **Step 1: Write the failing smoke test**

```swift
#if canImport(AppKit)
import XCTest
import AppKit
@testable import QuoinEditorKit

@MainActor
final class HarnessSmokeTests: XCTestCase {
    func testTypingLandsAndCaretIsARealBar() {
        let h = EditorTestHarness()
        h.type("# Heading")
        h.quiesce()
        XCTAssertEqual(h.textView.string, "# Heading")
        XCTAssertEqual(h.appliedRevision, 9)              // one bump per inserted character
        h.assertInsertionBar(minHeight: 8, file: #filePath, line: #line)   // NOT a 2pt dot
    }
    func testReturnAndBackspaceDrive() {
        let h = EditorTestHarness()
        h.type("ab"); h.pressReturn(); h.type("c"); h.quiesce()
        XCTAssertEqual(h.textView.string, "ab\nc")
        h.pressBackspace(); h.pressBackspace(); h.quiesce()   // delete "c" and the newline
        XCTAssertEqual(h.textView.string, "ab")
    }
    func testCaretRectIsNonEmptyAfterQuiesce() {
        let h = EditorTestHarness(); h.type("x"); h.quiesce()
        XCTAssertGreaterThan(h.caretRect.height, 0)
    }
}
#endif
```

- [ ] **Step 2: Run — verify it fails.** `swift test --filter HarnessSmokeTests` → `EditorTestHarness` undefined.

- [ ] **Step 3: Implement the harness** — reuse the offscreen-window pattern from `CaretLineAnchorTests` (create an `NSWindow`, an `NSScrollView`, a TextKit-2 `NSTextView` with content storage + layout manager; make it first responder). Drivers call the real responder methods; `quiesce()` runs `ensureLayout` + a brief `RunLoop.current.run(until:)` pump; `caretRect` uses `textView.firstRect(forCharacterRange:actualRange:)` mapped from the window; `assertInsertionBar` reads the caret rect height.

```swift
#if canImport(AppKit)
import AppKit

@MainActor
public final class EditorTestHarness {
    private let window: NSWindow
    private let scroll: NSScrollView
    public let textView: NSTextView
    public private(set) var appliedRevision = 0

    public init(width: CGFloat = 600) {
        let frame = NSRect(x: 0, y: 0, width: width, height: 800)
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        layoutManager.textContainer = container
        textView = NSTextView(frame: frame, textContainer: container)
        textView.isEditable = true; textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        scroll = NSScrollView(frame: frame); scroll.documentView = textView
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    public func setText(_ s: String) { textView.string = s; quiesce() }
    public func type(_ s: String) { for ch in s { textView.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)); appliedRevision += 1 } }
    public func pressReturn() { textView.insertNewline(nil); appliedRevision += 1 }
    public func pressBackspace() { textView.deleteBackward(nil); appliedRevision += 1 }
    public func move(_ sel: Selector) { textView.doCommand(by: sel); }

    public func quiesce() {
        textView.textLayoutManager?.ensureLayout(for: textView.textContentStorage!.documentRange)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    public var caretRect: CGRect {
        let sel = textView.selectedRange()
        var actual = NSRange()
        return textView.firstRect(forCharacterRange: sel, actualRange: &actual)
    }

    public func assertInsertionBar(minHeight: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(caretRect.height, minHeight,
            "caret must be a real insertion bar, not a collapsed dot", file: file, line: line)
    }
}
#endif
```
NOTE: `assertInsertionBar` uses `XCTAssertGreaterThanOrEqual`, so `EditorTestHarness.swift` must `import XCTest` under the AppKit guard (XCTest links fine in the test run; if linking XCTest into the library target is undesirable, move `assertInsertionBar` into a test-side helper extension and keep only `caretRect` on the harness — implementer's call, keep the smoke test green either way). `Date()`/`RunLoop` are allowed here (normal AppKit code, not a workflow script). If `firstRect` returns window-relative zero before layout, ensure `quiesce()` ran; the smoke test calls it.

- [ ] **Step 4: Run — verify it passes.** `swift test --filter HarnessSmokeTests` → PASS. If `appliedRevision` expected value differs (e.g., driver bump counting), correct the assertion to the real count — the point is it's monotonic and deterministic.

- [ ] **Step 5: Full suite + commit**

Run: `swift test` (UNPIPED) — the entire existing suite must remain green (this phase adds only new, isolated code).
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinEditorKit/EditorTestHarness.swift Tests/QuoinEditorKitTests/HarnessSmokeTests.swift
git commit -m "Phase 0: headless editor test harness (real NSTextView + quiescence + insertion-bar gate)"
git push origin main
```

---

## Final verification

- [ ] `swift test` — full suite green, including the new `QuoinEditorKitTests` and `BlockMetricsTests`; NO existing test changed or broken (Phase 0 adds only isolated new code).
- [ ] `QuoinEditorKit` builds and links `QuoinCore` + `QuoinRender`; the harness drives a real `NSTextView` and the insertion-bar gate passes on a plain text view (the mechanism that will catch the 2pt-dot regression in Phase 2 is proven working now).
- [ ] The app still builds: `cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build` (no app wiring changed, but confirm the new package target doesn't disturb the app build).
- [ ] Confirm `Package.resolved` is unchanged (Sparkle pin not committed).

## Notes for the next phase

Phase 1 builds the read-only view recycler (`BlockRenderCell` via `measuredHeight` from Task 5), behind a feature flag, gated by the Intel-i7 run of the Phase-0.5 spike (`spikes/phase0.5-recycler/`). The harness (Task 6) is repointed from a plain `NSTextView` to the real island cell in Phase 2, where its drivers + `assertInsertionBar` become the end-to-end regression gate for the interior-Return / typing-lands-right / ⌘A-delete scenarios that motivated the whole rearchitecture.
