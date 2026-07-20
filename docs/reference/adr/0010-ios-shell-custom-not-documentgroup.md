# 0010 — iOS/iPadOS shell: custom shell + shared view-model, not DocumentGroup

**Status:** Accepted (2026-07-20)

**Context.** Quoin ships a mature macOS editor and an iOS *reader* only. Building
a real iOS/iPadOS *editing* shell forces two architecture decisions: (A) the
app-shell container — Apple's document architecture (`DocumentGroup`/
`NSDocument`) vs. the custom `WindowGroup` + `LibraryModel` + `WindowSessionState`
model that shipped in macOS 1.2.0 (see [ADR 0009](0009-restoration-around-windowgroup-not-nsdocument.md));
and (B) the editing view-model — `ReaderModel` is macOS-only today, contradicting
CLAUDE.md's "view models are platform-free" principle. Full analysis in
[docs/design/ios-app-shell.md](../../design/ios-app-shell.md).

**Decision.**

- **A2 — custom shell, not `DocumentGroup`.** Keep the session-actor-as-truth
  model (`DocumentSession` is the source of truth, not an `NSDocument` in-memory
  model). A document-based rewrite would risk the byte-losslessness and conflict
  machinery for framework conveniences we can approximate. **Constraint:**
  architect the shell so a document-based / iCloud Drive layer can be added
  LATER without a rewrite — iCloud is a *nice-to-have*, not day-one; isolate
  file provenance behind a seam so an iCloud/file-provider backing can slot in.
- **iPad is a first-class editor** at launch (hardware keyboard, multi-column,
  pointer), not a scaled-up phone reader.
- **B1 — extract the platform-free editing view-model FIRST**, before the iOS
  editor UX. Move `ReaderModel`'s platform-independent core (projection ↔ source,
  caret/reveal state + offset math, autosave orchestration, held-preview,
  outline/stats/scroll-target) into a shared platform-free view-model; macOS
  `ReaderModel` becomes a thin `NSTextView` adapter over it, and the iOS editor
  becomes the `UITextView` adapter. Do it behind the RevealFidelity /
  CaretLineAnchor / ProjectorEquivalence suites so macOS is never destabilized.

**Consequences.** No macOS rewrite; the proven spine stays. We reimplement what
`DocumentGroup` gives free (document browser, iCloud) ourselves if/when needed —
accepted, and de-risked by the "add it later without a rewrite" constraint. The
B1 refactor pays down real, already-claimed debt (the aspirational platform-free
view-model) as a deliberate byproduct, and every iOS-shared line is guarded by
the existing invariant suites. Revisit A2 only if iCloud/Files.app becomes a
headline day-one requirement.
