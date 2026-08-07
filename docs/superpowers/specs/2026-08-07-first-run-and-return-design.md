---
title: First-run excellence — the Return key and the first window
status: APPROVED (design); implementation plan to follow
created: 2026-08-07
supersedes: nothing
related: docs/design/single-file-first.md, docs/design/principles.md
---

# First-run excellence — the Return key and the first window

Clint's directive (2026-08-07): *"We have a really bad first-run experience. In
many cases you cannot even type a line of text and then hit enter… I also think
we need to spend more time just making the first window someone sees easy to
interact with."*

Two independent failures produce one impression — that Quoin does not work:

1. **Return is dead in prose.** Type a line, press Return, nothing happens.
2. **The first window asks a filing-system question** before the user has
   written a word, and never offers "just start writing."

This document specifies both fixes. It deliberately does **not** re-architect
the editing path; see [Non-goals](#non-goals).

## Part A — the Return contract

### Diagnosis (evidenced, not inferred)

A probe against the real parser (`MarkdownConverter.parse`) establishes the
ground truth:

```
SOURCE "A\n\nB" → 2 blocks
  [0] paragraph range=(0,1) = "A"
      GAP → "\n\n"           ← owned by NEITHER block
  [1] paragraph range=(3,1) = "B"

SOURCE "A\n\n\nB" → 2 blocks
  [0] paragraph range=(0,1) = "A"
      GAP → "\n\n\n"
  [1] paragraph range=(4,1) = "B"
```

Two facts follow, and the whole design rests on them:

- **A paragraph's byte range covers only its content**, never the newlines that
  follow it. The blank line between two paragraphs belongs to no block.
- Therefore **the caret has no legal position in the gap**. There is nowhere for
  it to stand between two blocks.

Combined with markdown semantics — a lone `\n` inside a paragraph is a *soft
break*, which re-parses to the same single block and renders as a space — the
current behavior is fully explained. Return inserts one `\n`; the document
re-parses to a byte-identical projection; the caret cannot advance. Return is
not flaky, it is **semantically dead**.

A partial fix shipped for end-of-document only (commit `d8dfdbd`). It worked
there for a reason that does not generalize: **the last block has no separator
after it.** Mid-document, the renderer injects a projection-only separator
between block fragments, so an editable slice that also absorbs the gap
newlines would render the gap twice.

### The rule table

Return consults **one table, keyed on `BlockKind`**. Every Return path routes
through it; there is no second recognizer.

| Block kind | Return inserts | Rationale |
|---|---|---|
| `paragraph`, `heading` | `\n\n` — a real paragraph break | The fix. A lone `\n` is a soft break. |
| list item | existing marker continuation; empty item ends the list | Already implemented (`listContinuationEdit`); now test-pinned. |
| `blockQuote` | `\n> ` continuation; empty quoted line exits the quote | Mirrors lists. Without it, Return escapes the quote. |
| table | at the end of a row: `\n` plus an empty pipe skeleton matching the header's column count. Anywhere else in the table: plain `\n` | **A blank line terminates a table.** `\n\n` here destroys user data. |
| `codeBlock`, `mathBlock`, `diagram`, `htmlBlock`, `frontMatter`, `reviewEndmatter` | plain `\n` | Verbatim source; a newline is a newline. |
| ⇧Return, anywhere in prose | CommonMark hard break | Keeps the soft-break capability reachable. |

**The rule keys on `BlockKind`, never on `EditingFlavor`.**
`EditingFlavor.of` (`BlockPresentation.swift:20`) classifies tables as `.prose`
alongside paragraphs. Flavor answers "how does this block *reveal*"; the Return
table answers "what does Return *mean*". They agree for four of six kinds — the
exact shape that ships a bug later. This is the CLAUDE.md "two recognizers for
one grammar WILL diverge" pitfall; the mitigation is to have only one.

### Where the caret lives: excess-whitespace absorption

Mid-document, `\n\n` at the end of paragraph `A` yields `A\n\n\nB`. The gap is
now three newlines and still belongs to no block. The active block's editable
slice must give the caret a home.

**Rule: a prose block's editable slice absorbs only the whitespace in excess of
the canonical `\n\n` block separator.** Not the whole gap.

Precisely: let `gap` be the raw bytes between this block's end and the next
block's start. **If `gap` ends with exactly `\n\n`, the slice is
`content + gap.dropLast(2)`; otherwise the slice is `content` and nothing is
absorbed.** The final `\n\n` always remains the separator.

Stated conservatively on purpose. The consequences:

| Gap | Ends with `\n\n`? | Absorbed | Note |
|---|---|---|---|
| `\n\n` | yes | nothing | Canonical — every existing document. |
| `\n\n\n` | yes | `\n` | One Return pressed. |
| `\n\n\n\n` | yes | `\n\n` | Two Returns pressed. |
| `\n` | no | nothing | Tight construction (`# H\nA`) — real, not an edge case. |
| `\n   \n` | no | nothing | Whitespace-only lines are left strictly alone. |

Absorption never inspects, normalizes, or rewrites what it absorbs; it only
changes which block's editable slice those bytes fall inside. Any gap Quoin does
not recognize as canonical-plus-excess behaves exactly as it does today.

| Source | Gap | Absorbed | Slice for block A | Effect |
|---|---|---|---|---|
| `A\n\nB` | `\n\n` | nothing | `A` | **No change to any existing document.** |
| `A\n\n\nB` | `\n\n\n` | `\n` | `A\n` | One occupiable blank line. |
| `A\n\n\n\nB` | `\n\n\n\n` | `\n\n` | `A\n\n` | Two occupiable blank lines. |

This is the load-bearing refinement. Absorbing the *whole* gap — the obvious
reading of "extend the slice" — would make every prose block in every existing
document grow a caret-occupiable blank line, changing the projection on the most
common editing path and putting the viewport invariant at risk everywhere.
Absorbing only the excess collapses the blast radius to documents where the user
actually pressed Return.

The last block keeps its existing end-of-document behavior (absorb through EOF).

### Deletion symmetry

- Backspace on an occupiable blank line deletes one newline; the caret rises one
  line.
- Backspace on the *last* occupiable blank line deletes the final excess
  newline, returning the gap to canonical `\n\n` and merging the caret back to
  the end of the paragraph.
- Backspace at the start of a paragraph with a canonical gap before it merges
  that paragraph into the previous one (existing behavior, unchanged).
- Forward Delete is symmetric toward the following block.

### Two regressions this must not cause

1. **`separatorUnchangedAcrossEdit` asymmetry.**
   `AttributedRenderer.swift:633` derives the *old* separator from
   `substring(in: block.range)` — the raw range — while deriving the *new* one
   from the extended slice. This is harmless today only because line 632
   short-circuits whenever either side is the last block, and slice extension
   applies only to the last block. The moment slices generalize mid-document,
   the two derivations disagree, `revealNeedsClampedSeparator` flips
   spuriously, and the per-keystroke patch path bails to a full re-render on
   every keystroke near a block end. **Both sides must derive from
   `editableSlice`.** Verified by reading the source; found by PAL review.

2. **Separator double-counting.** `revealNeedsClampedSeparator`
   (`AttributedRenderer.swift:1119`) fires when a revealed slice ends in `\n`,
   and `clampedSeparator` clamps the *first* separator newline to near-zero
   height. With N absorbed newlines the clamping arithmetic has to balance, or
   the gap renders twice — once from the slice, once from the separator. This is
   the one area where iteration is expected.

Both are guarded by `ProjectorEquivalenceTests` (patch-vs-full-render
equivalence) plus `RevealFidelityTests` and `CaretLineAnchorTests` (the viewport
invariant). Per CLAUDE.md, all three suites must be extended in the same commit
as any new projection path.

### Blank lines are preserved exactly

Pressing Return four times writes four blank lines into the `.md` and they stay
there — through save, quit, and reopen. This follows byte-losslessness and
matches Obsidian, iA Writer, and Typora. Silently collapsing them would mean a
save moves the user's text, and capping them would reintroduce "Return does
nothing" in a narrower form.

A `Format ▸ Tidy Blank Lines` command offers explicit, undoable cleanup. Nothing
is ever removed automatically.

## Part B — the shell and the first window

### Diagnosis

`MainWindow.swift:95` gates first run on
`if openTabs.isEmpty && !library.hasLibrary { chooseLibraryPrompt }`. That pane
offers three co-equal buttons — `[Open a File…]`, `[Create a Starter Library]`,
`[Choose an Existing Folder…]` — and **no way to just start writing**.

⌘N already does the right thing (`ScratchStore.createUntitled()` — an instant,
autosaved, quit-surviving untitled document), but the first screen never says
so. The screen asks for a filing decision at the moment of creation, which is
precisely what `docs/design/principles.md` forbids: *"A 'decide first' modal is
a smell at the moment of creation; it belongs at the moment of commitment."*

The library-first *architecture* is not the problem here and is not changed by
this work. Only the first 0.5 seconds and the entry-path routing change.

### The first window is a document

`chooseLibraryPrompt` stops being the first-run gate. In `MainWindow.onAppear`
(line 327), **after** every existing drain — `connectLibrary`, `restoreTabs`,
`drainPendingOpenURLs`, `consumePendingDeepLink`, `claimPendingSelectionSeed`,
scratch reopen — if and only if the window still has nothing open and no library
connected, create an untitled scratch document and place the caret in it.

Ordering is load-bearing: a Finder double-click must never race an auto-untitled
document into existence beside it.

A dismissible banner sits below the caret:

> **Untitled note — saved automatically.** ⌘S to give it a home.
> `[Open a File…]` `[Connect a Library…]` `(×)`

It fades on first keystroke.

### Entry paths

Every way into the app lands somewhere sane:

| Entry | Landing |
|---|---|
| Cold launch, nothing to restore | Blank untitled doc, caret in it, sidebar collapsed, banner |
| Cold launch, session had docs | Those tabs restored; **no** auto-untitled |
| Cold launch, leftover scratch docs | Reopened (existing); no extra untitled |
| Finder double-click / Open With | One window, that file as the only tab, no library chrome |
| Drag 1 file to the Dock icon | Tab in the frontmost window; one new window if none exists |
| Drag N files to the Dock icon | **One** window, N tabs, zero blank orphans (issue #41) |
| ⌘O, multi-select | Tabs in the key window |
| Drag file(s) onto a window | Tabs in that window |
| Drag a folder onto a window / Dock | Non-modal offer: *Connect "Notes" as this window's library?* — never a silent re-root |

### Issue #41 — blank, unclosable windows

Dragging three `.md` files to the Dock opens one correct window plus three blank
windows that cannot be closed.

`application(_:open:)` (`QuoinApp.swift:870`) only *queues* opens via
`requestOpen`; it never spawns windows. The leading hypothesis is that
`WindowGroup(id: "main", for: String.self)` auto-spawns a scene per open
request, amplified by the `CFBundleTypeRole=Editor` doc-type registration —
macOS's document-open machinery creating a window per file even though Quoin is
not `NSDocument`-based. There is no `handlesExternalEvents` declaration anywhere
in `QuoinApp.swift`, which fits.

**This must be reproduced and the mechanism confirmed before any change is
made.** The likely mitigation is to declare the scene as handling no external
events and funnel every open through the AppKit delegate. Independently — belt
and braces — any window that does end up empty must be trivially closable, since
"unclosable" is the enraging half of the bug.

### Library setup, demoted but discoverable

- `File ▸ Connect a Library…` and `File ▸ Open Folder as Library…` become
  always-available menu items rather than first-run-only buttons.
- Dropping a folder on a window offers to connect it.
- The existing opt-in sample-documents card after a library pick is unchanged.
- The `emptyState` pane (library connected, no document open) already leads with
  **New Document** and is unchanged.

### Housekeeping

- Do not persist a window session whose only tab is an empty scratch document
  (otherwise a blank untitled reopens forever).
- GC empty scratch files at launch as well as on close.

### Deferred

Hiding the library sidebar whenever no open tab lives inside the library. It
would fix "a lone file opens inside library chrome," but it makes ⌘0 conditional
on which tab is showing, which may read as the sidebar vanishing on its own.
Ship the rest first and re-evaluate against the real app.

## Non-goals

**The editing path is not re-architected.** `single-file-first.md` asks whether
the common typing path should stop riding the async-echo projection round-trip.
The probe answers a narrower question decisively: the echo queue did not kill
Return — markdown semantics did. Moving to view-owned storage would trade one
diagnosed bug for a class of caret-mapping, IME-composition, and
undo-reconciliation bugs against a projection whose invariants are the app's
most load-bearing. Independently reached by PAL review.

The Layer-0 / Layer-1 re-layering question stays open, unfixed by this work and
unblocked by it. Issue #44 (keystrokes dropped during activation) is untouched.

## Testing

Every behavior above is pinned by tests in the same commit that introduces it.

- **Pure Return-table tests** (`QuoinCoreTests` / `QuoinRenderTests`): one case
  per block kind in the rule table, including the table case that proves `\n\n`
  is never inserted into a table.
- **Excess-absorption tests**: the slice for each row of the gap table —
  `A\n\nB`, `A\n\n\nB`, `A\n\n\n\nB`, the tight gap `# H\nA`, and the
  whitespace gap `A\n   \nB` — plus the unchanged last-block EOF behavior. The
  `A\n\nB`, tight, and whitespace cases are the regression guards proving
  existing documents are untouched.
- **Deletion symmetry tests**: Backspace at start, middle, and end of a gap with
  1, 2, and 3+ newlines; Forward Delete symmetry.
- **`ProjectorEquivalenceTests`**: interaction script extended with
  mid-document Return, per CLAUDE.md's requirement when touching any projection
  path.
- **`RevealFidelityTests` + `CaretLineAnchorTests`**: extended for the new
  projection path — the caret line must not move on screen when Return
  re-projects.
- **Patch-path regression test**: typing at the end of a mid-document paragraph
  stays on the per-keystroke patch path (proves the
  `separatorUnchangedAcrossEdit` fix works).
- **Entry-path tests**: the auto-untitled guard — that a pending Finder open, a
  restored session, and a reopened scratch document each suppress it.
- **Round-trip test**: four Returns, save, reopen — byte-identical.

## Open questions

None blocking. The separator-clamping arithmetic (Part A, regression 2) is the
one area where implementation is expected to iterate against
`ProjectorEquivalenceTests` rather than land right the first time.
