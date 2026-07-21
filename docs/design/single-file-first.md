---
title: Single-file-first — a first-principles re-think
status: PROPOSAL (for discussion)
created: 2026-07-21
---

# Single-file-first — a first-principles re-think

Clint's directive (2026-07-21): *"Re-think the app from first principles as
something that works on a single file with excellence, and re-layer project
folders / 'vaults' (Obsidian nomenclature) on top."* This doc diagnoses why the
current architecture keeps producing the bugs we're seeing in the field, and
frames the re-layering. It is for discussion — not a committed plan yet.

## The symptoms (from the field, v1.2–1.3 RC testing)

Two clusters, both hurting the *most basic* use — open a file and write:

- **Core editing wedges.** Typing the first line then pressing **Return does
  nothing**. Pasting a big block then pressing **Return does nothing**. These
  are the absolute floor of a text editor, and they fail.
- **Shell fragility around single files.** ⌘N no-ops with no library; ⌘W won't
  close an empty window; dragging N files to the Dock spawns N blank unclosable
  windows (#41); a lone file opens inside library chrome. Every one of these is
  the *single-file* path being an afterthought on a *library-first* shell.

## Root diagnosis

**Two architectural roots, one theme: the single file is not the foundation.**

### 1. The edit path is a projection with an async echo round-trip

The editor is a projection of the markdown string, not a normal text view. So
the `NSTextView`'s storage is *never* the source of truth: `shouldChangeTextIn`
returns `false` for essentially every keystroke, routes the intent through
`DocumentSession`, and waits for the re-parsed result to **echo** back. While
that echo is in flight, further keystrokes are **queued** (`awaitingEditEcho` +
`pendingCommands`, with a watchdog to un-wedge a lost echo). See
`ReaderCoordinator.textView(_:shouldChangeTextIn:)`.

This is elegant for byte-losslessness and reveal fidelity — but it makes the
*common* case (type, Return, paste) ride the *hard* path. A burst (fast typing,
a paste, a Return right after a line) can outrun or lose the echo, and the
queue/watchdog logic — not the keystroke itself — decides whether your Return
survives. **The floor of the app depends on the most complex code in it.**

### 2. The shell is library-first; the single file is bolted on

`MainWindow` owns a `LibraryModel`; a window *is* a library-with-tabs; ⌘N means
"new document *in the library*"; restoration keys on library-relative paths.
Single-file editing (#18), untitled scratch docs, Finder-open, multi-file drop —
all are special cases grafted onto that model, and each graft is where a bug
lives.

## The vision: single-file excellence first, vault as a layer

Invert the dependency. Two layers, with the arrow pointing *up*:

- **Layer 0 — the document.** Open one `.md` file and write into it flawlessly.
  Rock-solid keystrokes (Return, paste, undo) on the common path; byte-lossless
  save; reveal/edit fidelity. This layer knows **nothing** about libraries. It
  is a document window, first-class, complete on its own.
- **Layer 1 — the vault.** A folder of files, with navigation, search, outline,
  cross-file features — a *sidebar over many Layer-0 editors*. Optional. The
  editor never depends on it; the vault composes editors, not the reverse.

"Vault" (Obsidian's word) captures the intent: a folder you point Quoin at, not
a database the app is built around. A window can be a bare document (no vault) or
a document *within* a vault — but the document code is identical either way.

### What "single-file excellence" demands of the edit path

The common typing path must be **simple and reliable**, even if the fancy
projection features stay for the rest:

- Plain text entry, Return, and paste should be as dependable as `TextEdit`'s —
  never gated behind an async echo that can wedge. Options to explore: let the
  text view own its storage for plain runs and *reconcile* to the source
  afterward (instead of intercepting every keystroke), or make the echo path
  synchronous/coalesced for simple inserts so a queue can never strand a Return.
- The projection/reveal machinery (1:1 source, hidden delimiters, embed edit)
  layers on top of a reliable text substrate — not underneath it.

## Connection to work already in flight

This is not a from-scratch rewrite; several current threads *are* steps toward
it:

- **`EditorViewModel` extraction (ADR-0010).** Pulling the platform-free editing
  core out of `ReaderModel` is exactly the Layer-0 boundary. Finishing it (and
  simplifying the echo/queue path while we're in there) is the natural first
  move.
- **Untitled scratch documents + single-file mode (#18).** Already nudging
  toward "a document without a library." The re-layer makes that the *default*,
  not a branch.
- **Restoration ADR-0009 (WindowGroup, not NSDocument).** Worth revisiting under
  this lens: a document-window-first shell may want a document-based container
  after all — the decision we deferred.

## Proposed next steps

1. **Stabilize the floor first (urgent, independent of the re-arch).** Reproduce
   the Return-wedge with `QUOIN_EDIT_PERF_LOG` (watch `awaitingEditEcho` /
   `pendingCommands` / the watchdog around a paste + Return), and make the simple
   typing path un-wedgeable — even as a targeted fix — so users can write *today*.
2. **Write the Layer-0 contract.** Define exactly what a bare document editor is
   and guarantees, with the keystroke path as a first-class, test-covered
   surface (not "verified by the app UI tests").
3. **Re-layer the shell** so a window is a document first, optionally inside a
   vault — folding in the #41/⌘N/⌘W/single-file fixes as *consequences* of the
   new model rather than patches.

## Open questions for Clint

1. **Appetite/sequencing:** stabilize the edit path with targeted fixes first
   (keep shipping), *then* re-layer — or treat the re-layer as the fix and do it
   as one deliberate arc?
2. **How much projection to keep on the common path?** Is "text view owns plain
   typing, reconcile to source after" acceptable, or must every keystroke stay
   byte-mediated (the current invariant)? This is the crux of the edit-path
   simplification.
3. **Vault scope:** is the vault purely navigation/organization over files
   (search, outline, links), or does it own cross-file state (the review loop,
   backlinks) that the document layer must be aware of?
