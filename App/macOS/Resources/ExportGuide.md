---
title: Exporting Documents
created: 2026-07-17
---

# Exporting Documents

Your document is always a plain `.md` file — you never *need* to export to
keep or share it. Export is for handing your writing to something that isn't
a Markdown editor: a printer, a browser, a word processor.

Open the export sheet with **⇧⌘E** (or **File ▸ Export…**).

## Formats

| Format | Best for |
| :--- | :--- |
| **PDF** | Paginated, print-ready output. Default. |
| **HTML** | A standalone page with all styles inlined. |
| **Markdown** | Normalized source — tidy, canonical Markdown. |
| **RTF** | Pasting into a word processor. |
| **Plain text** | Just the text, no formatting. |

Math and diagrams are rendered natively into PDF, HTML, and RTF — no web
engine, no network round-trip.

## Options

- **Appearance** — export in Light, Dark, or Match System. Affects PDF,
  print, and HTML.
- **Include footnotes** — append footnote definitions at the end.
- **Sanitize HTML** — on by default. Standalone HTML export scrubs scripts,
  event handlers, and remote trackers so a shared page can't phone home.
  Turn it off only if you need byte-exact raw HTML.

## Printing

**⌘P** prints through the standard macOS print dialog, using the same
paginated rendering as PDF export. **⇧⌘P** opens Page Setup first if you
need to change paper size or orientation.

## What stays local

Export writes a new file wherever you choose in the save panel; your
original `.md` is untouched. Nothing is uploaded — the exported file is
yours to move, attach, or delete like any other.
