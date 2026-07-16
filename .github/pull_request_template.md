## Summary

-

## Linked Issues

-

## Architecture Invariants

- [ ] Markdown source string plus AST remain the source of truth; attributed strings are projection only.
- [ ] Untouched source regions remain byte-lossless through open, edit, and save.
- [ ] Documents remain plain `.md` files on disk; folders remain directories.
- [ ] View models remain platform-free; only navigation containers differ.
- [ ] System shortcuts are not overridden (`Cmd-P`, `Cmd-E`, `Cmd-H`).
- [ ] Local-only, zero-JavaScript runtime stance is preserved.

## Tests Run

-

## Screenshot / UI Notes

-

## Dependency Policy

- [ ] No new code dependency was added, or the TRD contains written justification before the policy was relaxed.
- [ ] `bash scripts/check-dependency-policy.sh` passes.
