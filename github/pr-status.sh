#!/usr/bin/env bash
# shellcheck disable=SC2016  # GraphQL variables are literal
# Report the open PRs that need you, or check one PR's readiness live. Run with -h for usage.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  pr-status.sh [options]                 Report your open PRs
  pr-status.sh [options] <url|number>    Check one PR's readiness

Uses your own gh login (GITHUB_TOKEN and GH_TOKEN are ignored). Read-only.

Report mode (no PR given): lists open PRs in repos you can push to that are
authored by, assigned to, or awaiting review from the gh user (@me), in two
groups: waiting on review or merge, and failing or changes requested.
Default scope: every non-archived repo your gh user can push to.

Check mode (a PR URL or number): checks the PR live and prints one line per
check: open, checks finished and green, 0 unresolved review threads, not
behind its base, mergeable apart from review, and a quiet period since the
last push. A number uses the current directory's repo unless -R is set.

Options:
  --orgs A,B           Report mode: only repos owned by these orgs or users.
  --repos A/X,B/Y      Report mode: only these repos.
  --exclude PATTERN    Report mode: skip repos matching a shell glob on
                       OWNER/NAME (repeatable), e.g. 'my-org/old-*'.
  -R OWNER/NAME        Check mode: repo for a PR number.
  --quiet-minutes N    Check mode: minutes since the last push. Default: 10.
  --hold-prefix TEXT   Check mode: also fail when the PR description starts
                       with TEXT, e.g. 'ON HOLD:'. Off unless set.
  -h, --help           Show this help.

To rerun runs that failed on a blocked network connection, use
rerun-blocked.sh in this directory.

Exit codes: 0 done (check mode: ready), 1 check mode: not ready,
2 usage or dependency error.
USAGE
}

die() { echo "pr-status: $*" >&2; exit 2; }
need() { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value"; }

ORGS="" REPOS="" PR="" REPO="" QUIET=10 HOLD=""
EXCLUDE=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --orgs) need "$@"; ORGS=$2; shift 2 ;;
    --repos) need "$@"; REPOS=$2; shift 2 ;;
    --exclude) need "$@"; EXCLUDE+=("$2"); shift 2 ;;
    -R) need "$@"; [[ $2 == */* ]] || die "-R must be OWNER/NAME"; REPO=$2; shift 2 ;;
    --quiet-minutes) need "$@"; [[ $2 =~ ^[0-9]+$ ]] || die "--quiet-minutes must be a whole number"; QUIET=$2; shift 2 ;;
    --hold-prefix) need "$@"; HOLD=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown argument: $1" ;;
    *) [[ -z $PR ]] || die "only one PR at a time"; PR=$1; shift ;;
  esac
done
if [[ -n $PR ]]; then
  [[ -z $ORGS && -z $REPOS && ${#EXCLUDE[@]} -eq 0 ]] || die "--orgs, --repos and --exclude are for report mode"
  [[ $PR =~ ^[0-9]+$ || $PR =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+ ]] || die "PR must be a number or a pull request URL"
else
  [[ -z $REPO && -z $HOLD ]] || die "-R and --hold-prefix need a PR"
  [[ -z $ORGS || -z $REPOS ]] || die "use only one of --orgs and --repos"
fi

unset GITHUB_TOKEN GH_TOKEN
command -v gh >/dev/null || die "gh not found"
command -v jq >/dev/null || die "jq not found"

check_pr() {
  local args=("$PR") pr url num repo owner name head fail=0 pending failed total threads behind mergeable mss pushed age now_head base
  [[ -n $REPO ]] && args+=(-R "$REPO")
  ok()  { printf 'ok    %s\n' "$1"; }
  bad() { printf 'FAIL  %s\n' "$1"; fail=1; }
  pr=$(gh pr view "${args[@]}" --json number,url,isDraft,state,body,mergeable,mergeStateStatus,headRefOid,baseRefName,statusCheckRollup) ||
    die "could not read the PR"
  url=$(jq -r '.url // empty' <<<"$pr"); [[ -n $url ]] || die "gh returned no PR data"
  num=$(jq -r .number <<<"$pr")
  repo=$(sed -E 's#https://github.com/([^/]+/[^/]+)/pull/.*#\1#' <<<"$url")
  owner=${repo%/*} name=${repo#*/}
  head=$(jq -r .headRefOid <<<"$pr") base=$(jq -r .baseRefName <<<"$pr")
  echo "$url (checked $(date '+%Y-%m-%d %H:%M %Z'))"

  if [[ $(jq -r .state <<<"$pr") == OPEN ]]; then ok "open"; else bad "not open"; fi
  if [[ -n $HOLD ]]; then
    if [[ $(jq -r '.body // ""' <<<"$pr") == "$HOLD"* ]]; then bad "description starts with $HOLD"; else ok "not on hold"; fi
  fi

  pending=$(jq '[.statusCheckRollup[] | select((.status // "COMPLETED") != "COMPLETED" or (.state // "") == "PENDING" or (.state // "") == "EXPECTED")] | length' <<<"$pr")
  failed=$(jq -r '[.statusCheckRollup[] | select((.conclusion // .state) as $c | $c != null and ($c | IN("SUCCESS","NEUTRAL","SKIPPED","COMPLETED","PENDING","EXPECTED","")) | not) | (.name // .context)] | join(", ")' <<<"$pr")
  total=$(jq '.statusCheckRollup | length' <<<"$pr")
  if (( pending > 0 )); then bad "checks: $pending still running"
  elif [[ -n $failed ]]; then bad "checks failed: $failed"
  else ok "checks: $total done and green"; fi

  threads=$(gh api graphql --paginate -f owner="$owner" -f name="$name" -F num="$num" -f query='
    query($owner:String!,$name:String!,$num:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$num){
      reviewThreads(first:100,after:$endCursor){nodes{isResolved} pageInfo{hasNextPage endCursor}}}}}' \
    --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved|not)] | length' | awk '{n+=$1} END{print n+0}')
  if (( threads == 0 )); then ok "0 unresolved threads"; else bad "$threads unresolved review thread(s)"; fi

  behind=$(gh api "repos/$repo/compare/$base...$head" --jq .behind_by)
  if (( behind == 0 )); then ok "0 commits behind $base"; else bad "$behind commit(s) behind $base"; fi

  mergeable=$(jq -r .mergeable <<<"$pr") mss=$(jq -r .mergeStateStatus <<<"$pr")
  case "$mergeable/$mss" in
    MERGEABLE/BLOCKED|MERGEABLE/CLEAN|MERGEABLE/HAS_HOOKS|MERGEABLE/DRAFT) ok "mergeable ($mss)" ;;
    *) bad "not mergeable: mergeable=$mergeable mergeStateStatus=$mss" ;;
  esac

  # Push time: the earliest check suite on the head commit.
  pushed=$(gh api "repos/$repo/commits/$head/check-suites" --jq '[.check_suites[].created_at] | min // empty')
  if [[ -z $pushed ]]; then bad "push time unknown (no check suites on the head commit yet)"
  else
    age=$(( ($(date +%s) - $(date -d "$pushed" +%s)) / 60 ))
    if (( age >= QUIET )); then ok "last push ${age} min ago"; else bad "last push ${age} min ago (need ${QUIET})"; fi
  fi

  now_head=$(gh pr view "$url" --json headRefOid --jq .headRefOid)
  [[ $now_head == "$head" ]] || bad "new push during the check; run again"

  if (( fail )); then echo "NOT READY"; exit 1; fi
  if jq -e .isDraft <<<"$pr" >/dev/null; then echo "READY (still a draft: gh pr ready $num -R $repo)"; else echo "READY"; fi
}

