---
title: Privacy & Your Files
created: 2026-07-17
---

# Privacy & Your Files

Quoin is local-only by design. This document explains exactly where your
writing lives and what never happens to it.

## Your documents are plain files

Every document is an ordinary `.md` file on your disk. Folders in your
library are just directories. There is:

- No database — nothing to corrupt, export, or get locked out of.
- No proprietary format — open any file in any editor, forever.
- No Save button — saves are automatic and **byte-lossless**, so the parts
  of a file you didn't touch come back exactly as they were.

Open this document in another editor right now and you'll see the same
plain text you see here.

## Nothing leaves your Mac

Quoin has no accounts, no sign-in, and no telemetry. It does not phone home,
sync to a server, or send analytics. Diagrams and math render **natively** —
there is no embedded web browser and no network request to draw them.

- [x] No account required
- [x] No telemetry or analytics
- [x] No network needed to write, render, math, or diagram
- [x] Your files stay in the folder you chose

## The sandbox and folder access

Quoin is sandboxed by macOS. When you pick a library folder, macOS grants
Quoin access to *that folder only*, and remembers the grant (a
security-scoped bookmark) so you approve it just once. Quoin can't read
anything outside the folders you point it at.

## Optional network features

A few actions reach the network, and only when *you* trigger them:

- **Check for Updates** downloads a signed app update, if you ask for one.
- **Report an Issue…** opens your browser to Quoin's issue tracker.
- Links you click in a document open in your browser, like any link.

Writing, editing, rendering, math, diagrams, search, and export all work
fully offline.

## Deleting is just deleting

Move a document to the Trash and it's gone from disk — there's no hidden
copy in a cloud. Your library is exactly the folder you see in Finder.
