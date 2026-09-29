#!/usr/bin/env bash
#
# Usage:
#   ./offboard-audit.sh [options] <github-username> [more usernames]
#
# Read-only report of the places a departed person still has access or
# ownership, using your own gh login (and your own oc login, if active).
#
# Options:
#   --org ORG         Organization to check (repeatable). Default: $OFFBOARD_ORGS,
#                     else "bcgov bcgov-c bcgov-nr".
#   --repo OWNER/NAME Repository for the per-repo checks (repeatable).
#   --repo-file FILE  File with one OWNER/NAME per line (# comments allowed).
#                     Default repo set: repos in the orgs where you have admin.
#   --idir NAME       Also match this IDIR name in OpenShift RoleBindings
#                     (only with a single username).
#   --json            Print JSON instead of text.
#   -h, --help        Show this help.
#
# Exit codes: 0 nothing found, 1 access found, 2 usage or dependency error,
#             3 an API call failed.

set -euo pipefail

usage() {
  grep -v '^#!' "${0}" | awk '/^#/ { sub(/^# ?/, ""); print; next } NF==0 { exit }'
}
die() { echo "offboard-audit: $*" >&2; exit 2; }
fail() { echo "offboard-audit: $*" >&2; exit 3; }
progress() { echo "offboard-audit: $*" >&2; }