if [[ -n $PR ]]; then check_pr; exit 0; fi

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
login=$(gh api user --jq .login) || die "could not read the gh user; run gh auth login"
echo "Reporting open PRs for $login in ${#repos[@]} repos"

search() { # $1 = tag, $2 = search qualifiers
  gh api graphql --paginate -f q="is:pr is:open archived:false $2" -f query='
    query($q:String!,$endCursor:String){search(query:$q,type:ISSUE,first:50,after:$endCursor){
      pageInfo{hasNextPage endCursor}
      nodes{... on PullRequest{url isDraft reviewDecision mergeStateStatus
        repository{nameWithOwner}
        commits(last:1){nodes{commit{statusCheckRollup{state}}}}}}}}' \
    --jq ".data.search.nodes[] | . + {tag:\"$1\"}"
}

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
{ search review "review-requested:$login" && search assigned "assignee:$login" && search authored "author:$login"; } |
  jq -s --argjson repos "$(printf '%s\n' "${repos[@]}" | jq -R . | jq -sc .)" -r '
  group_by(.url) | map(.[0] + {tags: map(.tag)}) | .[]
  | select(.repository.nameWithOwner as $r | $repos | index($r))
  | (.tags | index("review") != null) as $rev
  | (.tags | index("assigned") != null) as $asg
  | (.tags | index("authored") != null) as $own
  | (.commits.nodes[0].commit.statusCheckRollup.state // "NONE") as $ci
  | if ($own or $asg) and ($ci == "FAILURE" or $ci == "ERROR") then "2\tfailing checks\t\(.url)"
    elif ($own or $asg) and .reviewDecision == "CHANGES_REQUESTED" then "2\tchanges requested\t\(.url)"
    elif $rev then "1\treview requested\t\(.url)"
    elif .isDraft then empty
    elif $own and (.reviewDecision == "APPROVED" or .mergeStateStatus == "CLEAN") and ($ci != "PENDING") then "1\tready to merge\t\(.url)"
    elif $asg then "1\tassigned\t\(.url)"
    else empty end' | sort -u >"$tmp"

echo "== Waiting on review or merge"
awk -F'\t' '$1==1 {printf "%-17s %s\n", $2, $3}' "$tmp"
echo "== Failing or changes requested"
awk -F'\t' '$1==2 {printf "%-17s %s\n", $2, $3}' "$tmp"
echo "(checked $(date '+%Y-%m-%d %H:%M %Z'))"
