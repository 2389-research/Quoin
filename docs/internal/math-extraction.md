# Math engine — extracted to Vinculum

Quoin's native LaTeX math typesetter is no longer in this repo. It was
extracted into **[Vinculum](https://github.com/2389-research/Vinculum)**, a
Quoin-owned first-party package consumed from GitHub (`Package.swift`,
`from: "0.23.0"`). The parser, the box-model typesetter, the CoreText drawing,
and the exhaustive command coverage (~400 commands) all live there now, tested
by Vinculum's own CI. The decision and its rationale are recorded in
[adr/0003](../reference/adr/0003-first-party-engines.md).

**Working on parsing or typesetting math?** Do it in the Vinculum repo
(`VinculumLayout` = platform-free parse + geometry → `MathScene`;
`VinculumRender` = CoreText drawing behind the `MathTheme` seam), then publish →
tag → bump Quoin's pin. The exhaustive symbol/command matrix is Vinculum's
`docs/COVERAGE.md` / `docs/COMMANDS.md` — Quoin docs do not restate it (it
drifts; see [adr/0003](../reference/adr/0003-first-party-engines.md)).

**Working on how math behaves inside a Quoin document** (the
`MathImageRenderer.attachmentString` attachment, the degrade-to-source-card
fallback for unsupported LaTeX, the `Theme.mathTheme` seam, the `‹/› edit` /
side-panel-preview UX)? That glue stays in Quoin — see
[architecture.md](../reference/architecture.md) for where it sits in the pipeline.

> The former contents of this file (the two-product target shape, the
> theme-decoupling steps, and the migration checklist) documented a completed
> one-time extraction. The mechanics are preserved in
> [adr/0003](../reference/adr/0003-first-party-engines.md) and mirrored for MermaidKit in
> [diagram-engine-handoff.md](diagram-engine-handoff.md); the engine-internal
> detail now belongs to Vinculum and was removed here rather than duplicated.
