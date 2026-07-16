# Security Policy

## Supported Versions

Quoin is pre-release software. Security fixes are handled on `main` first and
carried into any active release branch if one exists. Older experimental
branches are not supported unless they are explicitly named in a release note.

## Reporting a Vulnerability

Do not open a public issue for a private vulnerability. Use GitHub's private
vulnerability reporting for this repository when available, or contact the
maintainer privately and include:

- a concise description of the issue
- affected Quoin version, branch, or commit
- reproduction steps or a minimal document
- whether user documents, filesystem access, exports, logs, or rendered output
  can expose private data

Reports are acknowledged as soon as practical. Fixes are developed privately
when disclosure would put users or their notes at risk, then published with an
appropriate summary once a patch is available.

## Security and Privacy Boundaries

Quoin is designed for local Markdown libraries and privacy-sensitive notes.
Security review should pay particular attention to:

- local file access, security-scoped bookmarks, sandbox entitlements, and file
  watcher behavior
- autosave, conflict handling, external file changes, and byte-lossless
  untouched regions
- image insertion, local asset copying, export, print, Quick Look, and sharing
  paths
- raw HTML, remote images, Mermaid, LaTeX, and unsupported-source fallback
  rendering
- logs, crash diagnostics, screenshots, fixture publishing, and any generated
  artifacts that might contain note content

The runtime privacy stance is strict: no telemetry, no indexing service owned
by Quoin, no JavaScript runtime, no embedded web view, and no network access
for normal local editing. The single exception is the Sparkle software-update
check (a signed appcast fetch), which is the app's only network traffic, is
user-disableable in Settings, and never transmits document content — see
[docs/reference/distribution.md](docs/reference/distribution.md). Any change
that weakens this stance needs explicit design and TRD review before
implementation.
