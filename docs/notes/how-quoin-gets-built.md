# How Quoin Gets Built

A short reflection on what's actually been working — grounded in the machinery
and habits we rely on, not the usual collaboration platitudes.

## One source of truth, defended by executable contracts

The single most consequential decision is architectural: the markdown string
plus its AST is the *only* truth, and everything on screen is a projection of
it. Almost every hard problem in a WYSIWYG editor — round-trip corruption,
caret drift, "why did my file change" — dissolves once you refuse to let the
view be data.

But a principle is only as strong as its enforcement. What makes Quoin hold
together isn't the rule; it's that the rule is *executable*. Byte-losslessness,
the viewport invariant (the caret's line must not move on any projection
change), patch-vs-full-render equivalence — these aren't aspirations in a doc,
they're `RevealFidelityTests`, `CaretLineAnchorTests`,
`ProjectorEquivalenceTests`. When we add a block type, the discipline is
"extend *both* tests." That's why rendering could move off the main actor and
we could actually *believe* it was safe: the invariant suites are the safety
net, named one by one.

## Institutional memory, written down

The `CLAUDE.md` "each of these was a real shipped bug" section is quietly the
most valuable file in the repo. `\r\n` is one grapheme; per-glyph backgrounds
render as ugly strips; two recognizers for one grammar *will* diverge;
equivalence asserts are only as strong as the fields they compare. Every one of
those is a scar, and writing them down means we pay for each bug once instead of
every few months. The find/replace work landed a *unified* matcher specifically
because that pitfall was already recorded — we didn't have to rediscover it.

## Trust the model, not the eyeball

A recurring technique: when something looks wrong, we diagnose it by dumping
exact numbers and linting the layout model, not by squinting at pixels. Vision
is biased toward confirming your own work — a mirrored snapshot overlay got
"verified" twice by two different readbacks that each lied differently. So we
anchor with an on-screen calibration, ship `NSImageView`-on-crop instead of
trusting `layer.render(in:)`, and prove a regression test *fails against the
old code* before believing the green (the file-descriptor-leak test leaked
~130 fds against the buggy `deinit` — that's how we knew it was real).

## How the collaboration works

A few things about the working style make this fast:

- **High-trust, low-ceremony delegation.** Standing directives are set once —
  commit and push each unit, rebase before push, close issues, update *all*
  docs and the website — and then left to run without re-litigation. That
  momentum is only safe *because* of the invariant tests; you can afford to be
  terse because the guardrails aren't.
- **Perceptual one-liners over specs.** "The cursor lands between the n and g
  of 'formatting'" localizes a bug faster than any amount of static analysis.
  Describe the symptom precisely; get the trace. That division of labor is
  unusually efficient.
- **CLI-only, everything Xcode does without Xcode.** Builds, logs, hang stack
  traces, screenshot automation — all scriptable, reproducible, and inspectable
  in a transcript. It's what lets an agent verify its own work.
- **Judgment, with transparency about it.** Deferring the Swift 6 migration out
  of a parallel batch — because a whole-codebase language-mode flip can't be
  safely merged against six feature branches — is the kind of call to make and
  *state*, not to ask permission for.

## How we approach development

- **Dogfood your own dependencies.** MermaidKit and Vinculum are Quoin's own
  engines, extracted into published packages and consumed *from GitHub like any
  host app would*, versioned and CI'd on their own. A new engine release is a
  pin bump and a green test run — the engine's correctness is its own CI's
  problem, by design. The one-third-party-dependency rule (default answer: no)
  keeps the surface small enough to actually reason about.
- **Triage, tier, batch.** A squad of reviewers surfaces a ledger; the
  data-safety bugs get fixed first with tests; everything else becomes a
  labeled issue. Work flows in batches with a consistent cadence: implement →
  verify → doc → commit → close.
- **Fan out, then integrate carefully.** Six issues, each in its own worktree
  and branch, each a subagent with a mandatory critical-review-and-repair loop,
  works because the *parallelism is in the implementation and the seriousness
  is in the integration*. Independent review beats self-review (self-assessment
  confirms its own work); merging one at a time, rebuilding and running the full
  suite after each, is where the real care goes. The agents produce; the
  integrator vouches.
- **Docs are load-bearing.** The canonical-documents hierarchy (the handoff
  wins conflicts, and note the conflict when it does), `invariants.md`, and the
  architecture map aren't decoration. They're what let a fresh agent be
  productive in one worktree without re-deriving the whole system.

The through-line: **make correctness cheap to verify, make memory durable, and
let trust scale by resting it on tests rather than vigilance.** That's the whole
trick.
