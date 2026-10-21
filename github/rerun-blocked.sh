#!/usr/bin/env bash
# Find GitHub Actions runs that failed on a blocked network connection and offer to rerun them.
# Run with -h for usage.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  rerun-blocked.sh [options]

Scans recent failed GitHub Actions runs, lists the ones whose failed-job log
matches a blocked-connection pattern, then asks before rerunning them. Uses
your own gh login (GITHUB_TOKEN and GH_TOKEN are ignored).

Default scope: every non-archived repo your gh user can push to.

Options:
  --orgs A,B         Only repos owned by these orgs or users.
  --repos A/X,B/Y    Only these repos (skips the repo discovery).
  --exclude PATTERN  Skip repos matching a shell glob on OWNER/NAME
                     (repeatable), e.g. 'my-org/old-*'.
  --days N           Runs created in the last N days. Default: 2.
  --pattern REGEX    Extended regex matched against the failed-job log.
                     Default: 'dial tcp [0-9.]+:6443: i/o timeout' (runner
                     blocked from the OpenShift API).
  --yes              Rerun without asking.
  -h, --help         Show this help.

Only the latest run per workflow and branch is checked, and only if it failed.
A matching run is skipped when it is not on attempt 1, is still running or
waiting on approval, has a job named prod/production, or deployed its commit
to a prod/production environment. Reruns use `gh run rerun <id> --failed`.
Without a terminal (CI, cron, a pipe) it only reports, unless --yes is set.

Exit codes: 0 done, 1 a rerun failed, 2 usage or dependency error.
USAGE
}

die() { echo "rerun-blocked: $*" >&2; exit 2; }
need() { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value"; }

ORGS="" REPOS="" DAYS=2 YES=false
PATTERN='dial tcp [0-9.]+:6443: i/o timeout'
EXCLUDE=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --orgs) need "$@"; ORGS=$2; shift 2 ;;
    --repos) need "$@"; REPOS=$2; shift 2 ;;
    --exclude) need "$@"; EXCLUDE+=("$2"); shift 2 ;;
    --days) need "$@"; [[ $2 =~ ^[1-9][0-9]*$ ]] || die "--days must be a positive whole number"; DAYS=$2; shift 2 ;;
    --pattern) need "$@"; PATTERN=$2; shift 2 ;;
    --yes) YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -z $ORGS || -z $REPOS ]] || die "use only one of --orgs and --repos"
rc=0; grep -Eq -- "$PATTERN" <<<"" 2>/dev/null || rc=$?
[[ $rc -le 1 ]] || die "--pattern is not a valid extended regex"

unset GITHUB_TOKEN GH_TOKEN
command -v gh >/dev/null || die "gh not found"
command -v jq >/dev/null || die "jq not found"

excluded() { # $1 = repo
  local pat
  for pat in "${EXCLUDE[@]}"; do
    # shellcheck disable=SC2053  # glob match is intended
    [[ $1 == $pat ]] && return 0
  done
  return 1
}

if [[ -n $REPOS ]]; then
  mapfile -t all < <(tr ',' '\n' <<<"$REPOS" | sed '/^$/d')
  for r in "${all[@]}"; do [[ $r == */* ]] || die "--repos entries must be OWNER/NAME: $r"; done
else
  orgs_json=$(tr ',' '\n' <<<"$ORGS" | sed '/^$/d' | jq -R . | jq -sc .)
  mapfile -t all < <(gh api --paginate 'user/repos?per_page=100&affiliation=owner,collaborator,organization_member' \
    --jq '.[] | select(.archived | not) | select(.permissions.push) | .full_name' |
    jq -Rr --argjson orgs "$orgs_json" 'select(($orgs | length) == 0 or ((split("/")[0] | ascii_downcase) as $o | $orgs | map(ascii_downcase) | index($o)))' | sort -u)
fi
repos=()
for r in "${all[@]}"; do excluded "$r" || repos+=("$r"); done
[[ ${#repos[@]} -gt 0 ]] || die "no repos to scan"
echo "Scanning ${#repos[@]} repos for failed runs from the last $DAYS days matching: $PATTERN"

since=$(date -u -d "-$DAYS days" +%Y-%m-%d)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

check_repo() { # $1 = repo; prints "ok|skip <tab> url <tab> id <tab> reason"
  local repo=$1 id url run why
  gh run list -R "$repo" --created ">=$since" -L 1000 \
    --json databaseId,url,workflowDatabaseId,headBranch,createdAt,conclusion 2>/dev/null |
    jq -r 'group_by([.workflowDatabaseId, .headBranch])[] | max_by(.createdAt)
           | select(.conclusion | IN("failure","timed_out")) | "\(.databaseId)\t\(.url)"' |
    while IFS=$'\t' read -r id url; do
      gh run view "$id" -R "$repo" --log-failed 2>/dev/null | grep -Eq -- "$PATTERN" || continue
      run=$(gh run view "$id" -R "$repo" --json attempt,status,headSha,jobs) || { printf 'skip\t%s\t%s\tcould not read run\n' "$url" "$id"; continue; }
      why=""
      if (( $(jq .attempt <<<"$run") >= 2 )); then why="already rerun (attempt $(jq .attempt <<<"$run"))"
      elif [[ $(jq -r .status <<<"$run") != completed ]]; then why="not finished or waiting on approval"
      elif jq -e '.jobs[].name | test("\\bprod(uction)?\\b"; "i")' <<<"$run" >/dev/null; then why="has a PROD job"
      elif gh api "repos/$repo/deployments?sha=$(jq -r .headSha <<<"$run")" --jq '.[].environment' |
        grep -Eqi '\bprod(uction)?\b'; then why="deploys to PROD"
      fi
      if [[ -n $why ]]; then printf 'skip\t%s\t%s\t%s\n' "$url" "$id" "$why"
      else printf 'ok\t%s\t%s\t\n' "$url" "$id"; fi
    done
}
export -f check_repo
export since PATTERN
printf '%s\n' "${repos[@]}" | xargs -P 4 -I{} bash -c 'check_repo "$1" || echo "WARN could not scan $1" >&2' _ {} |
  sort >"$tmp/found"

awk -F'\t' '$1=="skip" {printf "skip   %s (%s)\n", $2, $4}' "$tmp/found"
awk -F'\t' '$1=="ok" {printf "found  %s\n", $2}' "$tmp/found"
n=$(awk -F'\t' '$1=="ok"' "$tmp/found" | wc -l)
if [[ $n -eq 0 ]]; then echo "0 blocked runs to rerun."; exit 0; fi

if ! $YES; then
  if [[ ! -t 0 || ! -t 1 ]]; then echo "$n blocked runs found. No terminal, so not rerunning (use --yes)."; exit 0; fi
  read -r -p "$n blocked runs found, rerun them? [y/N] " answer
  [[ $answer =~ ^[Yy]([Ee][Ss])?$ ]] || { echo "Not rerun."; exit 0; }
fi

status=0
while IFS=$'\t' read -r kind url id _; do
  [[ $kind == ok ]] || continue
  repo=$(sed -E 's#https://github.com/([^/]+/[^/]+)/actions/runs/.*#\1#' <<<"$url")
  if gh run rerun "$id" -R "$repo" --failed; then echo "rerun  $url"; else echo "FAILED $url" >&2; status=1; fi
done <"$tmp/found"
exit "$status"
