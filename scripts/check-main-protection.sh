#!/usr/bin/env bash
set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh is required to check main branch protection." >&2
  exit 1
fi

repo="${QUOIN_GITHUB_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
branch="${1:-main}"
bypass_login="${QUOIN_MAIN_BYPASS_LOGIN:?set QUOIN_MAIN_BYPASS_LOGIN to the maintainer GitHub login}"

rules_file="$(mktemp)"
rulesets_file="$(mktemp)"
repo_file="$(mktemp)"
bypass_user_file="$(mktemp)"
trap 'rm -f "$rules_file" "$rulesets_file" "$repo_file" "$bypass_user_file"' EXIT

gh api "repos/${repo}" > "$repo_file"
gh api "repos/${repo}/rules/branches/${branch}" > "$rules_file"
gh api "users/${bypass_login}" > "$bypass_user_file"

ids="$(gh api "repos/${repo}/rulesets" --jq '.[].id')"
{
  echo "["
  first=1
  for id in $ids; do
    if (( first )); then
      first=0
    else
      echo ","
    fi
    gh api "repos/${repo}/rulesets/${id}"
  done
  echo "]"
} > "$rulesets_file"

/usr/bin/python3 - "$repo_file" "$rules_file" "$rulesets_file" "$bypass_user_file" "$branch" <<'PY'
import json
import sys

repo_path, rules_path, rulesets_path, bypass_user_path, branch = sys.argv[1:6]

with open(repo_path, encoding="utf-8") as handle:
    repo = json.load(handle)

with open(rules_path, encoding="utf-8") as handle:
    rules = json.load(handle)

with open(rulesets_path, encoding="utf-8") as handle:
    rulesets = json.load(handle)

with open(bypass_user_path, encoding="utf-8") as handle:
    bypass_user = json.load(handle)

violations = []
effective_by_type = {rule.get("type"): rule for rule in rules}

if repo.get("allow_auto_merge") is not True:
    violations.append("repository must allow auto-merge so protected PRs can merge without admin bypass")

if repo.get("delete_branch_on_merge") is not True:
    violations.append("repository should delete topic branches after merge")

protect_main = None
for ruleset in rulesets:
    if ruleset.get("name") == "Protect main":
        protect_main = ruleset
        break

if not protect_main:
    violations.append('missing ruleset named "Protect main"')
    ruleset_by_type = {}
else:
    if protect_main.get("target") != "branch":
        violations.append('"Protect main" must target branches')
    if protect_main.get("enforcement") != "active":
        violations.append('"Protect main" must be active')

    ref_name = (protect_main.get("conditions") or {}).get("ref_name") or {}
    includes = set(ref_name.get("include") or [])
    if f"refs/heads/{branch}" not in includes and "~DEFAULT_BRANCH" not in includes:
        violations.append(f'"Protect main" must include refs/heads/{branch}')

    bypass_actors = protect_main.get("bypass_actors") or []
    expected_bypass = {
        "actor_id": bypass_user.get("id"),
        "actor_type": "User",
        "bypass_mode": "always",
    }
    if bypass_actors != [expected_bypass]:
        violations.append(
            f'"Protect main" bypass actor must be exactly {bypass_user.get("login")} with always bypass'
        )

    ruleset_by_type = {rule.get("type"): rule for rule in protect_main.get("rules") or []}

for required_type in ("pull_request", "required_status_checks", "non_fast_forward", "deletion"):
    if required_type not in effective_by_type:
        violations.append(f"effective branch rules are missing {required_type}")

pull_request = ruleset_by_type.get("pull_request")
if not pull_request:
    violations.append('"Protect main" is missing pull_request rule')
else:
    params = pull_request.get("parameters") or {}
    if params.get("required_review_thread_resolution") is not True:
        violations.append("pull_request rule must require review thread resolution")
    if params.get("required_approving_review_count") != 0:
        violations.append("pull_request rule should require 0 approvals for the solo-maintainer workflow")

status_checks = ruleset_by_type.get("required_status_checks")
if not status_checks:
    violations.append('"Protect main" is missing required_status_checks rule')
else:
    params = status_checks.get("parameters") or {}
    contexts = {
        check.get("context")
        for check in params.get("required_status_checks", [])
        if isinstance(check, dict)
    }
    if "swift test (macOS)" not in contexts:
        violations.append('required_status_checks must include "swift test (macOS)"')
    if params.get("strict_required_status_checks_policy") is not True:
        violations.append("required_status_checks must require branches to be up to date")

if "non_fast_forward" not in ruleset_by_type:
    violations.append('"Protect main" is missing non_fast_forward rule')

if "deletion" not in ruleset_by_type:
    violations.append('"Protect main" is missing deletion rule')

if violations:
    print(f"Main protection check failed for {branch}:", file=sys.stderr)
    for violation in violations:
        print(f"  - {violation}", file=sys.stderr)
    sys.exit(1)

print(f'Main protection OK: {branch} requires PRs, "swift test (macOS)", up-to-date branches, and protected history.')
PY
