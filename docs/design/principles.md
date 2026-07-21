---
title: Quoin design principles
created: 2026-07-20
---

# Quoin design principles

Cross-cutting product principles that guide UX decisions. Where a specific screen
is spec'd in [`handoff.md`](handoff.md), that wins; this doc is the *why* behind
the calls, and the tie-breaker when the handoff is silent.

## Frictionless creation, deferred commitment

**Never gate the start of an action behind a decision or a modal. Let the user
begin instantly, make the work safe automatically, and defer the heavyweight
choice (name, location, structure, format) to the moment the user actually
reaches for it.**

The canonical example is **⌘N with no library configured.** The tempting fix is
a save panel — "choose where to save the new document" — before the user has
typed a word. That's wrong: it taxes the cheapest, most frequent action (making
a thing) with a question the user usually can't answer yet ("where should this
live?" — they don't know; they haven't written it). The right behavior:

1. **Instant.** ⌘N creates a real, editable document immediately — no dialog.
2. **Automatically safe.** It autosaves to a hidden **scratch directory** in the
   app container and survives quit/crash (reopened on relaunch). No data is at
   risk while the "where does this live?" decision is deferred.
3. **Deferred commitment.** Only when the user explicitly **saves** (⌘S, which
   for a scratch document behaves like Save As, rooted in the home directory)
   does Quoin ask where the file lives and relocate it to a real home. At that
   point it's an ordinary document.

This mirrors how the best editors treat *untitled* documents — real, saved,
recoverable, just not yet committed to a home. Quoin's twist: because the model
is file-backed (there is no in-memory "untitled"), "untitled" is implemented as
a real file in a hidden autosaved scratch store, not a special unsaved buffer.

### The checklist

When a design would interrupt the user with a modal/decision at the **start** of
an action, ask:

1. Can we do the thing **instantly** with a safe default instead of asking?
2. Can we make it **automatically safe/recoverable** (autosave, scratch store,
   survives quit/crash) so nothing is lost while the decision is deferred?
3. Can we **defer the real choice** to when the user signals they want to keep it
   (an explicit save / share / export)?

If yes to all three, prefer that over a prompt-on-create. **A "decide first"
modal is a smell at the moment of creation; it belongs at the moment of
commitment.** This composes with Quoin's other standing commitments — local-first,
byte-lossless, autosave-in-place — all of which already lean toward "the safe
thing happens automatically, the user is never made to babysit their data."
