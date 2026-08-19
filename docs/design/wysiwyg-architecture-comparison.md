---
title: How WYSIWYG-markdown editors handle Return/empty-blocks/merge — and where Quoin sits
status: DECISION RECORD (for discussion)
created: 2026-08-12
related: docs/design/single-file-first.md, docs/superpowers/specs/2026-08-11-editable-islands-design.md
---

# WYSIWYG-markdown architecture: the source-of-truth decision

Prompted by two live-test bugs in the Phase 3 editable-islands build:

1. **Backspace-merge deletes a real character.** `# How to do things` + Enter,
   type `clint`, delete it, one more Backspace → `# How to do thins` (the `g`),
   caret mid-word. Trace: the merge edited at byte **16** — the heading's
   *rendered inline length* (`How to do things`) — instead of **18**, its
   *source range end* (`# How to do things`). `IslandController.fireBackspaceMerge`
   computes the separator from a predecessor byte range that came back 2 bytes
   short (the `# ` marker).
2. **The virtual line sits ~2× too far below the heading** until the first
   keystroke, then snaps to the expected position.

Both are **structural, not incidental** — they are the standing cost of the
source-of-truth choice. This doc records how the mature open-source editors
avoid them, and frames the decision.

## The two camps every excellent editor picks

No shipping OSS WYSIWYG-markdown editor makes the markdown *string* the live
source of truth **while also** doing block-level rendered editing. They split:

### Camp A — a structured block/node tree IS the truth; markdown is import/export

ProseMirror / TipTap / Milkdown, Lexical, Slate, and — the closest peer to
Quoin — **MarkText's Muya engine** (native-feeling, typewriter + focus modes,
block WYSIWYG). MarkText "regenerates a document's Markdown from its internal
block model on every save"; edits happen on the tree.

An empty paragraph is a **first-class node** (`<p></p>`). Consequently:

- **Return** = split the current node at the caret — a precise operation on
  addressable tree positions.
- **Backspace-at-start** = `joinBackward` — merge two nodes at their exact
  boundary. It *cannot* land mid-word in the predecessor; the boundary is
  structural.
- The caret always has a real node to occupy, even when empty.

ProseMirror's own guide names Quoin's exact pain points as the reason to avoid
a string-as-truth: *"Markdown collapses empty blocks; structural validity
becomes implicit, not enforced… character offsets shift constantly during
edits, making undo/selection preservation complex… every edit requires
re-parsing surrounding markdown to find block boundaries."*

### Camp B — raw markdown IS the live buffer, but it is a SOURCE editor

CodeMirror 6 / Obsidian Live Preview / atomic-editor. Raw markdown is
byte-lossless truth; decorations hide syntax except on the cursor's line. But
**the caret always sits in real source text — empty lines included, native to
a text editor.** There is no block materialization and no hidden newlines, so
the empty-paragraph problem never arises. It is a styled textarea, not a block
editor. (Tellingly, a design doc dedicated to this architecture doesn't even
discuss empty-block semantics — there is nothing to solve.)

## Where Quoin sits: a third thing neither camp does

