#!/usr/bin/env bash
# Remove one GitHub user from an environment required-reviewers rule. Run with -h for usage.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  github-drop-env-reviewer.sh OWNER/REPO ENVIRONMENT LOGIN

Repo-admin: GET the environment, drop LOGIN from required reviewers, PUT the rest.
Does not change org membership, teams, or collaborators.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 3 ]] || { usage >&2; echo "github-drop-env-reviewer: need OWNER/REPO, environment, login" >&2; exit 2; }
repo="$1"
env="$2"
login="$3"
command -v gh >/dev/null 2>&1 || { echo "github-drop-env-reviewer: gh is required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "github-drop-env-reviewer: jq is required" >&2; exit 2; }

uid="$(gh api "users/${login}" | jq .id)"
body="$(gh api "repos/${repo}/environments/${env}" | jq -c --argjson uid "$uid" '
  (.protection_rules // []) as $rules
  | {
      wait_timer: ([$rules[] | select(.type == "wait_timer") | .wait_timer][0] // 0),
      prevent_self_review: ([$rules[] | select(.type == "required_reviewers") | .prevent_self_review][0] // false),
      reviewers: [
        $rules[] | select(.type == "required_reviewers") | .reviewers[]?
        | select((.reviewer.id // .id) != $uid)
        | {type, id: (.reviewer.id // .id)}
      ]
    }
')"
gh api -X PUT "repos/${repo}/environments/${env}" --input - <<<"$body"