ORGS=()
REPOS=()
REPO_FILE=""
IDIR=""
JSON=false
USERS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) [[ $# -ge 2 ]] || die "--org needs a value"; ORGS+=("$2"); shift 2 ;;
    --repo) [[ $# -ge 2 ]] || die "--repo needs a value"; REPOS+=("$2"); shift 2 ;;
    --repo-file) [[ $# -ge 2 ]] || die "--repo-file needs a value"; REPO_FILE="$2"; shift 2 ;;
    --idir) [[ $# -ge 2 ]] || die "--idir needs a value"; IDIR="$2"; shift 2 ;;
    --json) JSON=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; USERS+=("$@"); break ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) USERS+=("$1"); shift ;;
  esac
done

[[ ${#USERS[@]} -gt 0 ]] || { usage >&2; die "at least one GitHub username is required"; }
for u in "${USERS[@]}"; do
  [[ "$u" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]] || die "not a valid GitHub username: $u"
done
[[ -z "$IDIR" || ${#USERS[@]} -eq 1 ]] || die "--idir can only be used with a single username"
[[ -z "$IDIR" || "$IDIR" =~ ^[A-Za-z0-9._-]+$ ]] || die "not a valid IDIR name: $IDIR"

if [[ ${#ORGS[@]} -eq 0 ]]; then
  read -r -a ORGS <<< "${OFFBOARD_ORGS:-bcgov bcgov-c bcgov-nr}"
  ORGS=("${ORGS[@]//,/ }")
  read -r -a ORGS <<< "${ORGS[*]}"
fi
[[ ${#ORGS[@]} -gt 0 ]] || die "no organizations configured"

if [[ -n "$REPO_FILE" ]]; then
  [[ -r "$REPO_FILE" ]] || die "cannot read repo file: $REPO_FILE"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | tr -d '[:space:]')"
    if [[ -n "$line" ]]; then REPOS+=("$line"); fi
  done < "$REPO_FILE"
fi
for r in "${REPOS[@]}"; do
  [[ "$r" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "not an OWNER/NAME repository: $r"
done

command -v gh >/dev/null 2>&1 || die "gh is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
gh auth status >/dev/null 2>&1 || die "gh is not logged in (run: gh auth login)"

TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT
FINDINGS="${TMPD}/findings.jsonl"
NOTES="${TMPD}/notes.jsonl"
ERRF="${TMPD}/err"
: > "$FINDINGS"
: > "$NOTES"
USERS_FILE="${TMPD}/users"
printf '%s\n' "${USERS[@]}" | tr '[:upper:]' '[:lower:]' > "$USERS_FILE"

# finding USER CHECK TARGET DETAIL
finding() { jq -nc --arg u "$1" --arg c "$2" --arg t "$3" --arg d "$4" '{user:$u, check:$c, target:$t, detail:$d}' >> "$FINDINGS"; }
# note USER NOTE (USER may be empty)
note() { jq -nc --arg u "$1" --arg n "$2" '{user:$u, note:$n}' >> "$NOTES"; }

# call ARGS... : run "gh api ARGS"; output in API_OUT, HTTP status of a failure in API_STATUS.
# Server errors (HTTP 5xx) are retried up to three times.
call() {
  local attempt
  for attempt in 1 2 3; do
    API_STATUS=0
    if API_OUT="$(gh api "$@" 2>"$ERRF")"; then
      return 0
    fi
    API_STATUS="$(grep -oE 'HTTP [0-9]{3}' "$ERRF" | tail -n 1 | cut -d' ' -f2 || true)"
    API_STATUS="${API_STATUS:-000}"
    [[ "$API_STATUS" =~ ^5[0-9][0-9]$ && "$attempt" -lt 3 ]] || return 1
    sleep "$((attempt * 2))"
  done
  return 1
}
api_error() { fail "gh api $1 failed (HTTP ${API_STATUS}): $(tail -n 1 "$ERRF")"; }

# search_call KIND ARGS... : like call, waiting out search rate limits (KIND: search or code_search)
search_call() {
  local kind="$1" attempt reset now
  shift
  for attempt in 1 2 3 4 5; do
    call "$@" && return 0
    if [[ "$API_STATUS" =~ ^(403|429)$ ]] && grep -qi 'rate limit' "$ERRF"; then
      call rate_limit --jq ".resources.${kind}.reset" || api_error rate_limit
      reset="$API_OUT"
      now="$(date +%s)"
      progress "search rate limit reached; waiting $(( reset > now ? reset - now + 1 : 5 ))s (attempt ${attempt})"
      sleep "$(( reset > now ? reset - now + 1 : 5 ))"
      continue
    fi
    return 1
  done
  return 1
}

# Users must exist
for u in "${USERS[@]}"; do
  if ! call "users/${u}"; then
    [[ "$API_STATUS" == 404 ]] && die "no such GitHub user: $u"
    api_error "users/${u}"
  fi
done

# ---- Target repo set (shared by all users)
if [[ ${#REPOS[@]} -eq 0 ]]; then
  progress "listing repositories where you have admin in: ${ORGS[*]}"
  call --paginate 'user/repos?affiliation=owner,collaborator,organization_member&per_page=100' \
    --jq '.[] | select(.permissions.admin) | .full_name' || api_error user/repos
  orgs_json="$(printf '%s\n' "${ORGS[@]}" | jq -R . | jq -sc 'map(ascii_downcase)')"
  mapfile -t REPOS < <(printf '%s\n' "$API_OUT" | jq -Rr --argjson o "$orgs_json" \
    'select(length > 0) | select((split("/")[0] | ascii_downcase) as $x | $o | index($x)) ' | sort -u)
fi
progress "per-repo checks on ${#REPOS[@]} repositories"

CO_QUERY='query($o:String!,$n:String!){repository(owner:$o,name:$n){
  a:object(expression:"HEAD:.github/CODEOWNERS"){...on Blob{text}}
  b:object(expression:"HEAD:.github/codeowners"){...on Blob{text}}
  c:object(expression:"HEAD:CODEOWNERS"){...on Blob{text}}
  d:object(expression:"HEAD:codeowners"){...on Blob{text}}
  e:object(expression:"HEAD:docs/CODEOWNERS"){...on Blob{text}}
  f:object(expression:"HEAD:docs/codeowners"){...on Blob{text}}}}'
CO_JQ='{a:".github/CODEOWNERS",b:".github/codeowners",c:"CODEOWNERS",d:"codeowners",e:"docs/CODEOWNERS",f:"docs/codeowners"} as $p
  | (.data.repository // {}) | [to_entries[] | select(.value.text != null) | {path: $p[.key], text: .value.text}] | first // empty
  | .path as $path | .text | split("\n") | to_entries[] | [$path, (.key + 1 | tostring), .value] | @tsv'

i=0
for r in "${REPOS[@]}"; do
  i=$((i + 1))
  d="${TMPD}/repos/${r//\//__}"
  mkdir -p "$d"
  if (( i % 25 == 0 )); then progress "repo ${i}/${#REPOS[@]}"; fi
  if call --paginate "repos/${r}/collaborators?affiliation=all&per_page=100" --jq '.[] | [.login, .role_name] | @tsv'; then
    printf '%s\n' "$API_OUT" > "$d/all"
    : > "$d/direct"
    # Only ask for direct collaborators when one of the users has access
    if awk -F'\t' '{ print tolower($1) }' "$d/all" | grep -qxF -f "$USERS_FILE"; then
      call --paginate "repos/${r}/collaborators?affiliation=direct&per_page=100" --jq '.[] | .login' || api_error "repos/${r}/collaborators"
      printf '%s\n' "$API_OUT" > "$d/direct"
    fi
  elif [[ "$API_STATUS" =~ ^(403|404)$ ]]; then
    note "" "${r}: collaborators not checked (needs push access to the repository, or it does not exist)"
  else
    api_error "repos/${r}/collaborators"
  fi
  call graphql -f query="$CO_QUERY" -f o="${r%%/*}" -f n="${r#*/}" || api_error "graphql CODEOWNERS ${r}"
  printf '%s' "$API_OUT" | jq -r "$CO_JQ" > "$d/codeowners"
  if call --paginate "repos/${r}/environments?per_page=100" \
    --jq '.environments[]? | .name as $e | .protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]? | [$e, .type, (.reviewer.login // .reviewer.slug)] | @tsv'; then
    printf '%s\n' "$API_OUT" > "$d/environments"
  elif [[ "$API_STATUS" =~ ^(403|404)$ ]]; then
    : > "$d/environments"
    note "" "${r}: environments not checked (repository not found or not readable)"
  else
    api_error "repos/${r}/environments"
  fi
done

orgs_q=""
for o in "${ORGS[@]}"; do orgs_q+=" org:${o}"; done

# ---- Per-user checks
for u in "${USERS[@]}"; do
  lu="$(echo "$u" | tr '[:upper:]' '[:lower:]')"
  progress "checking ${u}"
  declare -A TEAMS=()

  for o in "${ORGS[@]}"; do
    # Organization membership
    if call "orgs/${o}/members/${u}"; then
      finding "$u" org-membership "$o" "member"
    elif [[ "$API_STATUS" != 404 ]]; then
      api_error "orgs/${o}/members/${u}"
    fi
    # Teams visible to you
    call graphql --paginate -f o="$o" -f u="$u" -f query='query($o:String!,$u:String!,$endCursor:String){organization(login:$o){teams(first:100,userLogins:[$u],after:$endCursor){pageInfo{hasNextPage endCursor} nodes{slug}}}}' \
      --jq '.data.organization.teams.nodes[]?.slug' || api_error "graphql teams ${o}"
    lo="$(echo "$o" | tr '[:upper:]' '[:lower:]')"
    TEAMS["$lo"]="$(echo "$API_OUT" | tr '[:upper:]' '[:lower:]' | xargs)"
    for t in ${TEAMS["$lo"]}; do finding "$u" team "${o}/${t}" "member"; done
  done

  # Per-repo checks (cached data)
  for r in "${REPOS[@]}"; do
    d="${TMPD}/repos/${r//\//__}"
    owner="$(echo "${r%%/*}" | tr '[:upper:]' '[:lower:]')"
    if [[ -f "$d/all" ]]; then
      role="$(awk -F'\t' -v u="$lu" 'tolower($1) == u { print $2; exit }' "$d/all")"
      if [[ -n "$role" ]]; then
        if grep -qixF "$u" "$d/direct"; then
          finding "$u" repo-collaborator "$r" "${role} (direct)"
        else
          finding "$u" repo-collaborator "$r" "${role} (through a team or organization role)"
        fi
      fi
    fi
    while IFS=$'\t' read -r path lineno text; do
      finding "$u" codeowners "$r" "${path}:${lineno}: ${text}"
    done < <(awk -F'\t' -v u="$lu" '{ l = tolower($3); sub(/#.*/, "", l); n = split(l, w, /[ \t]+/); for (k = 1; k <= n; k++) if (w[k] == "@" u) { print; next } }' "$d/codeowners")
    while IFS=$'\t' read -r env type who; do
      lw="$(echo "$who" | tr '[:upper:]' '[:lower:]')"
      if [[ "$type" == "User" && "$lw" == "$lu" ]]; then
        finding "$u" environment-reviewer "$r" "environment ${env}: required reviewer"
      elif [[ "$type" == "Team" && " ${TEAMS[$owner]:-} " == *" ${lw} "* ]]; then
        finding "$u" environment-reviewer "$r" "environment ${env}: required reviewer through team ${lw}"
      fi
    done < "$d/environments"
  done

  # CODEOWNERS code search across the orgs
  search_call code_search --paginate -X GET search/code -f q="${u} filename:CODEOWNERS${orgs_q}" -f per_page=100 \
    -H 'Accept: application/vnd.github.text-match+json' || api_error "search/code"
  while IFS=$'\t' read -r repo path; do
    finding "$u" codeowners-search "$repo" "$path"
  done < <(printf '%s' "$API_OUT" | jq -r --arg re "(^|[^A-Za-z0-9-])@${lu}([^A-Za-z0-9-]|$)" \
    '.items[]? | select(any(.text_matches[]?.fragment; test($re; "i"))) | [.repository.full_name, .path] | @tsv' | sort -u)

  # Open issues and PRs assigned; PRs waiting on their review
  search_call search --paginate -X GET search/issues -f q="is:open assignee:${u}${orgs_q}" -f per_page=100 \
    --jq '.items[] | [.html_url, (if .pull_request then "pull request" else "issue" end), .title] | @tsv' || api_error "search/issues"
  while IFS=$'\t' read -r url kind title; do
    if [[ -n "$url" ]]; then finding "$u" assigned "$url" "${kind}: ${title}"; fi
  done <<< "$API_OUT"
  search_call search --paginate -X GET search/issues -f q="is:open is:pr user-review-requested:${u}${orgs_q}" -f per_page=100 \
    --jq '.items[] | [.html_url, .title] | @tsv' || api_error "search/issues"
  while IFS=$'\t' read -r url title; do
    if [[ -n "$url" ]]; then finding "$u" review-requested "$url" "$title"; fi
  done <<< "$API_OUT"
  unset TEAMS
done

# ---- OpenShift RoleBindings (only with an active oc login)
if command -v oc >/dev/null 2>&1 && oc whoami >/dev/null 2>&1; then
  names=()
  for u in "${USERS[@]}"; do names+=("$u" "${u}@github"); done
  [[ -n "$IDIR" ]] && names+=("$IDIR" "${IDIR}@idir")
  names_json="$(printf '%s\n' "${names[@]}" | jq -R 'ascii_downcase' | jq -sc .)"
  unreadable=0
  mapfile -t NAMESPACES < <(oc projects -q)
  progress "OpenShift: checking RoleBindings in ${#NAMESPACES[@]} namespaces"
  for ns in "${NAMESPACES[@]}"; do
    if ! rb="$(oc get rolebindings -n "$ns" -o json 2>/dev/null)"; then
      unreadable=$((unreadable + 1))
      continue
    fi
    while IFS=$'\t' read -r subject binding role; do
      owner_user=""
      for u in "${USERS[@]}"; do
        lu="$(echo "$u" | tr '[:upper:]' '[:lower:]')"
        if [[ "$subject" == "$lu" || "$subject" == "${lu}@github" ]]; then owner_user="$u"; fi
      done
      if [[ -z "$owner_user" ]]; then owner_user="${USERS[0]}"; fi
      finding "$owner_user" openshift-rolebinding "$ns" "${binding} -> ${role} (subject ${subject})"
    done < <(printf '%s' "$rb" | jq -r --argjson n "$names_json" \
      '.items[] | .metadata.name as $b | .roleRef.name as $r | .subjects[]? | select(.kind == "User") | (.name | ascii_downcase) as $s | select($n | index($s)) | [$s, $b, $r] | @tsv')
  done
  if (( unreadable > 0 )); then note "" "OpenShift: RoleBindings not readable in ${unreadable} namespace(s)"; fi
else
  note "" "OpenShift check skipped: oc is not installed or not logged in"
fi

# ---- Report
count="$(wc -l < "$FINDINGS" | tr -d ' ')"
users_json="$(printf '%s\n' "${USERS[@]}" | jq -R . | jq -sc .)"
if [[ "$JSON" == "true" ]]; then
  jq -n --argjson users "$users_json" --slurpfile f "$FINDINGS" --slurpfile n "$NOTES" --argjson o "$(printf '%s\n' "${ORGS[@]}" | jq -R . | jq -sc .)" --argjson rc "${#REPOS[@]}" \
    '{orgs: $o, repos_checked: $rc, users: [$users[] as $u | {user: $u, findings: [$f[] | select(.user == $u) | del(.user)]}], notes: [$n[] | .note]}'
else
  declare -A TITLE=(
    [org-membership]="Organization membership" [team]="Teams" [repo-collaborator]="Repository access"
    [codeowners]="CODEOWNERS (checked repositories)" [environment-reviewer]="Environment required reviewers"
    [codeowners-search]="CODEOWNERS (code search)" [assigned]="Open issues and pull requests assigned"
    [review-requested]="Pull requests waiting on their review" [openshift-rolebinding]="OpenShift RoleBindings"
  )
  echo "Organizations: ${ORGS[*]}; repositories checked: ${#REPOS[@]}"
  for u in "${USERS[@]}"; do
    echo
    echo "== ${u}"
    if ! jq -e --arg u "$u" 'select(.user == $u)' "$FINDINGS" >/dev/null 2>&1; then
      echo "   nothing found"
      continue
    fi
    for c in org-membership team repo-collaborator codeowners environment-reviewer codeowners-search assigned review-requested openshift-rolebinding; do
      lines="$(jq -r --arg u "$u" --arg c "$c" 'select(.user == $u and .check == $c) | "   - \(.target): \(.detail)"' "$FINDINGS")"
      [[ -n "$lines" ]] || continue
      echo "  ${TITLE[$c]}"
      echo "$lines"
    done
  done
  if [[ -s "$NOTES" ]]; then
    echo
    echo "Notes:"
    jq -r '"  - " + (if .user != "" then .user + ": " else "" end) + .note' "$NOTES"
  fi
fi

[[ "$count" -eq 0 ]] || exit 1
exit 0