Quoin wants **both**: markdown-string-as-live-truth (Camp B's byte-lossless
purity) **and** block-level rendered editing where a rendered heading is not
its source text (Camp A's true WYSIWYG). That combination is what forces the
"virtual line," and it maps the two bugs directly:

| Bug | Root friction | How each camp avoids it |
|---|---|---|
| Backspace-merge eats the `g` | character offsets shift; block ranges re-parsed; no structural boundary | Camp A: `joinBackward` merges at an exact node boundary, can't cross into content. Camp B: it's one text buffer; Backspace is just Backspace. |
| Virtual line 2× too low | markdown cannot represent the empty block the caret needs | Camp A: an empty `<p>` node sits at the right place. Camp B: an empty line is a real line. |

The editable-islands rework is Quoin drifting **toward Camp A** — an island is
a local editable model over one block. But the *document* truth stays the
markdown string, so every boundary op (Return-split, Backspace-merge) still
reconciles against markdown byte ranges. That reconciliation is where these
bugs live and will keep living.

## The options

### Option 1 — Keep the hybrid, harden the boundaries
Fix `fireBackspaceMerge` to derive the merge point from the predecessor's
*source range end*, and add a structural invariant "a merge never deletes
predecessor content." Ship-able now. Cost: the string-vs-block friction is
paid at *every* block boundary; expect a long tail of boundary bugs (the
CLAUDE.md "two recognizers diverge" pattern, at document scale).

### Option 2 — Go fuller Camp A: block tree as the live editing truth
An in-memory block/inline tree is the truth *during editing*; serialize to
markdown at save; parse on load (Muya's model, and ProseMirror's). Return =
split node; Backspace = join node; empty block = real node. Eliminates the
whole bug class. Cost: the largest change; must preserve byte-losslessness for
untouched regions across a parse→edit→serialize round-trip (achievable — keep
original source spans per node and re-emit them verbatim when untouched). This
is `single-file-first.md`'s open "how much projection stays on the common
typing path" question, answered decisively.

### Option 3 — Reconsider block-level rendered editing itself
Accept Camp B: a source editor with reveal-on-cursor decorations (Obsidian).
Never "true WYSIWYG," but Return/Backspace never break because they never leave
real text. Largest philosophical retreat from the handoff's rounded-block
vision.

## Recommendation (for debate, not settled)

- **Now:** fix the `fireBackspaceMerge` heading bug (Option 1 for *this*
  defect) — it is a real, contained correctness/data-loss bug regardless of the
  larger decision.
- **Strategically:** the *pattern* of bugs is the signal that the source-of-truth
  question is the real decision. No shipping editor makes the string the live
  truth **and** does block WYSIWYG. Weigh Option 2 seriously against the cost of
  an indefinite boundary-bug tail under Option 1.

The debate that follows this doc stress-tests Option 1 (harden the hybrid) vs
Option 2 (block tree as editing truth).

## The debate (two independent models, opposing stances, both 8/10)

**FOR migration (gpt-5):** Both bugs vanish *by construction* — an empty
paragraph is a real node; a join operates at a node boundary and structurally
cannot delete predecessor content. Byte-losslessness is preserved by per-node
segment spans (leadingTrivia / openMarker / contentRun / closeMarker /
trailingTrivia, each with a `fileByteRange` + checksum + `pristine` flag):
re-emit pristine subtrees verbatim, regenerate only dirty subtrees, validate
with a rolling checksum. Bonus: synchronous tree ops remove the async
edit/echo path that jeopardizes "type, Return, paste." ~10–15 weeks, phased
(tactical merge fix now → shadow tree behind a flag → switch Return/Backspace
to tree ops → promote tree to truth → expand to tables/lists/fences). Main
risk it names: precise byte-span recovery across *all* markdown edge cases, and
the TextKit 2 bridge.

**AGAINST migration (gemini-2.5-pro):** The bugs are ordinary boundary defects
— fix the merge from the *pre-edit* AST source ranges and add the invariant "a
merge's splice must not touch the predecessor's content range." The virtual-line
2× is a view-layer bug, not a data-model one. String-as-truth is Quoin's
*defining* characteristic and the cleanest possible enforcement of "markdown
files are truth on disk." A tree serializer introduces a translation layer that
trades *visible, containable* UI glitches for *invisible, catastrophic* on-save
corruption — a worse failure mode. The migration is a massive rewrite with a
permanent serializer maintenance tax (every CommonMark/GFM quirk must round-trip
perfectly); hardening is localized and converges.

**Where they agree (unanimous):**
1. Fix the merge bug NOW using the predecessor's pre-edit source-range end, plus
   a structural "a merge never deletes predecessor content" invariant.
2. The tree model is genuinely better for edit-time structural purity and future
   features (collaboration, block transforms).
3. Byte-losslessness is the crux constraint.

**The real crux — and it is empirically testable.** The disagreement reduces to
one question: *can a tree→markdown serializer preserve byte-fidelity across real
files?* gemini's central fear (invisible on-save corruption) and gpt-5's central
claim (pristine-subtree-verbatim + checksums) are the same question with
opposite priors. It does **not** require committing 10–15 weeks to answer: build
only the *shadow tree + span-retaining serializer* (gpt-5's phase 2) and run a
property/fuzz test — `parse → serialize` must be byte-identical — across a large
corpus (Clint's real `~/Documents/ClintNotes` + the torture fixtures). If the
round-trip is clean across thousands of real files, gemini's risk is largely
retired and the migration bet is safe. If it is not clean, that is decisive
evidence to stay hybrid. **Answer the crux with a cheap experiment before betting
the quarter.**

A useful reframing: the editable-islands work is already a partial migration —
an island *is* a local editable model over one block. The bugs live at the seam
between islands and the string. So the decision is less "rewrite to a tree" than
"should the islands compose into a persistent tree, or keep reconciling
individually to the string?" — which makes the "massive rewrite" framing smaller
than it first appears.

### Decision (recommended sequencing)
1. **Now:** the unanimous merge fix (pre-edit source range + no-touch-predecessor
   invariant). Data-loss bug; do it regardless of the strategic call.
2. **Next (bounded, ~1–2 weeks):** the round-trip fuzz experiment on the shadow
   tree + serializer. This *is* the decision input.
3. **Then:** commit to Option 1 or Option 2 based on the fuzz result, not on
   priors.

## Sources
- ProseMirror Guide — https://prosemirror.net/docs/guide/
- ProseMirror joinBackward discussions — https://discuss.prosemirror.net/t/joinbackward-behavior/3296
- Lexical Editor State — https://lexical.dev/docs/concepts/editor-state
- @lexical/markdown — https://lexical.dev/docs/packages/lexical-markdown
- Obsidian-style Live Preview in CodeMirror 6 (atomic-editor, HN) — https://news.ycombinator.com/item?id=48345201
- CodeMirror live-markdown design doc — https://github.com/blueberrycongee/codemirror-live-markdown
- MarkText / Muya architecture — https://deepwiki.com/marktext/marktext/3.2-markdown-parsing-and-rendering
