# CARET-1: Blank-line Height & Backspace-merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make blank-line height a pure function of document state (never caret position), so Return doesn't heave, the caret isn't a tiny dot, and Backspace on a blank line never deletes a previous block's content.

**Architecture:** Approach B (caret-geometry). Delete the two caret-conditional branches in the reveal clamps; style a slice ending `\n\n` at body height (byte-derived) so the blank line already equals the post-first-keystroke height; harden Backspace-in-absorbed-whitespace at the edit layer; draw a full-height caret overlay for compressed gaps (layout-neutral). No new bytes, reveal stays 1:1, patch≡full holds.

**Tech Stack:** Swift 5/6, TextKit 2, `AttributedRenderer` (QuoinRender), `ReaderCoordinator` (AppKit), XCTest + XCUITest.

**Source spec:** `docs/superpowers/specs/2026-08-10-caret1-blank-line-design.md` — read it first. Fixes audit CARET-1 (RC-2). Does NOT add a synthetic empty-paragraph node.

## Global Constraints

- **Byte-lossless:** styling + an edit-layer Backspace rule only. No invented bytes; the on-disk `.md` is untouched until the user types a real character.
- **Reveal fidelity:** the revealed slice stays exactly the source bytes (1:1); hidden delimiters are 1pt clear text. Do not alter the revealed STRING.
- **Viewport invariant:** height must NOT depend on caret position. Enforced by `RevealFidelityTests` (fragment heights) and `CaretLineAnchorTests` (caret-line screen-Y). Patch≡full by `ProjectorEquivalenceTests`. Extend the relevant suite IN THE SAME COMMIT as any change (per `docs/reference/invariants.md`).
- CRLF is one grapheme; the "ends with two newlines" detection is byte-wise.
- `QuoinRender` is Swift 5. No new dependencies.
- Package tests: `swift test`. App build: `cd App/macOS && xcodegen && xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build`. XCUITest: `xcodebuild test -project App/macOS/Quoin.xcodeproj -scheme Quoin -destination 'platform=macOS' -only-testing:QuoinUITests/<Suite>` (the UI-test bundle now code-signs — `GENERATE_INFOPLIST_FILE` is set). Revert `Package.resolved` churn before each commit.
- Commit after each task; push to `main`.

## Verified anchors

- `AttributedRenderer.clampTrailingNewlinePhantom` (AttributedRenderer.swift:1069): clamps the trailing `\n` to `maximumLineHeight = 2` UNLESS `caretOffset >= text.length` (line 1076 — the caret exception to delete).
- `AttributedRenderer.compressInteriorBlankLines` (:1092): the caret guard at :1111 (`if let caretOffset, caretOffset >= line.location, caretOffset <= NSMaxRange(line) { continue }`) is the one to delete; keep the `previousNonBlankSpacing` rule (:1118, loose lists must not double-space).
- Theme body metrics: `bodySize = 14`, `bodyLineHeightMultiple = 1.4`, `paragraphSpacing = 12` (Theme.swift:66-71). A body line ≈ `bodySize * bodyLineHeightMultiple` ≈ 19.6pt.
- `RevealFidelityTests.measureHeight(_:width:)` lays out an attributed string and returns its height — reuse it. `testMidDocumentAbsorbedNewlineParagraphRevealIsHeightNeutral` (:397) is the closest existing pattern (but it puts the caret on CONTENT; CARET-1 is about the caret ON the blank line).
- `ReaderCoordinator.Coordinator.gapDeletion(sourceText:relCaret:forward:)` (ReaderCoordinator.swift:2326): fires only when `relCaret > contentEnd` where `contentEnd = length - trailingNewlines`. `handleGapDeletion` (:2156) routes it. Symptom 3 is the caret landing at `contentEnd` (the content/whitespace boundary) after de-materialization, so `gapDeletion` returns nil and the system deletes a content glyph.

---

## Task 1: Blank-line height is a pure function of document state

**Files:**
- Modify: `Sources/QuoinRender/AttributedRenderer.swift:1069` (`clampTrailingNewlinePhantom`), `:1092` (`compressInteriorBlankLines`)
- Test: `Tests/QuoinRenderTests/RevealFidelityTests.swift` (extend), `Tests/QuoinRenderTests/CaretLineAnchorTests.swift` (extend)

**Interfaces:**
- Consumes: `theme.bodyLineHeightMultiple`, `measureHeight`.
- Produces: no API change — behavior change: reveal heights no longer depend on `caretOffset`.

- [ ] **Step 1: Write the failing tests**

Add to `RevealFidelityTests` (uses the existing `measureHeight`):

