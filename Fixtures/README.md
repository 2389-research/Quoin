# Fixture ownership

Quoin uses fixtures for several different jobs. Keep those jobs separate so a
fixture edit does not accidentally change parser contracts, render snapshots,
CI screenshots, documentation images, and future onboarding samples at the same
time.

## Categories

| Path | Owner | Stability |
|---|---|---|
| `renderer/` | Parser/render conformance tests | Stable contract; changes require snapshot review |
| `gallery-*.md` | Screenshot and README gallery coverage | Visual contract; screenshot deltas must be reviewed |
| `showcase.md`, `engines.md`, `structure.md` | App dogfooding and screenshot automation | Demo contract; keep broad element coverage |
| Future first-run or Help samples | Product onboarding | Keep separate from conformance fixtures |
| Local scratch fixtures | Individual developer | Do not commit unless promoted into one of the categories above |

## Renderer Conformance

`renderer/` holds focused Markdown modules, one per feature area. They serve two
jobs:

1. **CI conformance.** `RendererConformanceTests` in `Tests/QuoinCoreTests`
   parses every module and checks:
   - it parses, produces blocks, and preserves its source byte-for-byte;
   - structural metrics (block / heading / diagram / math / table counts) match
     the committed snapshot in `Tests/QuoinCoreTests/Snapshots/renderer-metrics.json`;
   - every natively-rendered mermaid diagram lays out non-degenerately.

   After an intentional fixture or parser change, regenerate the snapshot:

   ```sh
   QUOIN_UPDATE_SNAPSHOTS=1 swift test --filter RendererConformanceTests
   ```

2. **Dogfooding.** To browse the modules in the app instead of scrolling a
   70k-char document, copy the folder into your Quoin library (the sandbox
   blocks `-QuoinLibraryPath` from reaching an arbitrary repo folder on a
   normal launch):

   ```sh
   cp -R Fixtures/renderer ~/Documents/ClintNotes/RendererFixtures
   ```

   They then appear as a `RendererFixtures` folder in the sidebar; re-copy
   after editing a fixture.

`Tests/QuoinRenderTests/AttributedRendererSnapshotTests` also converts these
modules into render digests. Digest updates are expected only when rendering,
source styling, or fixture coverage intentionally changes.

## Screenshot Fixtures

The top-level Markdown files in `Fixtures/` feed screenshot automation and
README imagery. CI copies them to `/tmp/quoin-fixtures`, captures PNGs in
`/tmp/quoin-shots`, uploads the screenshots as an artifact, and publishes
successful main-branch results to the `ci-screenshots` branch.

Screenshot capture is advisory in CI, but screenshot diffs are part of review
for UI-sensitive changes. Treat unexpected changes in colors, rules, spacing,
decorations, math, diagrams, or source reveal behavior as blocking until the PR
explains the delta.

## Snapshot Updates

When a fixture change intentionally moves a contract, regenerate and review the
matching snapshots in the same PR:

```sh
QUOIN_UPDATE_SNAPSHOTS=1 swift test
```

In the PR, say which contract moved: parser metrics, rendering digest,
screenshot/gallery coverage, or demo content. Do not update snapshots to mask an
unexplained regression.

## Modules

| File | Covers |
|---|---|
| `01-headings.md` | ATX/Setext headings, anchors, thematic breaks |
| `02-inline-and-links.md` | emphasis/code/strikethrough, links, images |
| `03-lists-and-tasks.md` | lists, nesting, definition lists, checkboxes |
| `04-blockquotes-callouts.md` | quotes, nested cards, alert callouts |
| `05-code-blocks.md` | fenced/indented code, fences, long lines |
| `06-tables.md` | alignment, escaped pipes, wide/empty cells |
| `07-html-and-footnotes.md` | raw HTML, footnotes, reference definitions |
| `08-unicode-edge-cases.md` | mixed scripts, RTL, ambiguous escapes |
| `09-math.md` | inline/display math, matrices/cases/aligned gallery |
| `10-diagrams.md` | mermaid gallery (native + tidy-fallback types) |
| `11-extensions.md` | non-standard extensions (mostly plain-text fallback) |
| `12-torture.md` | pathological inputs, large repeated content |
