#!/usr/bin/env bash
# Read-only OpenShift offboarding audit. Run with -h for usage.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  offboard-openshift.sh [--github LOGIN]... [--gov NAME]...

Read-only report of OpenShift RoleBindings for departed people, using your
own oc login. GitHub is a separate script.

Options:
  --github LOGIN  GitHub login (repeatable). Matches that name and name@github.
  --gov NAME      gov.bc.ca name, the part before the @ (repeatable).
                  Matches name@gov.bc.ca only.
  --json          Print JSON instead of text.
  -h, --help      Show this help.

Matching ignores case. A GitHub login is not compared to @gov.bc.ca, and a
gov name is not compared to @github.
Exit codes: 0 nothing found, 1 access found, 2 usage or dependency error,
            3 an oc call failed.
EOF
}
die() { echo "offboard-openshift: $*" >&2; exit 2; }
fail() { echo "offboard-openshift: $*" >&2; exit 3; }
progress() { echo "offboard-openshift: $*" >&2; }
lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

GH=()
GOV=()
declare -A GH_LABEL=() GOV_LABEL=()
JSON=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --github)
      [[ $# -ge 2 ]] || die "--github needs a value"
      [[ "$2" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]] || die "not a valid GitHub name: $2"
      GH+=("$2")
      GH_LABEL["$(lower "$2")"]="$2"
      shift 2 ;;
    --gov)
      [[ $# -ge 2 ]] || die "--gov needs a value"
      [[ "$2" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]{0,63})$ ]] || die "not a valid gov.bc.ca name: $2"
      GOV+=("$2")
      GOV_LABEL["$(lower "$2")"]="$2"
      shift 2 ;;
    --json) JSON=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ ${#GH[@]} -gt 0 || ${#GOV[@]} -gt 0 ]] || { usage >&2; die "pass --github or --gov"; }

command -v oc >/dev/null 2>&1 || die "oc is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
oc whoami >/dev/null 2>&1 || die "oc is not logged in (run: oc login)"

TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT
FINDINGS="${TMPD}/findings.jsonl"
NOTES="${TMPD}/notes.jsonl"
: > "$FINDINGS"
: > "$NOTES"
finding() { jq -nc --arg u "$1" --arg c "$2" --arg t "$3" --arg d "$4" '{user:$u, check:$c, target:$t, detail:$d}' >> "$FINDINGS"; }
note() { jq -nc --arg n "$1" '{note:$n}' >> "$NOTES"; }

if ! projects="$(oc projects -q)"; then
  fail "oc projects failed"
fi
NAMESPACES=()
if [[ -n "$projects" ]]; then
  mapfile -t NAMESPACES <<< "$projects"
fi
progress "checking RoleBindings in ${#NAMESPACES[@]} namespaces"
unreadable=0
for ns in "${NAMESPACES[@]}"; do
  [[ -n "$ns" ]] || continue
  if ! rb="$(oc get rolebindings -n "$ns" -o json 2>/dev/null)"; then
    unreadable=$((unreadable + 1))
    continue
  fi
  while IFS=$'\t' read -r subject binding role; do
    [[ -n "$subject" ]] || continue
    subject_l="$(lower "$subject")"
    if [[ "$subject_l" == *"@"* ]]; then
      local_part="${subject_l%%@*}"
      domain="${subject_l#*@}"
    else
      local_part="$subject_l"
      domain=""
    fi
    owner=""
    case "$domain" in
      "" | github) owner="${GH_LABEL[$local_part]:-}" ;;
      gov.bc.ca) owner="${GOV_LABEL[$local_part]:-}" ;;
    esac
    [[ -n "$owner" ]] || continue
    finding "$owner" rolebinding "$ns" "${binding} -> ${role} (subject ${subject_l})"
  done < <(printf '%s' "$rb" | jq -r \
    '.items[] | .metadata.name as $b | .roleRef.name as $r | .subjects[]? | select(.kind == "User") | [.name, $b, $r] | @tsv')
done
if (( unreadable > 0 )); then note "RoleBindings not readable in ${unreadable} namespace(s)"; fi

SECTIONS=()
[[ ${#GH[@]} -eq 0 ]] || SECTIONS+=("${GH[@]}")
[[ ${#GOV[@]} -eq 0 ]] || SECTIONS+=("${GOV[@]}")
count="$(wc -l < "$FINDINGS" | tr -d ' ')"
sections_json="$(printf '%s\n' "${SECTIONS[@]}" | jq -R . | jq -sc .)"
if [[ "$JSON" == "true" ]]; then
  jq -n --argjson sections "$sections_json" --slurpfile f "$FINDINGS" --slurpfile n "$NOTES" --argjson ns "${#NAMESPACES[@]}" \
    '{namespaces_checked: $ns, sections: [$sections[] as $u | {name: $u, findings: [$f[] | select(.user == $u) | del(.user)]}], notes: [$n[] | .note]}'
else
  echo "Namespaces checked: ${#NAMESPACES[@]}"
  for u in "${SECTIONS[@]}"; do
    echo
    echo "== ${u}"
    if ! jq -e --arg u "$u" 'select(.user == $u)' "$FINDINGS" >/dev/null 2>&1; then
      echo "   nothing found"
      continue
    fi
    echo "  RoleBindings"
    jq -r --arg u "$u" 'select(.user == $u) | "   - \(.target): \(.detail)"' "$FINDINGS"
  done
  if [[ -s "$NOTES" ]]; then
    echo
    echo "Notes:"
    jq -r '"  - " + .note' "$NOTES"
  fi
fi

[[ "$count" -eq 0 ]] || exit 1
exit 0