```swift
    /// CARET-1: the blank line's height must NOT depend on where the caret is.
    /// Today the clamps OPEN the line to full height when the caret is on it,
    /// so caret-on-blank vs caret-on-content differ — the tiny-dot / heave bug.
    func testBlankLineHeightIsCaretIndependent() throws {
        let source = "# heading\n\n"   // heading + an occupiable blank line (last block)
        let document = MarkdownConverter.parse(source)
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        let block = document.blocks[0].id
        // Caret ON the blank line (end of the extended slice) vs on the content.
        let onBlank = renderer.render(document, activeBlockID: block, activeCaret: 11, cache: &cache)
        let onContent = renderer.render(document, activeBlockID: block, activeCaret: 3, cache: &cache)
        XCTAssertEqual(measureHeight(onBlank.attributed), measureHeight(onContent.attributed), accuracy: 0.5,
                       "blank-line height must be caret-independent (viewport invariant)")
    }

    /// CARET-1: no heave on Return. A slice ending "\n\n" must render its blank
    /// line at BODY height, so typing the first character (which turns it into a
    /// real paragraph line) causes NO height change.
    func testReturnBlankLineEqualsAfterFirstCharacter() throws {
        let renderer = AttributedRenderer()
        var cache: [BlockID: NSAttributedString] = [:]
        // State just after Return: heading + blank line, caret on the blank line.
        let afterReturn = MarkdownConverter.parse("# heading\n\n")
        let r1 = renderer.render(afterReturn, activeBlockID: afterReturn.blocks[0].id, activeCaret: 11, cache: &cache)
        // State after typing the first character: heading + paragraph "x".
        let afterChar = MarkdownConverter.parse("# heading\n\nx")
        let paraID = afterChar.blocks[1].id
        let r2 = renderer.render(afterChar, activeBlockID: paraID, activeCaret: 1, cache: &cache)
        // The caret's line height (blank vs the "x" line) must match → no heave.
        XCTAssertEqual(measureHeight(r1.attributed), measureHeight(r2.attributed), accuracy: 1.0,
                       "Return blank line must equal the height after the first character (no heave)")
    }
```

- [ ] **Step 2: Run and watch them fail**

Run: `swift test --filter RevealFidelityTests`
Expected: FAIL — `testBlankLineHeightIsCaretIndependent` (caret-on-blank opens to full height) and `testReturnBlankLineEqualsAfterFirstCharacter` (blank line is 2pt or full, not body height).

- [ ] **Step 3: Remove the caret exceptions + add the body-height branch**

`compressInteriorBlankLines` (:1111): delete the caret guard line entirely:
```swift
            // (deleted) if let caretOffset, caretOffset >= line.location, caretOffset <= NSMaxRange(line) { continue }
```
Its signature keeps `caretOffset` for now (callers pass it) but it is unused; drop the parameter if clean, else leave it and note. Keep the `previousNonBlankSpacing`/`rowHeight` logic.

`clampTrailingNewlinePhantom` (:1069): delete the caret early-return (:1076) and split on the slice's trailing bytes:
```swift
    private func clampTrailingNewlinePhantom(in styled: NSMutableAttributedString) {
        let text = styled.string as NSString
        guard text.length > 0,
              text.character(at: text.length - 1) == UInt16(UnicodeScalar("\n").value)
        else { return }
        // Byte-derived, NOT caret-derived (viewport invariant). A slice ending
        // in TWO newlines is an occupiable blank line the caret can land on:
        // give it BODY height so typing the first character causes no heave.
        // A single trailing newline (end-of-doc / one terminator) stays a
        // ~2pt phantom the reading skeleton never shows.
        let endsWithDoubleNewline = text.length >= 2
            && text.character(at: text.length - 2) == UInt16(UnicodeScalar("\n").value)
        mutateParagraphStyles(in: styled, range: NSRange(location: text.length - 1, length: 1)) { style, _ in
            if endsWithDoubleNewline {
                style.lineHeightMultiple = theme.bodyLineHeightMultiple
                style.minimumLineHeight = 0
                style.maximumLineHeight = 0   // let lineHeightMultiple drive body height
                style.paragraphSpacing = 0
            } else {
                style.maximumLineHeight = 2
                style.minimumLineHeight = 0
                style.lineHeightMultiple = 1
                style.paragraphSpacing = 0
            }
        }
    }
```
Update the call site (`:938` region) to drop the `caretOffset:` argument. Both callers (full render + patch) must call the same no-caret version so patch≡full holds.

- [ ] **Step 4: Run the new tests + all viewport/equivalence suites**

