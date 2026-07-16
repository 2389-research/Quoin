# Dependencies

Quoin runs on **one third-party code dependency**: swift-markdown. Everything
else in the build graph is either a transitive dependency of that one package,
or a Quoin-owned first-party engine. For how these pieces fit into the running
app, see the [architecture map](architecture.md); for what capability spec
they exist to serve, see [PRODUCT.md](../PRODUCT.md).

## Why so few

Every dependency is a standing liability — supply-chain risk, binary bloat, a
compatibility surface you don't control, and lock-in to someone else's release
cadence and design choices. A native, local-only, zero-JavaScript editor whose
whole promise is that your files stay yours cannot afford to smuggle in an
unaudited transitive graph. So the policy is deliberately strict: **the default
answer to a new dependency is no.** Adding one requires written justification in
this file *before* it lands, plus an allowlist entry in
`scripts/check-dependency-policy.sh`, which fails CI if `Package.swift` or
`Package.resolved` names anything unapproved.

First-party engine packages (MermaidKit, Vinculum) are exempt — they are
Quoin's own code, just versioned in their own repos (see
[why they're separate](#first-party-engines-mermaidkit--vinculum)).

## The graph

```mermaid
flowchart TD
    subgraph quoin["Quoin (this repo)"]
        Core["QuoinCore<br/>(platform-free engine)"]
        Render["QuoinRender<br/>(TextKit 2 + drawing)"]
    end

    subgraph thirdparty["Third-party (approved)"]
        Markdown["swift-markdown"]
        Cmark["swift-cmark<br/>(cmark-gfm)"]
    end

    subgraph firstparty["First-party engines (own repos)"]
        MLayout["MermaidLayout"]
        MRender["MermaidRender"]
        VLayout["VinculumLayout"]
        VRender["VinculumRender"]
    end

    Render --> Core
    Core --> Markdown
    Markdown --> Cmark
    Core --> MLayout
    Core --> VLayout
    Render --> MRender
    Render --> VRender

    classDef third fill:#ffe8cc,stroke:#d9822b,color:#333
    classDef first fill:#d6ebff,stroke:#3b82c4,color:#333
    class Markdown,Cmark third
    class MLayout,MRender,VLayout,VRender first
```

| Package | Kind | Pin | Role |
| :--- | :--- | :--- | :--- |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | third-party (approved) | `from: 0.8.0` | The cmark-gfm parser; the entire AST |
| swift-cmark | transitive (via swift-markdown) | — | cmark-gfm itself |
| [MermaidKit](https://github.com/2389-research/MermaidKit) | first-party | `from: 1.0.0` | Native Mermaid diagram engine |
| [Vinculum](https://github.com/2389-research/Vinculum) | first-party | `from: 1.4.1` | Native LaTeX math engine |

`QuoinCore` depends only on the platform-free layout halves (Markdown,
MermaidLayout, VinculumLayout) so it builds and tests on Linux. `QuoinRender`
adds the drawing halves (MermaidRender, VinculumRender), which need
CoreText/CoreGraphics. The next diagram makes that split explicit — see
[Linux rendering](#linux-rendering) below for what it takes to draw pixels
off Apple platforms.

```mermaid
flowchart TB
    subgraph linuxSplit["Platform-free — builds & tests on Linux"]
        QC["QuoinCore"]
        SM["swift-markdown"]
        ML["MermaidLayout"]
        VL["VinculumLayout"]
    end
    subgraph macSplit["Platform render — needs CoreGraphics/CoreText"]
        QR["QuoinRender"]
        MR["MermaidRender"]
        VR["VinculumRender"]
    end

    QC --> SM
    QC --> ML
    QC --> VL
    QR --> QC
    QR --> MR
    QR --> VR
    ML -. "DiagramScene" .-> MR
    VL -. "MathScene" .-> VR

    classDef linuxNode fill:#d6ebff,stroke:#3b82c4,color:#333
    classDef macNode fill:#ffe8cc,stroke:#d9822b,color:#333
    class QC,SM,ML,VL linuxNode
    class QR,MR,VR macNode
```

Every arrow crossing the boundary is a device-independent scene (`DiagramScene`,
`MathScene`) — the layout halves compute geometry once, and only the render
halves turn it into pixels. That seam is also what makes the engines portable
to other hosts and other platforms; see [platforms.md](../design/platforms.md)
for where this split is headed on iOS and Linux.

## swift-markdown

The one approved third-party dependency, and the foundation of the whole
product. Quoin's source of truth is the markdown string and the AST parsed from
it — never an attributed string — and that AST is swift-markdown's.

It is the right dependency to keep: writing a CommonMark+GFM parser from scratch
is a multi-year effort with an enormous compatibility surface, swift-markdown is
Apple-maintained and Apache 2.0, and it pulls only swift-cmark (cmark-gfm, the
same lineage) transitively. Attribution ships in About ▸ Acknowledgements.

## First-party engines: MermaidKit & Vinculum

Mermaid diagrams and LaTeX math are rendered by two Quoin-owned packages —
[MermaidKit](https://github.com/2389-research/MermaidKit) and
[Vinculum](https://github.com/2389-research/Vinculum) — consumed from GitHub with
`from:` pins exactly as any host app would consume them. They are first-party
code, so they are exempt from the one-third-party rule and allowlisted in the
policy script.

**Why separate packages rather than in-repo folders** (see
[ADR 0003](adr/0003-first-party-engines.md)): each engine grew large enough to
be a product in itself. Splitting them out means their test suites run in their
own CI instead of dragging Quoin's, they can serve other hosts, and their
capability matrices live in one authoritative place — their own repos — instead
of being duplicated (and silently drifting) in Quoin's docs.

![Math typesetting and a Mermaid diagram rendering natively side by side in one viewport](../images/native-engines.png)

This is what the split buys the reader: math and diagrams typeset and paint
inline, at editor speed, with no web view and no JavaScript. The full capability
list for both — what markup each supports, what a document looks like with
them — lives in [PRODUCT.md](../PRODUCT.md).

Both follow the same shape:

- A **platform-free layout half** — `MermaidLayout`, `VinculumLayout` — parses
  and computes device-independent geometry (`DiagramScene`, `MathScene`).
  `QuoinCore` `@_exported import`s these, so `import QuoinCore` still exposes
  `MermaidParser`, `MathParser`, and friends.
- A **drawing half** — `MermaidRender`, `VinculumRender` — draws that geometry
  via CoreGraphics/CoreText behind a theme seam (`DiagramTheme`, `MathTheme`),
  which Quoin adapts through `Theme.diagramTheme` / `Theme.mathTheme`.
  `QuoinRender` consumes these.

To co-develop an engine: clone it beside `quoin` and temporarily point
`Package.swift` at `.package(path: "../MermaidKit")` (never commit that), or
`swift package edit`; then publish to the engine repo, tag, and bump the pin
here. Engine changes are validated by the engine's own CI, not Quoin's.

MermaidKit covers flowcharts, sequence, state, class, and ER diagrams:

![A gallery of Mermaid diagrams rendered natively by MermaidKit](../images/gallery-diagrams.png)

Vinculum's coverage is large (~400 commands); the exhaustive matrix lives in
Vinculum's `docs/COVERAGE.md` / `docs/COMMANDS.md`.

![A gallery of LaTeX math typeset natively by Vinculum](../images/gallery-math.png)

### Linux rendering

On Apple platforms the diagram and math engines draw natively through
CoreGraphics/CoreText (`MermaidRender`, `VinculumRender`). The layout halves
(`MermaidLayout`, `VinculumLayout`) are platform-free, so `QuoinCore` builds
and tests on Linux today — but rasterizing a diagram or equation to *screen*
pixels there needs a CoreGraphics substitute. Both engine packages now ship
that: a PureSwift/Silica (Cairo/FreeType) backend behind a default-off
`LinuxRaster` package trait, so a macOS build never pulls Cairo and a
`from:`-pinned consumer gets a Silica-free graph. Opt in with
`traits: ["LinuxRaster"]` to rasterize on Linux. Quoin's macOS product does
not enable it.

Export is further along than raster drawing: both layout halves already emit
their scene IR to platform-free SVG writers, so a headless Linux host can
export full-fidelity diagrams and math today with zero graphics dependencies —
raster is the optional upstream enhancement. See
[platforms.md](../design/platforms.md#rendering-everywhere-scene-ir) for that
SVG path and the rest of Quoin's non-macOS direction (the `quoin` CLI, the
iPhone/iPad reader-first plan).

## Sparkle (auto-update)

Quoin ships by direct distribution, not the App Store. A direct-distribution app
with no updater strands every shipped bug forever — users won't re-download
DMGs — so update delivery is a launch requirement, and
[Sparkle 2.x](https://sparkle-project.org) is the approved answer. It is wired
into the app; the full release/notarization/appcast runbook lives in
[distribution.md](distribution.md).

**Why not hand-roll it:** a safe self-updater is security-critical
infrastructure — EdDSA-signed appcasts, delta application, atomic app
replacement, rollback, sandbox-safe XPC install. Sparkle is the Mac standard:
actively maintained, MIT, with a documented threat model. A hand-rolled updater
would be *less* safe, so the policy's own intent — minimize risk — argues *for*
adopting Sparkle here rather than against it.

How it's scoped:

- **App target only.** Sparkle is a dependency of the `App/macOS` Xcode project
  alone — never the SwiftPM graph — so `QuoinCore`/`QuoinRender` stay
  dependency-clean and Linux-buildable. The policy script allowlists `sparkle`.
- **Privacy.** The update check is Quoin's *only* network traffic. It is
  user-disableable (Settings → Advanced), default on, with a first-run
  disclosure.
- **Prerequisites** (human-only, one-time): an Apple Developer ID plus
  notarization, an appcast host, and an EdDSA key pair (private key in the
  keychain, never the repo). Full steps in [distribution.md](distribution.md).
