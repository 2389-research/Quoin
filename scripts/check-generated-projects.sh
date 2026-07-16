#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

generated_projects=(
  "App/macOS/Quoin.xcodeproj"
  "App/iOS/QuoinIOS.xcodeproj"
)

fail=0

for project in "${generated_projects[@]}"; do
  if [[ -n "$(git ls-files -- "$project")" ]]; then
    echo "error: generated project is tracked: $project" >&2
    fail=1
  fi

  if ! git check-ignore --no-index -q "$project/"; then
    echo "error: generated project is not ignored by .gitignore: $project" >&2
    fail=1
  fi
done

if (( fail != 0 )); then
  cat >&2 <<'EOF'

Quoin app projects are generated from App/*/project.yml with XcodeGen.
Keep .xcodeproj bundles out of git; regenerate them locally or in CI.
EOF
  exit 1
fi

echo "Generated Xcode project policy OK"
