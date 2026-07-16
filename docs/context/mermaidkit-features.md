# MermaidKit — features context pack

*Everything someone evaluating MermaidKit should know. Verified against the
package source at v0.9.0 on 2026-07-10 (github.com/2389-research/MermaidKit).
Companion pack: `quoin-features.md`.*

## One paragraph

MermaidKit renders Mermaid diagrams as **native Swift drawing** — parser,
layout engine, and CoreGraphics/CoreText renderer, with **zero third-party
dependencies** (verified: no `.package` entries in Package.swift) and zero
JavaScript/WebView. Feed it Mermaid source, get back a `PlatformImage`, an
`NSAttributedString` attachment, a vector PDF, or a SwiftUI view — themed
to match your app, on macOS 14+ / iOS 17+ / visionOS 1+, in Swift 6
language mode.

## The big differentiators

1. **No web engine.** The standard way to render Mermaid in an app is
   mermaid.js inside a WKWebView: slow first paint, async sizing
   headaches, foreign typography, no dark-mode fidelity, a JS runtime in
   your process. MermaidKit is synchronous native drawing that inherits
   your fonts and colors.
2. **Zero dependencies, Swift 6.** No ELK port, no JS bridge, nothing to
   audit but the package itself. Swift 6 language mode with zero
   concurrency warnings.
3. **30 diagram types** — the standard Mermaid catalog plus seven
   MermaidKit-original dialects (venn, cynefin, wardley, ishikawa,
   eventmodeling, swimlane, treeView) that mermaid.js doesn't have.
4. **A geometry linter as a first-class API.** Every layout lowers to a
   platform-free, Codable scene IR that can be machine-checked against
   visual invariants (edge-occludes-node, nodes-overlap, edge-cuts-label,
   off-canvas, crossing budgets). CI lints all 30 fixture diagrams — the
   engine's "looks right" is enforced, not eyeballed. Hosts can run the
   same linter on user diagrams.
5. **Honest degradation + real diagnostics.** Unparseable source returns
   nil (host shows the fenced text), and `MermaidParser.diagnose()`
   returns line-numbered diagnostics with did-you-mean suggestions.
   Adversarial-input and parser-honesty suites keep the parser from
   pretending.

## The 30 diagram types

Standard Mermaid: `flowchart`/`graph`, `sequenceDiagram`, `pie`,
`stateDiagram-v2`, `classDiagram`, `erDiagram`, `gantt`, `timeline`,
`mindmap`, `journey`, `quadrantChart`, `packet`, `xychart`, `kanban`,
`radar`, `treemap`, `gitGraph`, `sankey`, `requirementDiagram`, `zenuml`,
`C4Context`/`C4Container`/…, `architecture`, `block-beta`.

MermaidKit originals: `venn`, `cynefin`, `wardley`, `ishikawa`,
`eventmodeling`, `swimlane`, `treeView`.

(Headers match leniently — both `venn` and `venn-beta` parse. One fixture
per type ships in the repo and is layout-linted in CI.)

### Per-type capability highlights

- **Flowchart** — network-simplex layered placement; nested `subgraph`
  group boxes with per-group `direction`; edges to a subgraph resolve to
  its border; chained edges (`A-->B-->C`), `&` fan-out, inline edge
  labels, `<-->`, `--o`/`--x` heads, edge IDs, `:::class` tolerated.
- **Sequence** — everyday mermaid parity: `loop`/`alt`+`else`/`opt`/
  `par`+`and`/`critical`+`option`/`break` fragments (arbitrarily nested),
  `rect` bands, `box` participant groups, activation bars (`->>+`/`->>-`),
  `create`/`destroy` lifelines, notes with `<br/>`, `actor` figures,
  typed participants (`@{ "type": "database" }`), autonumber, all arrow
  tokens.
- **State (v2)** — composite states, fork/join bars, choice diamonds,
  `<<annotations>>`, per-scope `[*]`.
- **Class** — compartments, generics `~T~`, relation kinds with UML
  markers (▷ ◆ ◇), orthogonal routing, multiplicity labels.
- **ER** — crow's-foot cardinalities, identifying/non-identifying
  relations, attribute keys.
- **Gantt** — sections, `after` dependencies, date/duration timeline,
  statuses, milestones (months approximated as 30 days).
- **Charts** — pie; quadrant (2×2 tinted matrix, plotted points); radar
  (spoked graticule, overlaid polygons); xychart (grouped bars + lines);
  packet (32-bit grid, `+N` relative widths); sankey (proportional flow
  bands); treemap (squarified, nested).