Run: `swift test --filter RevealFidelityTests && swift test --filter CaretLineAnchorTests && swift test --filter ProjectorEquivalenceTests`
Expected: PASS. If `ProjectorEquivalence` fails, the two clamp callers disagree — make both call the caret-free clamp. If an EXISTING RevealFidelity test (e.g. `testMidDocumentAbsorbedNewlineParagraphRevealIsHeightNeutral`, which asserted the blank line stays a ~2pt sliver when caret is on CONTENT) now fails: that test encoded the OLD caret-dependent behavior for a mid-document (single absorbed `\n`) block. A mid-document paragraph that absorbs ONE newline ends its slice in a single `\n` (not `\n\n`), so it still clamps to 2pt — that test should still pass. Confirm; if it legitimately changed, update it to the new caret-independent expectation and note why.

- [ ] **Step 5: CaretLineAnchor no-heave regression**

Add to `CaretLineAnchorTests` a case that drives the real scroll view, places the caret at the end of a heading block, applies Return then the first character, and asserts the caret line's screen-Y is identical across both (follow the suite's existing harness). This should PASS given Step 3's height equality; if it fails, the height fix is incomplete.

- [ ] **Step 6: Full suite + commit**

Run: `swift test`
```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinRender/AttributedRenderer.swift Tests/QuoinRenderTests/RevealFidelityTests.swift Tests/QuoinRenderTests/CaretLineAnchorTests.swift
git commit -m "CARET-1: blank-line height is caret-independent; \\n\\n line at body height (no heave)"
git push origin main
```

---

## Task 2: Backspace-merge — never delete a previous block's content

**Files:**
- Modify: `Sources/QuoinRender/AppKit/ReaderCoordinator.swift` (`gapDeletion` :2326, `handleGapDeletion` :2156)
- Test: `Tests/QuoinRenderTests/GapDeletionTests.swift` (extend)

**Interfaces:**
- Produces: `gapDeletion` hardened so a Backspace at the content/absorbed-whitespace boundary of a block whose slice has trailing newlines removes a newline (merge), never a content glyph.

- [ ] **Step 1: Reproduce symptom 3 as a failing pure test**

The bug: after `# heading\n\n`, deleting the just-typed character can land the caret at `contentEnd` (offset 9, end of `# heading`) rather than in the trailing-newline run (offset 10/11). `gapDeletion` fires only for `relCaret > contentEnd`, so at `relCaret == contentEnd` it returns nil and the system Backspace deletes `g`. Write the failing case:

```swift
    /// CARET-1 symptom 3: Backspace at the content boundary of a block that has
    /// an absorbed trailing blank line must remove a NEWLINE (merge toward the
    /// canonical separator), NOT delete the last content glyph.
    func testBackspaceAtContentBoundaryRemovesNewlineNotContent() {
        // "# heading\n\n" — caret at offset 9 (end of "# heading"), trailing = 2.
        let d = C.gapDeletion(sourceText: "# heading\n\n", relCaret: 9, forward: false)
        XCTAssertEqual(d?.utf16Range, 9..<10, "must delete a newline, not the 'g' at 8..<9")
        XCTAssertEqual(d?.caretUTF16, 9)
    }
```

Run: `swift test --filter GapDeletionTests` → this new case FAILS (returns nil today).

- [ ] **Step 2: Confirm the precise live repro (REQUIRED before changing the rule)**

Before changing `gapDeletion`'s boundary, confirm the ACTUAL live caret offset when symptom 3 fires — the fix depends on whether the caret lands at `contentEnd` (9) or inside the run (10/11). Reproduce in the app OR instrument: launch with `QUOIN_EDIT_PERF_LOG=1`, type `# heading`, Return, `x`, Backspace to line start, one more Backspace; read the `restoreCaret`/gap trace for the caret offset the second Backspace sees. Record the real offset in your report. (If you cannot drive the GUI, reason from the code path: after deleting `x` the paragraph empties and the block re-parses to just the heading; the caret is restored to the merge point — determine whether `caretMapping` puts it at 9 or 11.) The fix must target the real offset, not the assumed one.

- [ ] **Step 3: Harden the boundary rule**

Extend `gapDeletion` so a backward delete at `relCaret == contentEnd` (the content boundary) WHEN `trailing > 0` removes the FIRST trailing newline (merging toward the canonical `\n\n`), instead of returning nil:

