#!/usr/bin/env bash
# Read-only GitHub offboarding audit. Run with -h for usage.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  offboard-github.sh [options] <github-username> [more usernames]

Read-only report of GitHub access and ownership for departed accounts,
using your own gh login. OpenShift is a separate script.

Options:
  --org ORG         Organization to check (repeatable). Default: $OFFBOARD_ORGS,
                    else "bcgov bcgov-c bcgov-nr".
  --repo OWNER/NAME Repository for the per-repo checks (repeatable).
  --repo-file FILE  File with one OWNER/NAME per line (# comments allowed).
                    Default repo set: repos in the orgs where you have admin.
  --json            Print JSON instead of text.
  -h, --help        Show this help.

A login GitHub does not have is listed and skipped. It is not queried.
Exit codes: 0 nothing found, 1 access found, 2 usage or dependency error,
            3 an API call failed.
EOF
}
die() { echo "offboard-github: $*" >&2; exit 2; }
fail() { echo "offboard-github: $*" >&2; exit 3; }
progress() { echo "offboard-github: $*" >&2; }
lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

ORGS=()
REPOS=()
REPO_FILE=""
JSON=false
USERS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) [[ $# -ge 2 ]] || die "--org needs a value"; ORGS+=("$2"); shift 2 ;;
    --repo) [[ $# -ge 2 ]] || die "--repo needs a value"; REPOS+=("$2"); shift 2 ;;
    --repo-file) [[ $# -ge 2 ]] || die "--repo-file needs a value"; REPO_FILE="$2"; shift 2 ;;
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

finding() { jq -nc --arg u "$1" --arg c "$2" --arg t "$3" --arg d "$4" '{user:$u, check:$c, target:$t, detail:$d}' >> "$FINDINGS"; }
note() { jq -nc --arg u "$1" --arg n "$2" '{user:$u, note:$n}' >> "$NOTES"; }

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

# Issue search allows five OR operators, so an assignee query covers at most six logins.
# Code search rejects a parenthesized OR and returns no hits for a bare OR, so it is one query per login.
search_expr() {
  local out="" w
  for w in "$@"; do out+="${out:+ OR }${w}"; done
  if [[ $# -gt 1 ]]; then printf '(%s)' "$out"; else printf '%s' "$out"; fi
}

LIVE=()
SKIPPED=()
SEARCH_OK=true
declare -A SKIPPED_SET=()
for u in "${USERS[@]}"; do
  if call "users/${u}"; then
    LIVE+=("$u")
  elif [[ "$API_STATUS" == 404 ]]; then
    SKIPPED+=("$u")
    SKIPPED_SET["$u"]=1
    progress "no GitHub account: ${u}"
  else
    api_error "users/${u}"
  fi
done

declare -A USER_TEAMS=()

if [[ ${#LIVE[@]} -gt 0 ]]; then
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
  for o in "${ORGS[@]}"; do orgs_q+=" org:$(lower "$o")"; done

  for o in "${ORGS[@]}"; do
    if call --paginate "orgs/$(lower "$o")/members?per_page=100" --jq '.[].login'; then
      printf '%s\n' "$API_OUT" | tr '[:upper:]' '[:lower:]' > "$TMPD/members"
    elif [[ "$API_STATUS" == 404 ]]; then
      : > "$TMPD/members"
    else
      api_error "orgs/${o}/members"
    fi
    for u in "${LIVE[@]}"; do
      if grep -qxF "$(lower "$u")" "$TMPD/members"; then
        finding "$u" org-membership "$o" "member"
      fi
    done

    # ponytail: one GraphQL document per org, 100 teams per login. hasNextPage is noted and not followed.
    tq='query($o:String!){organization(login:$o){'
    ti=0
    for u in "${LIVE[@]}"; do
      tq+="u${ti}:teams(first:100,userLogins:[\"$(lower "$u")\"]){pageInfo{hasNextPage}nodes{slug}}"
      ti=$((ti + 1))
    done
    tq+='}}'
    call graphql -f query="$tq" -f o="$(lower "$o")" || api_error "graphql teams ${o}"
    live_json="$(printf '%s\n' "${LIVE[@]}" | jq -R . | jq -sc .)"
    while IFS=$'\t' read -r idx more; do
      [[ "$more" == "true" ]] || continue
      note "" "${LIVE[$idx]}: team list truncated at 100 in ${o}"
    done < <(printf '%s' "$API_OUT" | jq -r '
      (.data.organization // {}) | to_entries[]
      | [(.key | ltrimstr("u")), (.value.pageInfo.hasNextPage | tostring)] | @tsv')
    while IFS=$'\t' read -r idx slug; do
      [[ -n "$idx" && -n "$slug" ]] || continue
      u="${LIVE[$idx]}"
      slug="$(lower "$slug")"
      lo="$(lower "$o")"
      lu="$(lower "$u")"
      finding "$u" team "${o}/${slug}" "member"
      USER_TEAMS["${lu}|${lo}"]="${USER_TEAMS["${lu}|${lo}"]:-} ${slug}"
    done < <(printf '%s' "$API_OUT" | jq -r --argjson users "$live_json" '
      (.data.organization // {}) | to_entries[]
      | (.key | ltrimstr("u")) as $i
      | .value.nodes[]? | [$i, .slug] | @tsv')
  done

  for u in "${USERS[@]}"; do
    lu="$(lower "$u")"
    for r in "${REPOS[@]}"; do
      d="${TMPD}/repos/${r//\//__}"
      owner="$(lower "${r%%/*}")"
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
        lw="$(lower "$who")"
        if [[ "$type" == "User" && "$lw" == "$lu" ]]; then
          finding "$u" environment-reviewer "$r" "environment ${env}: required reviewer"
        elif [[ "$type" == "Team" && " ${USER_TEAMS["${lu}|${owner}"]:-} " == *" ${lw} "* ]]; then
          finding "$u" environment-reviewer "$r" "environment ${env}: required reviewer through team ${lw}"
        fi
      done < "$d/environments"
    done
  done

  search_stop() {
    echo "offboard-github: search failed (HTTP ${API_STATUS}): $(tail -n 1 "$ERRF")" >&2
    note "" "search failed (HTTP ${API_STATUS})"
    SEARCH_OK=false
  }

  for u in "${LIVE[@]}"; do
    [[ "$SEARCH_OK" == true ]] || break
    lu="$(lower "$u")"
    search_call code_search --paginate -X GET search/code -f q="${lu} filename:CODEOWNERS${orgs_q}" -f per_page=100 \
      -H 'Accept: application/vnd.github.text-match+json' || { search_stop; break; }
    while IFS=$'\t' read -r repo path; do
      [[ -n "$repo" ]] || continue
      finding "$u" codeowners-search "$repo" "$path"
    done < <(printf '%s' "$API_OUT" | jq -r --arg re "(^|[^A-Za-z0-9-])@${lu}([^A-Za-z0-9-]|$)" \
      '.items[]? | select(any(.text_matches[]?.fragment; test($re; "i"))) | [.repository.full_name, .path] | @tsv' | sort -u)
  done

  i=0
  while [[ "$SEARCH_OK" == true && $i -lt ${#LIVE[@]} ]]; do
    chunk=("${LIVE[@]:i:6}")
    i=$((i + 6))
    prefixed=()
    for u in "${chunk[@]}"; do prefixed+=("assignee:$(lower "$u")"); done
    expr="$(search_expr "${prefixed[@]}")"
    search_call search --paginate -X GET search/issues -f q="is:open ${expr}${orgs_q}" -f per_page=100 \
      --jq '.items[]? | .html_url as $u | (if .pull_request then "pull request" else "issue" end) as $k | .title as $t | (.assignees // [])[]? | [$u, $k, $t, .login] | @tsv' \
      || { search_stop; break; }
    while IFS=$'\t' read -r url kind title login; do
      [[ -n "$url" && -n "$login" ]] || continue
      llogin="$(lower "$login")"
      for u in "${chunk[@]}"; do
        if [[ "$(lower "$u")" == "$llogin" ]]; then
          finding "$u" assigned "$url" "${kind}: ${title}"
        fi
      done
    done <<< "$API_OUT"
  done

  if [[ "$SEARCH_OK" == true ]]; then
    for u in "${LIVE[@]}"; do
      [[ "$SEARCH_OK" == true ]] || break
      search_call search --paginate -X GET search/issues -f q="is:open is:pr user-review-requested:$(lower "$u")${orgs_q}" -f per_page=100 \
        --jq '.items[] | [.html_url, .title] | @tsv' || { search_stop; break; }
      while IFS=$'\t' read -r url title; do
        if [[ -n "$url" ]]; then finding "$u" review-requested "$url" "$title"; fi
      done <<< "$API_OUT"
    done
  fi
fi

count="$(wc -l < "$FINDINGS" | tr -d ' ')"
users_json="$(printf '%s\n' "${USERS[@]}" | jq -R . | jq -sc .)"
if [[ ${#SKIPPED[@]} -eq 0 ]]; then
  skipped_json='[]'
else
  skipped_json="$(printf '%s\n' "${SKIPPED[@]}" | jq -R . | jq -sc .)"
fi
if [[ "$JSON" == "true" ]]; then
  jq -n --argjson users "$users_json" --argjson skipped "$skipped_json" --slurpfile f "$FINDINGS" --slurpfile n "$NOTES" \
    --argjson o "$(printf '%s\n' "${ORGS[@]}" | jq -R . | jq -sc .)" --argjson rc "${#REPOS[@]}" \
    '{orgs: $o, repos_checked: $rc, skipped: $skipped, users: [$users[] as $u | {user: $u, findings: [$f[] | select(.user == $u) | del(.user)]}], notes: [$n[] | .note]}'
else
  declare -A TITLE=(
    [org-membership]="Organization membership" [team]="Teams" [repo-collaborator]="Repository access"
    [codeowners]="CODEOWNERS (checked repositories)" [environment-reviewer]="Environment required reviewers"
    [codeowners-search]="CODEOWNERS (code search)" [assigned]="Open issues and pull requests assigned"
    [review-requested]="Pull requests waiting on their review"
  )
  echo "Organizations: ${ORGS[*]}; repositories checked: ${#REPOS[@]}"
  for u in "${USERS[@]}"; do
    echo
    echo "== ${u}"
    if [[ -n "${SKIPPED_SET[$u]:-}" ]]; then
      echo "   GitHub account not found"
    fi
    if ! jq -e --arg u "$u" 'select(.user == $u)' "$FINDINGS" >/dev/null 2>&1; then
      [[ -n "${SKIPPED_SET[$u]:-}" ]] || echo "   nothing found"
      continue
    fi
    for c in org-membership team repo-collaborator codeowners environment-reviewer codeowners-search assigned review-requested; do
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
  if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo
    echo "Skipped, no GitHub account:"
    for u in "${SKIPPED[@]}"; do echo "  - ${u}"; done
  fi
fi

if [[ "$SEARCH_OK" != true ]]; then exit 3; fi
[[ "$count" -eq 0 ]] || exit 1
exit 0
