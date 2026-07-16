# Diagrams in Quoin

Quoin renders Mermaid diagrams **natively** — no Mermaid.js, no JavaScript,
no network, no headless browser. A fenced ` ```mermaid ` block is parsed,
laid out, and drawn with CoreGraphics/CoreText inside the editor.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../images/gallery-diagrams.png">
  <img alt="A page of native Mermaid diagrams rendered by Quoin" src="../images/gallery-diagrams.png">
</picture>

## The full diagram catalog lives in MermaidKit

The parser, layout, and drawing all come from **[MermaidKit](https://github.com/2389-research/MermaidKit)**,
Quoin's own first-party published package (pinned in `Package.swift`;
`from: "0.10.0"`). The complete, always-current list of supported diagram
types — and the rendered gallery of each in a simple and complex form — is
documented **there**, in the engine that owns it.

Quoin's docs deliberately do **not** restate that matrix. A duplicated count
drifts the moment the engine gains a type (the 23-vs-30 diagram-count
regression of 2026-07-13 happened exactly that way; see
[adr/0003](../reference/adr/0003-first-party-engines.md)). For "which diagrams can I draw
and what does each look like," go to MermaidKit. This page covers only what is
**Quoin-specific**: how a diagram behaves once it is inside a document.

## How a diagram behaves in the editor

- **It's a block decoration, not text.** A rendered diagram is a single
  `NSTextAttachment` image tagged with `QuoinAttribute.blockID`; its hairline
  frame is the `BlockDecoration.diagramFrame` case
  (`Sources/QuoinRender/BlockDecoration.swift`), drawn behind the text in
  `QuoinTextView.drawBackground(in:)` from TextKit 2 fragment frames so it
  tracks reflow. It is never a per-glyph `.backgroundColor`.

- **Presentation object, not a text run.** A diagram does not flip to source
  on double-click or on a stray keystroke — those are jarring for a picture.
  Editing is entered explicitly: the `‹/› edit` chip, ⌘↩, or the context menu
  (rendering-ledger #7). See [design/embed-editing-ux.md](../design/embed-editing-ux.md).

- **Live preview is a side panel, not an inline run.** While you edit the
  Mermaid source, the rendered diagram shows in a floating panel beside the
  source (`RenderedDocument.previewPanel`), not in the text flow. The
  last-good render is held while a mid-edit source is temporarily unparseable,
  so the layout never jumps per keystroke (`HeldPreview`;
  [adr/0004](../reference/adr/0004-side-panel-preview.md), rendering-ledger #6/#8).

- **Degrade, never break.** `MermaidRenderer.attachmentString(source:theme:)`
  returns `nil` for a dialect the engine doesn't recognise, and
  `AttributedRenderer` falls back to the same tidy labelled source card used
  for unsupported math — never a broken half-render
  (`Sources/QuoinRender/AttributedRenderer.swift`).

- **Theme seam.** Quoin passes its palette through `Theme.diagramTheme`
  (a `DiagramTheme` value), so diagrams adapt to light/dark without the engine
  knowing anything about Quoin's `Theme`. The engine draws; Quoin supplies the
  ink.

- **Block-adjacent comments.** Because a diagram can't host an inline
  CriticMarkup span, review comments attach to the block itself — the same
  mechanism used for code, tables, and math (see
  [design/suggestions.md](../design/suggestions.md)).

## Regenerating the image on this page

`images/gallery-diagrams.png` is one of the marketing/gallery composites
rendered from Quoin's own pipeline. Engine-level per-type PNGs and their
regeneration harness now live in **MermaidKit's** repository and CI, not here.