```swift
        static func gapDeletion(sourceText: String, relCaret: Int, forward: Bool) -> (utf16Range: Range<Int>, caretUTF16: Int)? {
            let ns = sourceText as NSString
            guard relCaret >= 0, relCaret <= ns.length else { return nil }
            let trailing = sourceText.reversed().prefix(while: { $0 == "\n" }).count
            let contentEnd = ns.length - trailing
            guard trailing > 0 else { return nil }
            if forward {
                guard relCaret >= contentEnd, relCaret < ns.length else { return nil }
                return (relCaret ..< relCaret + 1, relCaret)
            }
            // Backward: fire when the caret is IN the trailing run OR exactly at
            // the content boundary with trailing newlines present. At the
            // boundary, delete the FIRST trailing newline (merge), never the
            // preceding content glyph.
            guard relCaret >= contentEnd, relCaret <= ns.length, relCaret > 0 else { return nil }
            if relCaret == contentEnd {
                // Only claim the boundary delete when MORE than the canonical
                // separator remains OR this is the last block's occupiable line;
                // otherwise a plain end-of-content backspace should still edit
                // content. Reproduce (Step 2) to set this predicate exactly.
                return (contentEnd ..< contentEnd + 1, contentEnd)
            }
            return (relCaret - 1 ..< relCaret, relCaret - 1)
        }
```

CAUTION: the `relCaret == contentEnd` branch must NOT hijack an ordinary Backspace at the end of a block that legitimately deletes the last content char (a block with content and no occupiable trailing blank line the user is editing). Use Step 2's real repro to decide the exact predicate (e.g. only claim it when `trailing >= 2`, i.e. an occupiable blank line exists beyond the canonical single separator). Add tests for BOTH: symptom-3 (merge) AND ordinary end-of-content backspace (still deletes content) so the fix can't over-claim.

- [ ] **Step 4: Tests green (both directions) + full suite**

Add the ordinary-end-of-content counter-test (Backspace at the end of a plain paragraph WITH content and only a single/zero trailing newline deletes the content char — `gapDeletion` returns nil). Run `swift test --filter GapDeletionTests` and `swift test`.

- [ ] **Step 5: Commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinRender/AppKit/ReaderCoordinator.swift Tests/QuoinRenderTests/GapDeletionTests.swift
git commit -m "CARET-1: Backspace at a block's absorbed-whitespace boundary merges, never deletes content"
git push origin main
```

---

## Task 3: Full-height caret overlay for compressed gaps (view layer)

**Files:**
- Modify: `Sources/QuoinRender/AppKit/QuoinTextView.swift` (caret/insertion-point draw path)
- Test: a `QuoinTextView` geometry unit test in `Tests/QuoinRenderTests/` if the suite supports view instantiation; else build-verified + manual.

**Interfaces:**
- Produces: when the insertion point sits on a compressed-gap line (near-zero `maximumLineHeight`, zero `paragraphSpacing`), the drawn caret is a body-height rect; layout is unchanged.

- [ ] **Step 1: Draw a body-height caret on compressed gaps**

Override the insertion-point rect / draw path in `QuoinTextView` (grep for the existing caret/`drawInsertionPoint`/`insertionPointColor` handling). When the caret's paragraph style indicates a compressed gap (detect via `maximumLineHeight` <= a small threshold, e.g. 3, and `paragraphSpacing == 0`), extend the drawn caret rect to body height (`theme`/font line height) centered on the gap. This is DRAW-ONLY — do not change layout, storage, or the fragment. Follow the existing decoration-draw precedent (`drawBackground(in:)` / the done-chip draw), which already paints ink without touching text.

- [ ] **Step 2: Build the app + confirm no layout change**

Run the app build. If a headless `QuoinTextView` geometry test is feasible, assert the caret rect height on a compressed-gap line exceeds the line height while the fragment frame is unchanged. Otherwise verify via the XCUITest in Task 5 and note it.

- [ ] **Step 3: Commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add Sources/QuoinRender/AppKit/QuoinTextView.swift
git commit -m "CARET-1: draw a full-height caret on compressed-gap lines (layout-neutral)"
git push origin main
```

---

## Task 4: ProjectorEquivalence + CRLF guards

**Files:**
- Modify: `Tests/QuoinRenderTests/ProjectorEquivalenceTests.swift`, and a CRLF case in `Tests/QuoinRenderTests/RevealFidelityTests.swift`

- [ ] **Step 1: Extend the equivalence script**

Add the CARET-1 sequence to the `ProjectorEquivalenceTests` interaction script: from an active heading/paragraph block, append `\n\n` then append `x` (the Return-then-type path), asserting the patched storage equals a full render at each step. This proves the caret-free clamp decisions are identical on both paths.

- [ ] **Step 2: CRLF height-stability case**

