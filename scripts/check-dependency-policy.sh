#!/usr/bin/env bash
set -euo pipefail

# Approved remote packages: swift-markdown is the one permitted THIRD-PARTY
# code dependency; MermaidKit is FIRST-PARTY (Quoin's own published package,
# extracted from this repo). Anything else requires written TRD justification.
# Sparkle (auto-update) is justified in docs/reference/dependencies.md and lives
# in the App/macOS Xcode project ONLY — never in the SwiftPM graph this guard
# inspects, so QuoinCore/QuoinRender stay dependency-clean and Linux-buildable.
# It is allowlisted here so the guard stays correct if the app's resolution is
# ever folded in.
approved_urls="https://github.com/swiftlang/swift-markdown.git https://github.com/2389-research/MermaidKit.git https://github.com/2389-research/Vinculum.git https://github.com/sparkle-project/Sparkle"
approved_identities="swift-markdown swift-cmark mermaidkit vinculum sparkle"

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift is required to check Quoin's dependency policy." >&2
  exit 1
fi

package_file="$(mktemp)"
violations_file="$(mktemp)"
trap 'rm -f "$package_file" "$violations_file"' EXIT

swift package dump-package > "$package_file"

/usr/bin/python3 - "$package_file" $approved_urls 2> "$violations_file" <<'PYEOF'
import json
import sys

package_path = sys.argv[1]
approved = set(sys.argv[2:])
with open(package_path, encoding="utf-8") as handle:
    package = json.load(handle)
deps = package.get("dependencies", [])
violations = []

def remote_url(dep):
    source = dep.get("sourceControl", [{}])[0]
    remote = source.get("location", {}).get("remote", [None])[0]
    if isinstance(remote, dict):
        return remote.get("urlString")
    return remote

# Local path dependencies (fileSystem) are first-party code living in this
# repository; the policy governs code fetched from elsewhere.
remote_deps = [dep for dep in deps if "fileSystem" not in dep]

for dep in remote_deps:
    location = remote_url(dep)
    if location not in approved:
        violations.append(location or "<unknown>")

if violations:
    print("\n".join(violations), file=sys.stderr)
PYEOF

if [[ -s "$violations_file" ]]; then
  echo "error: Package.swift contains unapproved package dependencies:" >&2
  sed 's/^/  - /' "$violations_file" >&2
  echo "New code dependencies require written TRD justification before this guard is relaxed." >&2
  exit 1
fi

if [[ -f Package.resolved ]]; then
  /usr/bin/python3 - $approved_identities Package.resolved <<'PYEOF'
import json
import sys

allowed = set(sys.argv[1:-1])
resolved_path = sys.argv[-1]
with open(resolved_path, encoding="utf-8") as handle:
    resolved = json.load(handle)
pins = resolved.get("pins", [])
unexpected = sorted(
    pin.get("identity", "<unknown>")
    for pin in pins
    if pin.get("identity") not in allowed
)

if unexpected:
    print("error: Package.resolved contains unapproved pins:", file=sys.stderr)
    for identity in unexpected:
        print(f"  - {identity}", file=sys.stderr)
    print("Only swift-markdown (+ swift-cmark transitive) and first-party mermaidkit + vinculum are allowed without TRD justification.", file=sys.stderr)
    sys.exit(1)
PYEOF
fi

echo "Dependency policy OK: remotes limited to swift-markdown (third-party) and first-party MermaidKit + Vinculum."
