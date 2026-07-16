# 0005 — Keep-alive tab views REJECTED; sessions live in an app-level store

Status: Accepted (2026-07-13).

## Context
Tab switches destroyed scroll/caret/undo because the editor view (and the
model it owned) was torn down per switch (ledger #22). The obvious fix — keep
every tab's full `ReaderScreen` alive in a ZStack, toggling opacity — was
implemented and shipped to a test build.

## Decision
REJECTED: SwiftUI accumulates window chrome per alive screen — 4 tabs
rendered 4 copies of the toolbar (12 buttons), and sibling screens fought
over interaction. Instead, the MODEL outlives the view: `OpenDocumentStore`
owns one ReaderModel/DocumentSession per file (ref-counted across windows
AND tabs — also fixing dual-autosaver corruption, ledger #12), a single
ReaderScreen shows the active tab, and `ViewportSnapshot` stashes/restores
scroll + caret across switches.

## Consequences
- Do NOT re-attempt the keep-alive stack; the failure is structural
  (`.toolbar`/`.navigationTitle`/`.inspector` accumulate across siblings).
- Anything that must survive a tab switch belongs on the model, not the view.

## Evidence
User-supplied screenshot of the tripled toolbar (2026-07-13 session);
commits 5bb1419 + e97fce3; ledger #12/#22 now FIXED.
