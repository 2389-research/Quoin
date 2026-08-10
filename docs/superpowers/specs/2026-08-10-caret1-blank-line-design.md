---
title: CARET-1 — blank-line height, viewport stability, and backspace-merge
created: 2026-08-10
status: APPROVED (design); implementation plan to follow
related:
  - docs/superpowers/specs/2026-08-10-editing-lifecycle-first-principles-issues.md (CARET-1, RC-2)
  - docs/reference/invariants.md (§ viewport & caret invariant)
---

# CARET-1 — blank-line height, viewport stability, and backspace-merge

## The bug (live-confirmed by Clint)

Markdown has no empty-paragraph node, so when the caret must sit on a blank line
between/after blocks, the renderer synthesizes it: the active block's
`editableSlice` **absorbs** trailing/inter-block whitespace beyond the canonical
`\n\n`, and three **caret-position-keyed** height clamps paper over the visual.
Symptoms:

1. Type `# heading`, press Return → **huge gap** (the literal `\n\n` renders as
   full-height lines) that **collapses** to a normal paragraph gap the instant
   the first character is typed → the page *heaves on Return, un-heaves on
   keystroke*.
2. In another caret state the caret renders as a **tiny 2pt dot** (blank line
   clamped).
3. Backspace to the start of the new line + one more Backspace **deletes the
   last content char of the previous block** (the `e` in "developer").

**Root cause (RC-2):** rendered line **height is a function of caret position**,
which the viewport invariant forbids — height must be a pure function of
document state.

## Approach (B — caret-geometry; PAL-reviewed)

Do NOT model the gap as a synthetic empty-paragraph node (approach A): reveal
fidelity requires the active block's revealed source to be **1:1 with the file
bytes**, and a not-byte-backed node fights that. Instead, keep the source exactly
as-is and fix the one thing that is actually wrong — height reading the caret —
plus a small session-layer backspace rule and a view-layer caret overlay.

### 1. Height becomes a pure function of document state

Remove the two caret-conditional branches in the reveal clamps:
- `AttributedRenderer.clampTrailingNewlinePhantom` (~line 1069): delete the
  `if let caretOffset, caretOffset >= text.length { return }` early-return.
- `AttributedRenderer.compressInteriorBlankLines` (~line 1111): delete the
  `if let caretOffset, caretOffset >= line.location, caretOffset <= NSMaxRange(line) { continue }`
  caret guard. Keep the `previousNonBlankSpacing` rule (loose lists must not
  double-space).

After this, blank-line height depends only on the slice's bytes, never the caret.

### 2. Kill the "heaves on Return" jump at its source

In `clampTrailingNewlinePhantom`, make the final terminator's line metrics a pure
function of the slice's trailing bytes:
- If the slice ends with **two** newlines (`\n\n`), style that final blank line
  at **body height** (Theme body line metrics), so it already equals the height
  of the line after the first character is typed → **zero height delta on the
  first keystroke** → no heave.
- Otherwise (end-of-document / single-terminator), keep the existing ~2pt
  collapsed phantom.

This is byte-driven, not caret-driven. `clampedSeparator` /
`revealNeedsClampedSeparator` (already pure over the slice's trailing newline)
are unchanged.

### 3. Backspace-merge at the session/edit layer (fixes symptom 3)

Backspace when the caret is in a block's **absorbed trailing whitespace** must
remove one newline **byte** (never a content glyph of the previous block), and
merge the blocks only when the canonical `\n\n` separator remains. This hardens
the existing gap-deletion path (`gapDeletion` / `handleGapDeletion`): the rule
keys on "caret UTF-16 offset in the slice is past the block's content length but
within the slice" using the byte ranges already available (`block.range` +
`caretMapping`). No renderer change; a bounded key-handler rule. It must be
symmetric for forward-delete.

### 4. Caret legibility in compressed gaps (view layer, layout-neutral)

Where a blank line is a visual sliver (a compressed gap the caret sits on), draw
a **full-height caret overlay** at the gap so the caret is visible — WITHOUT
changing layout. This is the one net-new UI behavior, isolated to
`QuoinTextView`'s draw path; it detects a compressed gap from the paragraph style
(near-zero `maximumLineHeight`, zero `paragraphSpacing`) and paints a body-height
caret there. Layout, byte-losslessness, and reveal fidelity are untouched.

## Non-negotiables preserved

- **Byte-lossless:** styling + a session-layer backspace rule only. No invented
  bytes; the on-disk `.md` is untouched until the user types a real character.
- **Reveal fidelity:** the revealed slice stays exactly the source bytes (1:1);
  hidden delimiters remain 1pt clear text.
- **Viewport invariant:** height no longer depends on the caret, so the caret
  line cannot move on a projection change; the "heave" is eliminated by height
  equality (§2).
- **Patch ≡ full render:** the clamp/separator functions are single-derivation
  and shared by both paths (`ProjectorEquivalenceTests`), so removing the caret
  branches keeps them equal.

## Testing (all runnable on this Mac, headless + XCUITest)

- **`RevealFidelityTests` — height equality:** render a heading/paragraph block
  revealed with a slice ending `\n\n`; record the final blank line's height.
  Apply the first-character edit; re-render; assert the height is **equal**
  (the direct guard for symptom 1). Also assert an interior blank line's height
  is identical whether or not the caret is on it (symptom 2 / §1).
- **`CaretLineAnchorTests` — no screen-Y move:** drive a real `NSScrollView`
  with the block visible, caret at block end; apply Return then the first
  character; assert the caret line's screen-Y is identical across both.
- **`ProjectorEquivalenceTests`:** extend the interaction script with
  append-`\n\n` then append-`x` on the active-block patch path; assert patched
  storage equals a full render.
- **Backspace-merge unit tests** (pure `gapDeletion`-level): caret at the start
  of an absorbed blank line, Backspace removes one newline and never a content
  char; the last one merges into the previous block; forward-delete symmetric;
  with 1 / 2 / 3+ trailing newlines.
- **CRLF fixture:** the "ends with two newlines" detector is byte-stable; a
  CRLF-authored file drives the same clamp branch (or, per the accepted LF-only
  limitation, is explicitly documented).
- **XCUITest (behavioral, real keys):** type `# heading` → Return → type `x` →
  Backspace to line start → one more Backspace → assert the heading text is
  intact (`# heading`, not `# headin`). This is the failing test that pins
  symptom 3 today and goes green when §3 lands.

## Risks & guards

- **Mis-classifying the trailing-newline shape** (CRLF, odd whitespace) could
  give an unintended body-height line that pushes content. Guard: byte-aware
  detection + the CRLF fixture + the height-equality test.
- **The caret overlay** could paint a tall caret in the wrong place; it is
  view-only and cannot change layout, and is covered by a `QuoinTextView`
  geometry check. If the overlay proves fiddly, the fallback is a minimum
  caret-rect height on compressed gaps (still layout-neutral).
- This is the fragile layer that has shipped "verified by one readout" bugs;
  every change lands with its headless assertion in the same commit, and the
  XCUITest gate runs on this Mac.

## Non-goals

The synthetic empty-paragraph node (A), the keystroke-intent grammar, and the
broader edit-intent/caret-mapping extraction from the shell are out of scope.
This spec fixes CARET-1's three symptoms with the minimal, byte-lossless change.