Add a RevealFidelity case: a CRLF-authored source whose last block's slice ends in `\r\n\r\n`. Assert the "ends with two newlines" detection is byte-stable — either it drives the same body-height branch, OR (per the accepted LF-only limitation) it stays clamped; assert whichever the implementation guarantees and document it. Do NOT let a CRLF file silently get an unintended body-height line that pushes content.

- [ ] **Step 3: Full suite + commit**

Run `swift test`.
```bash
git checkout Package.resolved 2>/dev/null || true
git add Tests/QuoinRenderTests/ProjectorEquivalenceTests.swift Tests/QuoinRenderTests/RevealFidelityTests.swift
git commit -m "CARET-1: patch≡full for Return-then-type; CRLF trailing-newline stability"
git push origin main
```

---

## Task 5: Behavioral XCUITest — pin symptom 3, verify the fix live

**Files:**
- Create: `App/macOS/UITests/CaretBlankLineTests.swift`

**Interfaces:** consumes the shell-created fixture pattern from `BehavioralSmokeTests` (fixture library made by the shell before the run; `QUOIN_BEHAVIORAL_LIB`).

- [ ] **Step 1: Write the behavioral test (real keys)**

```swift
import XCTest

/// CARET-1 behavioral guard: the Backspace-deletes-content symptom, driven with
/// real key events on the real app.
final class CaretBlankLineTests: XCTestCase {
    private var lib: String { ProcessInfo.processInfo.environment["QUOIN_BEHAVIORAL_LIB"] ?? "/tmp/quoin-caret1-fixture" }
    override func setUp() { continueAfterFailure = false }

    func testBackspaceOnBlankLineDoesNotEatHeading() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-QuoinLibraryPath", lib]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        let row = app.staticTexts["Note"]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.click()

        app.typeText("# heading")
        app.typeKey(.return, modifierFlags: [])   // real Return
        app.typeText("x")
        app.typeKey(.delete, modifierFlags: [])    // delete the "x"
        app.typeKey(.delete, modifierFlags: [])    // one more — must NOT eat the heading

        let value = editor.value as? String ?? ""
        XCTAssertTrue(value.contains("# heading"),
                      "Backspace on the blank line must not delete heading content; got: \(value.prefix(120))")
    }
}
```

- [ ] **Step 2: Run it — RED before Task 2's fix is confirmed, GREEN after**

Create the fixture from the shell (the test process is sandboxed): `mkdir -p /tmp/quoin-caret1-fixture && printf "" > /tmp/quoin-caret1-fixture/Note.md`. Then:
Run: `cd App/macOS && xcodegen && xcodebuild test -project Quoin.xcodeproj -scheme Quoin -destination 'platform=macOS' -only-testing:QuoinUITests/CaretBlankLineTests`
Expected: PASS now that Task 2 landed. (If Task 2 hadn't landed, this would FAIL — that's the point; it's the behavioral acceptance gate for symptom 3.)

- [ ] **Step 3: Commit**

```bash
git checkout Package.resolved 2>/dev/null || true
git add App/macOS/UITests/CaretBlankLineTests.swift
git commit -m "CARET-1: behavioral XCUITest — Backspace on a blank line never eats the heading"
git push origin main
```

---

## Final verification

- [ ] `swift test` — full suite green, including the new RevealFidelity/CaretLineAnchor/GapDeletion/ProjectorEquivalence cases.
- [ ] App builds; `xcodebuild test -only-testing:QuoinUITests/CaretBlankLineTests` and `.../BehavioralSmokeTests` both green on this Mac.
- [ ] **No heave, by test:** `testReturnBlankLineEqualsAfterFirstCharacter` + the CaretLineAnchor no-move case pass.
- [ ] **Caret is caret-independent height:** `testBlankLineHeightIsCaretIndependent` passes.
- [ ] **Backspace merges, never eats content:** the pure `gapDeletion` tests AND the behavioral XCUITest pass; the ordinary end-of-content counter-test still deletes content.
- [ ] **Manual (optional, but this is the fragile layer):** launch, type `# heading` → Return → confirm no visible heave; the caret is a normal line (not a dot); type + backspace round-trips cleanly. Per CLAUDE.md, judge zoomed, not from a downsampled screenshot.
- [ ] Update `docs/reference/invariants.md` (§ viewport & caret) to note blank-line height is byte-derived (caret-independent) and the `\n\n`→body-height rule.

## Notes for the redo sequence

This closes CARET-1 (the last of the three symptoms Clint hit live). Remaining audit work: the keystroke-intent grammar (RC-1) and the deferred edit-intent/caret-mapping extraction from the shell — both now sit on the `EditorCore` seam from sub-project ①.
