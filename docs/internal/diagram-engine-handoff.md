# Diagram engine — extracted to MermaidKit

Quoin's native Mermaid engine is no longer in this repo. It was extracted
into **[MermaidKit](https://github.com/2389-research/MermaidKit)**, a Quoin-owned
first-party package consumed from GitHub (`Package.swift`, `from: "0.10.0"`).
The parser, the Sugiyama/Brandes–Köpf layout, the dummy-node edge routing, and
the CoreGraphics drawing — plus the engine's own handoff brief, diagram-type
catalog, and gallery-regeneration harness — all live there now, tested by
MermaidKit's own CI. The decision and its rationale are recorded in
[adr/0003](../reference/adr/0003-first-party-engines.md).

**Working on diagram layout/routing/drawing?** Do it in the MermaidKit repo
(`MermaidLayout` = platform-free parse + layout + scene IR; `MermaidRender` =
CoreGraphics drawing behind the `DiagramTheme` seam), then publish → tag → bump
Quoin's pin. Do not fix it here.

**Working on how diagrams behave inside a Quoin document** (the block
decoration/frame, the degrade-to-source-card fallback, the `Theme.diagramTheme`
seam, the `‹/› edit` / side-panel-preview UX)? That glue stays in Quoin — see
[diagram-gallery.md](diagram-gallery.md) for the Quoin-side behaviour and
[architecture.md](../reference/architecture.md) for where it sits in the pipeline.

> The former contents of this file (the routing pipeline, `routeChains`
> invariants, Brandes–Köpf notes, the iteration harness) described engine
> internals that now belong to MermaidKit. They were removed here rather than
> duplicated, so this file can't drift out of sync with the engine.
