# Contributing to Quoin

Quoin is a native Swift/SwiftUI plus TextKit 2 WYSIWYG Markdown editor for
macOS, with iOS/iPadOS reader work following the same engine boundaries. It is
local-only at runtime: no JavaScript, no web views, no telemetry, and no
network dependency for editing local notes.

Before changing behavior, read these project sources in order:

1. `docs/design/handoff.md` and `docs/design/Markdown Editor Design Doc.dc.html`
2. `docs/archive/TRD.html`
3. `docs/archive/PRD.html`
4. `docs/reference/architecture.md`

The handoff wins on visual and interaction details. If it conflicts with the
TRD, keep the handoff behavior and note the conflict in the implementation or
follow-up issue.

## Setup

Requirements:

- macOS 14 or newer
- Xcode 16 or newer
- Swift 5.10 or newer
- XcodeGen for app projects: `brew install xcodegen`
- GitHub CLI for tracker hygiene checks: `brew install gh`

Editor defaults are declared in `.editorconfig`: LF line endings, UTF-8,
final newlines, spaces for indentation, and 4-space Swift indentation.
Quoin does not currently require SwiftFormat or SwiftLint. That is
intentional: formatter or linter adoption would add project policy and tool
surface, so keep Swift style changes review-driven until the TRD justifies a
new dependency or required tool.

Package checks run from the repository root:

```sh
swift build
swift test
bash scripts/check-dependency-policy.sh
bash scripts/check-generated-projects.sh
```

The app projects are generated with XcodeGen:

```sh
cd App/macOS
xcodegen
xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build

cd ../iOS
xcodegen
xcodebuild -project QuoinIOS.xcodeproj -scheme QuoinIOS \
  -destination 'generic/platform=iOS Simulator' build
```

Generated `.xcodeproj` bundles are ignored and should not be committed. Treat
`App/macOS/project.yml` and `App/iOS/project.yml` as the source of truth; CI
regenerates projects before app builds.

## Branch and Worktree Workflow

Keep work scoped to one issue bundle. A typical flow is:

```sh
git fetch --prune origin
git pull --ff-only
git worktree add ../quoin-my-branch -b codex/my-branch origin/main
cd ../quoin-my-branch
```

Commit meaningful units of work and push the branch for CI. Do not mix
unrelated issue work into the same pull request.

## Architecture Invariants

These are not style preferences; changes must preserve them:

- The markdown source string plus AST are the only source of truth.
  Attributed strings are projections, never document data.
- Edits flow through `DocumentSession` as source edits and the renderer
  re-projects the result.
- Opening, editing, and saving must keep untouched regions byte-lossless.
- Documents are plain `.md` files on disk; folders are directories.
- `QuoinCore` stays platform-free and must keep building on Linux in
  principle.
- View models stay platform-free; only navigation containers differ.
- Runtime stays local-only with zero JavaScript and no embedded web view.
- System shortcuts are not overridden: `Cmd-P`, `Cmd-E`, and `Cmd-H` keep
  their system meanings.
- Block chrome is drawn from geometry in `QuoinTextView`, not with per-glyph
  background attributes.
- Unknown or unsupported input degrades to a labelled source card rather than
  crashing or half-rendering.

## Dependency Policy

Quoin has one direct code dependency: `swift-markdown`. New code dependencies
require written TRD justification before `Package.swift`, `Package.resolved`,
or the dependency guard is changed. Run:

```sh
bash scripts/check-dependency-policy.sh
```

## Tests, Fixtures, and Snapshots

Every core behavior should have coverage under `Tests/QuoinCoreTests`.
Rendering changes usually need `Tests/QuoinRenderTests`, fixture updates, or
both. Pathological input belongs in torture tests, and performance-sensitive
work should preserve the PRD budgets enforced by `PerformanceTests`.

Fixture roles are deliberately separate:

- `Fixtures/renderer/` is a conformance contract. It feeds parser metrics,
  renderer digest snapshots, and non-degenerate diagram layout checks.
- `Fixtures/gallery-*.md`, `Fixtures/showcase.md`, `Fixtures/engines.md`, and
  `Fixtures/structure.md` are screenshot and dogfooding material for the app.
- Torture or pathological coverage belongs in focused tests or renderer
  modules whose expected metrics are committed with the change.
- Future user-facing samples for first-run or Help flows should live outside
  conformance fixtures so onboarding copy does not churn golden snapshots.

Regenerate snapshots only for intentional behavior or fixture contract changes:

```sh
QUOIN_UPDATE_SNAPSHOTS=1 swift test
```

Call out snapshot updates in the PR body and explain whether the change is a
parser/source preservation change, a rendering projection change, or a fixture
coverage change.

Screenshot automation copies the top-level Markdown files in `Fixtures/` into
`/tmp/quoin-fixtures`, captures app PNGs into `/tmp/quoin-shots`, uploads them
as a CI artifact, and publishes successful main-branch screenshots to
`ci-screenshots`. Screenshot capture is advisory in CI: failures should be
investigated, but they do not block non-UI changes by default. For
layout-sensitive UI changes, especially colors, rules, spacing, decorations,
and rendered math or diagrams, review screenshots as part of the PR and treat
unexpected visual deltas as blocking until explained.

## Issue and PR Hygiene

Open issues should be triaged with:

- `status:triaged`
- exactly one `priority:*` label
- at least one `area:*` label
- a milestone

Check tracker metadata with:

```sh
bash scripts/check-issue-triage.sh
```

The `main` branch is protected by the GitHub ruleset `Protect main`. It applies
to `refs/heads/main` and requires pull requests, resolved review threads, an
up-to-date branch, and the `swift test (macOS)` CI check before normal merges.
It also blocks non-fast-forward updates and branch deletion.

Repository auto-merge is enabled so protected pull requests can merge after the
required checks pass without using emergency bypass privileges. Topic branches
are deleted automatically after merge.

The ruleset intentionally requires zero approving reviews for now. Quoin is a
solo-maintainer private repository, so a hard external approval requirement
would turn routine maintenance into a deadlock. The review rule still forces
the pull-request path and keeps review threads resolved.

Only Clint's GitHub user is configured as an emergency bypass actor. Use that
bypass only for break-glass repository recovery, then follow up with a normal
issue or pull request that explains what happened and confirms CI returned to
green.

Audit the live GitHub setting with:

```sh
bash scripts/check-main-protection.sh
```

Pull requests should link the issue they close, list tests run, call out UI
screenshots when relevant, and confirm the dependency policy.
