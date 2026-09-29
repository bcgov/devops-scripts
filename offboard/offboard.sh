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
  offboard.sh --github LOGIN [--github LOGIN]... [--gov NAME]...

Runs the GitHub audit, then the OpenShift audit.

With no arguments in a terminal, asks for GitHub logins and then gov.bc.ca
names (the part before the @). Otherwise repeat --github and --gov.
A gov name is optional.

If oc is not logged in, the GitHub report is still printed and OpenShift is
skipped. Exit 1 if either report found access, 3 if either call failed.
EOF
}
die() { echo "offboard: $*" >&2; exit 2; }

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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --github) [[ $# -ge 2 ]] || die "--github needs a value"; USERS+=("$2"); shift 2 ;;
    --gov) [[ $# -ge 2 ]] || die "--gov needs a value"; GOV+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

if [[ ${#USERS[@]} -eq 0 && ${#GOV[@]} -eq 0 ]]; then
  [[ -t 0 ]] || { usage >&2; die "pass --github, or run from a terminal to be asked"; }
  read -r -p "GitHub logins: " gh_line || die "no GitHub logins entered"
  read -r -p "gov.bc.ca names: " gov_line || true
  mapfile -t USERS < <(split_words "$gh_line")
  mapfile -t GOV < <(split_words "${gov_line:-}")
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
oc_cmd=("$OC_SCRIPT")
for u in "${USERS[@]}"; do oc_cmd+=(--github "$u"); done
for g in "${GOV[@]+"${GOV[@]}"}"; do oc_cmd+=(--gov "$g"); done
if ! command -v oc >/dev/null 2>&1 || ! oc whoami >/dev/null 2>&1; then
  echo "OpenShift skipped: oc is not logged in"
  echo "Run this where oc is logged in:"
  printf ' '
  printf ' %q' "${oc_cmd[@]}"
  printf '\n'
else
  set +e
  "${oc_cmd[@]}"
  oc_rc=$?
  set -e
fi

if [[ "$gh_rc" -eq 3 || "$oc_rc" -eq 3 ]]; then exit 3; fi
if [[ "$gh_rc" -eq 1 || "$oc_rc" -eq 1 ]]; then exit 1; fi
if [[ "$gh_rc" -eq 2 || "$oc_rc" -eq 2 ]]; then exit 2; fi
exit 0
