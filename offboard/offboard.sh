#!/usr/bin/env bash
# Run the GitHub audit and the OpenShift audit as one report per person.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_SCRIPT="${DIR}/offboard-github.sh"
OC_SCRIPT="${DIR}/offboard-openshift.sh"

usage() {
  cat <<'EOF'
Usage:
  offboard.sh
  offboard.sh PERSON [PERSON...]

A person is a GitHub login, or several names joined with = :
  gpascucci=greg.pascucci

Each name is searched for as written. OpenShift matches when the User
subject contains the name. No suffix is added. Names that are valid GitHub
logins are also sent to the GitHub audit. Matching ignores case.

With no arguments in a terminal, asks for the people. If oc is not logged
in, the GitHub report is still printed and OpenShift is skipped.
Exit 1 if either report found access, 3 if either call failed.
EOF
}
die() { echo "offboard: $*" >&2; exit 2; }
lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
is_login() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]]; }

PERSONS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --) shift; PERSONS+=("$@"); break ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) PERSONS+=("$1"); shift ;;
  esac
done

if [[ ${#PERSONS[@]} -eq 0 ]]; then
  [[ -t 0 ]] || { usage >&2; die "pass at least one person, or run from a terminal to be asked"; }
  read -r -p "People: " line || die "no people entered"
  line="${line//,/ }"
  read -r -a PERSONS <<< "$line"
fi
[[ ${#PERSONS[@]} -gt 0 ]] || die "at least one person is required"

declare -a P_SPEC=()
declare -a P_NAMES=()
LOGINS=()
NEEDLES=()
declare -A SEEN_LOGIN=() SEEN_NEEDLE=()
for spec in "${PERSONS[@]}"; do
  [[ "$spec" == *'=='* || "$spec" == '='* || "$spec" == *'=' ]] && die "empty name in: $spec"
  IFS='=' read -r -a parts <<< "$spec"
  [[ ${#parts[@]} -gt 0 ]] || die "empty name in: $spec"
  names=""
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]] || die "not a valid name: $part"
    names+="${names:+$'\t'}${part}"
    if [[ -z "${SEEN_NEEDLE[$part]:-}" ]]; then
      SEEN_NEEDLE[$part]=1
      NEEDLES+=("$part")
    fi
    key="$(lower "$part")"
    if is_login "$part" && [[ -z "${SEEN_LOGIN[$key]:-}" ]]; then
      SEEN_LOGIN[$key]=1
      LOGINS+=("$part")
    fi
  done
  P_SPEC+=("$spec")
  P_NAMES+=("$names")
done

TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT
GH_OUT="${TMPD}/github.json"
OC_OUT="${TMPD}/openshift.json"
echo '{"users":[],"skipped":[],"notes":[]}' > "$GH_OUT"
echo '{"sections":[],"notes":[]}' > "$OC_OUT"

gh_rc=0
if [[ ${#LOGINS[@]} -gt 0 ]]; then
  set +e
  "$GH_SCRIPT" --json -- "${LOGINS[@]}" > "$GH_OUT"
  gh_rc=$?
  set -e
  jq -e . "$GH_OUT" >/dev/null 2>&1 || echo '{"users":[],"skipped":[],"notes":[]}' > "$GH_OUT"
fi

oc_rc=0
ran_oc=false
if ! command -v oc >/dev/null 2>&1 || ! oc whoami >/dev/null 2>&1; then
  echo "OpenShift skipped: oc is not logged in"
  echo "Run this where oc is logged in:"
  printf '%q' "$OC_SCRIPT"
  for n in "${NEEDLES[@]}"; do printf ' --name %q' "$n"; done
  printf '\n'
else
  ran_oc=true
  set +e
  oc_cmd=("$OC_SCRIPT" --json)
  for n in "${NEEDLES[@]}"; do oc_cmd+=(--name "$n"); done
  "${oc_cmd[@]}" > "$OC_OUT"
  oc_rc=$?
  set -e
  jq -e . "$OC_OUT" >/dev/null 2>&1 || echo '{"sections":[],"notes":[]}' > "$OC_OUT"
fi

gh_titles='
  def title:
    if . == "org-membership" then "Organization membership"
    elif . == "team" then "Teams"
    elif . == "repo-collaborator" then "Repository access"
    elif . == "codeowners" then "CODEOWNERS"
    elif . == "codeowners-search" then "CODEOWNERS (code search)"
    elif . == "environment-reviewer" then "Environment required reviewers"
    else . end;
  def note:
    (.cmd // "") as $c
    | ($c | split("\n") | map(select(length > 0)) | (length == 0 or all(test("^#"))));
'

i=0
while [[ $i -lt ${#P_SPEC[@]} ]]; do
  echo
  echo "== ${P_SPEC[$i]}"
  IFS=$'\t' read -r -a parts <<< "${P_NAMES[$i]}"
  shown=" "
  paste_file="${TMPD}/paste-${i}"
  : > "$paste_file"
  for part in "${parts[@]}"; do
    lpart="$(lower "$part")"
    if is_login "$part" && [[ "$shown" != *" ${lpart} "* ]]; then
      shown+="${lpart} "
      echo "  GitHub: ${part}"
      has_user=false
      jq -e --arg u "$part" 'any(.users[]?; (.user | ascii_downcase) == ($u | ascii_downcase))' "$GH_OUT" >/dev/null && has_user=true
      if [[ "$gh_rc" -eq 3 && "$has_user" == false ]]; then
        echo "   GitHub audit failed"
      elif jq -e --arg u "$part" 'any(.skipped[]?; ascii_downcase == ($u | ascii_downcase))' "$GH_OUT" >/dev/null; then
        echo "   GitHub account not found"
      else
        block="$(jq -r --arg u "$part" "$gh_titles"'
          .users[] | select((.user | ascii_downcase) == ($u | ascii_downcase)) | .findings
          | if length == 0 then empty else group_by(.check)[] | "  \(.[0].check | title)",
            (.[] | "   - \(.target): \(.detail)",
              (if (.cmd // "") != "" and note then (.cmd | split("\n")[] | select(length > 0) | "    \(.)") else empty end)) end
        ' "$GH_OUT")"
        if [[ -n "$block" ]]; then
          echo "$block"
        elif [[ "$gh_rc" -eq 3 ]]; then
          echo "   GitHub audit did not finish"
        else
          echo "   nothing found"
        fi
        jq -r --arg u "$part" "$gh_titles"'
          .users[] | select((.user | ascii_downcase) == ($u | ascii_downcase)) | .findings[]
          | select((.cmd // "") != "" and (note | not))
          | .cmd | split("\n")[] | select(length > 0)
        ' "$GH_OUT" >> "$paste_file"
      fi
    fi
    if [[ "$ran_oc" == true ]]; then
      echo "  OpenShift: ${part}"
      if [[ "$oc_rc" -eq 3 ]]; then
        echo "   OpenShift audit failed"
      else
        block="$(jq -r --arg u "$part" '
          .sections[] | select(.name == $u) | .findings
          | if length == 0 then empty else .[] | "   - \(.target): \(.detail)" end
        ' "$OC_OUT")"
        if [[ -n "$block" ]]; then echo "$block"; else echo "   nothing found"; fi
        jq -r --arg u "$part" '
          .sections[] | select(.name == $u) | .findings[]
          | select((.cmd // "") != "") | .cmd
        ' "$OC_OUT" >> "$paste_file"
      fi
    fi
  done
  if [[ -s "$paste_file" ]]; then
    echo
    cat "$paste_file"
  fi
  i=$((i + 1))
done

skipped="$(jq -r '.skipped[]?' "$GH_OUT")"
if [[ -n "$skipped" ]]; then
  echo
  echo "Skipped, no GitHub account:"
  printf '%s\n' "$skipped" | sed 's/^/  - /'
fi

notes="$(jq -rn --slurpfile g "$GH_OUT" --slurpfile o "$OC_OUT" '
  [$g[0].notes[]?, $o[0].notes[]?] | .[] | select(length > 0)
')"
if [[ -n "$notes" ]]; then
  echo
  echo "Notes:"
  printf '%s\n' "$notes" | sed 's/^/  - /'
fi

if [[ "$gh_rc" -eq 3 || "$oc_rc" -eq 3 ]]; then exit 3; fi
if [[ "$gh_rc" -eq 1 || "$oc_rc" -eq 1 ]]; then exit 1; fi
if [[ "$gh_rc" -eq 2 || "$oc_rc" -eq 2 ]]; then exit 2; fi
exit 0
