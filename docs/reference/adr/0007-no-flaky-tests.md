# 0007 — There are no flaky tests, only bad tests

Status: Accepted (user directive, 2026-07-14).

## Context
FlipTransitionFidelityTests failed ~50% of runs with a mysterious 0.55
pixel-correlation, and was about to be labeled an environmental "GPU flake."

## Decision
Intermittent failures are never labeled and ignored. Either the test
measures through a nondeterministic channel (fix the channel) or the code
races (fix the race). Diagnose by A/B-ing the suspect commit with repeated
runs, then instrumenting the failing readout.

## Consequences
- The flip test's failure was NOT the GPU: its blank-frame retry called
  RunLoop.run, draining the main queue and STARTING the deferred animations
  it then measured through (~50ms into a 240ms slide = the exact 0.55).
  Retries in AppKit pixel tests must Thread.sleep; a tripwire assertion now
  names the mechanism if a drain is ever reintroduced. 12/12 green since.
- Corpus/property tests assert minimum check counts so silent bailing can't
  fake a pass.

## Evidence
Commit 729ae2b; docs/reference/invariants.md #18–19; memory:
no-flaky-tests-fix-definitively.
