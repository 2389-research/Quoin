#!/usr/bin/env bash
set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh is required to check issue triage metadata." >&2
  exit 1
fi

issues_file="$(mktemp)"
trap 'rm -f "$issues_file"' EXIT

gh issue list --state open --limit 1000 --json number,title,labels,milestone > "$issues_file"

/usr/bin/python3 - "$issues_file" <<'PY'
import json
import sys

issues_path = sys.argv[1]
with open(issues_path, encoding="utf-8") as handle:
    issues = json.load(handle)

violations = []
for issue in issues:
    labels = sorted(label.get("name", "") for label in issue.get("labels", []))
    priorities = [name for name in labels if name.startswith("priority:")]
    areas = [name for name in labels if name.startswith("area:")]
    missing = []

    if "status:triaged" not in labels:
        missing.append("status:triaged")
    if len(priorities) != 1:
        if priorities:
            missing.append("exactly one priority:* label (found " + ", ".join(priorities) + ")")
        else:
            missing.append("exactly one priority:* label")
    if not areas:
        missing.append("at least one area:* label")
    if not issue.get("milestone"):
        missing.append("milestone")

    if missing:
        violations.append((issue["number"], issue["title"], missing))

if violations:
    print("Open issue triage metadata is incomplete:", file=sys.stderr)
    for number, title, missing in violations:
        print(f"  #{number} {title}", file=sys.stderr)
        for item in missing:
            print(f"    - missing {item}", file=sys.stderr)
    sys.exit(1)

print(f"Issue triage OK: {len(issues)} open issues are triaged with priority, area, and milestone metadata.")
PY
