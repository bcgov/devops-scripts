#!/usr/bin/env bash
# Run the GitHub audit, then the OpenShift audit. Run with -h for usage.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_SCRIPT="${DIR}/offboard-github.sh"
OC_SCRIPT="${DIR}/offboard-openshift.sh"

usage() {
  cat <<'EOF'
Usage:
  offboard.sh
  offboard.sh --github-file FILE [--gov-file FILE]

Runs the GitHub audit, then the OpenShift audit.

With no arguments in a terminal, asks for GitHub logins and then gov.bc.ca
names (the part before the @). Otherwise pass the two lists as files, one
name per line. A gov list is optional.

If oc is not logged in, the GitHub report is still printed and OpenShift is
skipped. Exit 1 if either report found access, 3 if either call failed.
EOF
}
die() { echo "offboard: $*" >&2; exit 2; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

names_from_file() {
  local file="$1" line
  [[ -r "$file" ]] || die "cannot read $file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -n "$line" ]] && printf '%s\n' "$line"
  done < "$file"
}

GITHUB_FILE=""
GOV_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --github-file) [[ $# -ge 2 ]] || die "--github-file needs a value"; GITHUB_FILE="$2"; shift 2 ;;
    --gov-file) [[ $# -ge 2 ]] || die "--gov-file needs a value"; GOV_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

split_words() {
  local line="$1" w
  local -a words=()
  line="${line//,/ }"
  read -r -a words <<< "$line"
  for w in "${words[@]+"${words[@]}"}"; do
    [[ -n "$w" ]] && printf '%s\n' "$w"
  done
}

USERS=()
GOV=()
PROMPTED=false
if [[ -z "$GITHUB_FILE" && -z "$GOV_FILE" ]]; then
  [[ -t 0 ]] || { usage >&2; die "pass --github-file, or run from a terminal to be asked"; }
  PROMPTED=true
  read -r -p "GitHub logins: " gh_line || die "no GitHub logins entered"
  read -r -p "gov.bc.ca names: " gov_line || true
  mapfile -t USERS < <(split_words "$gh_line")
  mapfile -t GOV < <(split_words "${gov_line:-}")
  TMPD="$(mktemp -d)"
  trap 'rm -rf "${TMPD}"' EXIT
  GITHUB_FILE="${TMPD}/github.txt"
  printf '%s\n' "${USERS[@]}" > "$GITHUB_FILE"
  if [[ ${#GOV[@]} -gt 0 ]]; then
    GOV_FILE="${TMPD}/gov.txt"
    printf '%s\n' "${GOV[@]}" > "$GOV_FILE"
  fi
else
  [[ -n "$GITHUB_FILE" ]] || die "pass --github-file"
  mapfile -t USERS < <(names_from_file "$GITHUB_FILE")
  if [[ -n "$GOV_FILE" ]]; then
    mapfile -t GOV < <(names_from_file "$GOV_FILE")
  fi
fi
[[ ${#USERS[@]} -gt 0 ]] || die "at least one GitHub login is required"

echo "=== GitHub ==="
set +e
"$GH_SCRIPT" -- "${USERS[@]}"
gh_rc=$?
set -e

echo
echo "=== OpenShift ==="
oc_rc=0
if ! command -v oc >/dev/null 2>&1 || ! oc whoami >/dev/null 2>&1; then
  echo "OpenShift skipped: oc is not logged in"
  echo "Run this where oc is logged in:"
  if [[ "$PROMPTED" == true ]]; then
    echo "  $(printf '%q' "$OC_SCRIPT") --github-file github.txt${GOV_FILE:+ --gov-file gov.txt}"
    echo "GitHub logins: ${USERS[*]}"
    [[ ${#GOV[@]} -eq 0 ]] || echo "gov.bc.ca names: ${GOV[*]}"
  else
    cmd="$(printf '%q' "$OC_SCRIPT") --github-file $(printf '%q' "$GITHUB_FILE")"
    [[ -z "$GOV_FILE" ]] || cmd+=" --gov-file $(printf '%q' "$GOV_FILE")"
    echo "  ${cmd}"
  fi
else
  set +e
  if [[ -n "$GOV_FILE" ]]; then
    "$OC_SCRIPT" --github-file "$GITHUB_FILE" --gov-file "$GOV_FILE"
  else
    "$OC_SCRIPT" --github-file "$GITHUB_FILE"
  fi
  oc_rc=$?
  set -e
fi

if [[ "$gh_rc" -eq 3 || "$oc_rc" -eq 3 ]]; then exit 3; fi
if [[ "$gh_rc" -eq 1 || "$oc_rc" -eq 1 ]]; then exit 1; fi
if [[ "$gh_rc" -eq 2 || "$oc_rc" -eq 2 ]]; then exit 2; fi
exit 0
