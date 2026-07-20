---
title: Using Quoin with macOS
created: 2026-07-20
---

# Using Quoin with macOS

Quoin plugs into the parts of macOS you already use. These features live in the
**operating system**, not inside a Quoin menu, so they're easy to miss — here's
where to find each one. Everything below stays local: no account, no telemetry,
nothing leaves your Mac.

## Spotlight — find any note from anywhere

Quoin quietly indexes the documents in your library so the system's own search
can find them.

1. Press **⌘Space** to open Spotlight (or use the search glass in the menu bar).
2. Type a word, a heading, or a tag from one of your notes.
3. A Quoin result appears — press **Return** and the document opens in Quoin.

The index is private and on-device. Only `.md` files inside a library you've
opened are indexed, and it stays in sync as you write — documents you move or
delete drop out automatically. Nothing is uploaded.

## Shortcuts & Siri — automate common actions

Quoin ships five actions to Apple's **Shortcuts** app, so you can drive your
library by keyboard, menu bar, or voice.

1. Open the **Shortcuts** app (it comes with macOS).
2. In the action list on the right, search for **Quoin**.
3. Drag any of these into a shortcut:
   - **Create Note** — make a new note (optionally with a title and body).
   - **Append Text to Note** — add a line to the end of a note. It's a real,
     undoable edit — never a blind overwrite.
   - **Open Note** — bring Quoin forward with a chosen note.
   - **Search Library** — fuzzy-search notes to feed into another action.
   - **Export Note** — export a note as HTML, Markdown, or plain text.

You can also just ask Siri, e.g. *"Create a note in Quoin."*

## Services — capture text from any app

Turn a selection in **any** app into a new Quoin note.

1. Select some text (in Safari, Mail, Notes — anywhere).
2. Open that app's **application menu ▸ Services**, or **right-click ▸ Services**.
3. Choose **New Quoin Document with Selection**.

Quoin creates a new note seeded with the selection and opens it. With no library
configured, Quoin asks where to save instead.

> If the Services item doesn't appear right away, it usually shows up once Quoin
> has launched at least once and you reopen the menu — macOS caches the list.

## Handoff — pick up where you left off

The document you're editing is published as your current activity, so it can
resume from the Mac's **Handoff** banner, and from **Siri Suggestions** and
window restoration. The handle it carries is a private, in-library link — never
a raw file path — so resuming always stays inside the folder you granted.

## Quick Look — preview `.md` files in Finder

In **Finder**, select any Markdown file and press **Space**. Quoin renders a
preview — headings, prose, code, tables, callouts — instead of showing raw
text, and Finder shows a rendered thumbnail too. This works for `.md` files
anywhere, even outside your library.

---

Prefer everything at your fingertips inside the app? See **Keyboard Shortcuts**
in the Help menu.