- **GitGraph** — commit lanes, branch/merge curves, tags, cherry-pick.
- **Boards & maps** — kanban (tinted columns, ticket chips), timeline,
  mindmap (tidy tree, per-branch tints), journey (satisfaction badges),
  requirement (UML req boxes), architecture (grouped services), block
  (column grid), C4 (see gaps), ZenUML (alternate sequence syntax).

## Architecture (why hosts can trust it)

- **MermaidLayout** (platform-free): `MermaidParser.parse` → typed models
  → `DiagramLayoutEngine.layout(_:measure:)` → pure geometry. Text
  measurement is INJECTED (`DiagramTextMeasurer`), so layout runs
  headless and deterministically; layered types use network-simplex layer
  assignment with label-space reservation and declaration-order
  stability.
- **MermaidRender** (CoreGraphics/CoreText): per-type renderers,
  `MermaidView` (SwiftUI), the `DiagramTheme` seam.
- **Scene IR**: every layout lowers to `DiagramScene` — Codable nodes/
  edges/labels — enabling the linter, golden diffs (`DiagramSceneDiff`),
  and external tooling.
- **DiagramTheme**: six semantic colors + a categorical palette +
  `prefersDark`, resolving to a fingerprinted platform-free form (cache
  key). Re-skin every diagram type at once.

## API (the whole integration)

```swift
import MermaidRender

// One-shot image (cached per source+theme+spacing):
let image = MermaidRenderer.image(source: mermaid, theme: .init(prefersDark: true))

// Off-main, cancellation-aware:
let image = await MermaidRenderer.renderImage(source: mermaid)

// For text systems / exporters:
let run = MermaidRenderer.attachmentString(source: mermaid)   // NSAttributedString
let pdf = MermaidRenderer.pdfData(source: mermaid)            // vector, single page
let alt = MermaidRenderer.altText(source: mermaid)            // VoiceOver

// SwiftUI:
MermaidView(mermaid)   // follows the environment color scheme

// Headless quality gate (same geometry as the renderer):
let diagram = MermaidParser.parse(mermaid)
let layout = DiagramLayoutEngine.layout(diagram!, measure: MermaidRenderer.textMeasurer)
let report = DiagramLayoutLinter.lint(scene)   // machine-readable violations

// Line-numbered errors with did-you-mean:
let issues = MermaidParser.diagnose(brokenSource)
```

Spacing presets: `.compact` / `.regular` / `.comfortable` (or custom
gaps/margins). Input guards: 50k chars / 500 edges max.

## Quality signals

- ~156 XCTest cases across 20 files, including **ParserHonestyTests**
  (39 cases: the parser may not pretend to understand what it doesn't),
  **AdversarialInputTests**, **StabilityTests** (layout determinism),
  **EdgeCutsLabelTests**, and **RenderBenchmarks** — CI fails if any type
  renders slower than 250ms.
- The geometry linter runs over all 30 fixtures in CI.
- Proven in production as Quoin's diagram engine (every keystroke of
  Quoin's live diagram editing round-trips through parse→layout→render).

## Honest limitations (verified in source)

- **Core syntax per type**, not bug-for-bug mermaid.js parity. Known
  unsupported: flowchart `@{ shape: … }` node shapes, HTML in labels
  beyond `<br/>`, FontAwesome icons, click callbacks, animations, and
  `%%{init}%%` theme directives (theming is the host's `DiagramTheme`
  instead).
- **Venn**: classic 1/2/3-set arrangements only; 4+ sets degrade to a row
  of tangent circles, and overlap areas are heuristic, not
  area-proportional Euler solutions.
- **C4**: renders persons/systems/containers/components (+ external
  variants) and `Rel`/`BiRel` relations, but `System_Boundary`/
  `Enterprise_Boundary`/deployment `Node` grouping frames are currently
  dropped.
- Apple platforms only (macOS 14+/iOS 17+/visionOS 1+); the layout target
  has no AppKit/UIKit imports but the manifest doesn't declare Linux.
- Parse failure is silent-by-design at the render API (nil → host shows
  source); use `diagnose()` when you want the reasons.

## Assets & examples

Rendered examples of every type live in the MermaidKit repo's CI gallery (the
per-type renders are owned there, not vendored into Quoin). Quoin keeps only
`docs/images/gallery-diagrams.png` (a mixed sampler) and
`docs/history/diagram-gallery.md`, which documents Quoin-side behaviour. The 30
canonical fixture sources live in the MermaidKit repo under `Fixtures/diagrams/`.

## Version & license

v0.9.0 (SemVer, CHANGELOG maintained; recent: 0.9 flowchart subgraph
boxes, 0.8 sequence lifecycle + typed participants, 0.7 sequence combined
fragments). Swift tools 6.0. First-party package of the Quoin project —
note for adopters: a LICENSE file is being added to the repo (tracked on
Quoin's launch ledger).
