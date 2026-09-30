#!/usr/bin/env bash
# Read-only OpenShift offboarding audit. Run with -h for usage.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  offboard-openshift.sh --name STRING [--name STRING]...

Read-only report of OpenShift RoleBindings whose User subject contains one
of the names, using your own oc login. Matching ignores case. No suffix is
added. GitHub is a separate script.

Options:
  --name STRING  Name to search for (repeatable).
  --json         Print JSON instead of text.
  -h, --help     Show this help.

Each finding includes an oc command to remove that User from that role in
the namespace. This script does not run those commands.

Exit codes: 0 nothing found, 1 access found, 2 usage or dependency error,
            3 an oc call failed.
EOF
}
die() { echo "offboard-openshift: $*" >&2; exit 2; }
fail() { echo "offboard-openshift: $*" >&2; exit 3; }
progress() { echo "offboard-openshift: $*" >&2; }
lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

NAMES=()
JSON=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || die "--name needs a value"
      [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]] || die "not a valid name: $2"
      NAMES+=("$2")
      shift 2 ;;
    --json) JSON=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ ${#NAMES[@]} -gt 0 ]] || { usage >&2; die "pass --name"; }

command -v oc >/dev/null 2>&1 || die "oc is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
oc whoami >/dev/null 2>&1 || die "oc is not logged in (run: oc login)"

TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT
FINDINGS="${TMPD}/findings.jsonl"
NOTES="${TMPD}/notes.jsonl"
: > "$FINDINGS"
: > "$NOTES"
finding() { jq -nc --arg u "$1" --arg c "$2" --arg t "$3" --arg d "$4" --arg cmd "${5:-}" '{user:$u, check:$c, target:$t, detail:$d, cmd:$cmd}' >> "$FINDINGS"; }
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
    for name in "${NAMES[@]}"; do
      needle="$(lower "$name")"
      [[ "$subject_l" == *"$needle"* ]] || continue
      cmd="$(printf 'oc adm policy remove-role-from-user %q %q -n %q' "$role" "$subject" "$ns")"
      finding "$name" rolebinding "$ns" "${binding} -> ${role}" "$cmd"
    done
  done < <(printf '%s' "$rb" | jq -r \
    '.items[] | .metadata.name as $b | .roleRef.name as $r | .subjects[]? | select(.kind == "User") | [.name, $b, $r] | @tsv')
done
if (( unreadable > 0 )); then note "RoleBindings not readable in ${unreadable} namespace(s)"; fi

count="$(wc -l < "$FINDINGS" | tr -d ' ')"
names_json="$(printf '%s\n' "${NAMES[@]}" | jq -R . | jq -sc .)"
if [[ "$JSON" == "true" ]]; then
  jq -n --argjson names "$names_json" --slurpfile f "$FINDINGS" --slurpfile n "$NOTES" --argjson ns "${#NAMESPACES[@]}" \
    '{namespaces_checked: $ns, sections: [$names[] as $u | {name: $u, findings: [$f[] | select(.user == $u) | del(.user)]}], notes: [$n[] | .note]}'
else
  echo "Namespaces checked: ${#NAMESPACES[@]}"
  for u in "${NAMES[@]}"; do
    echo
    echo "== ${u}"
    if ! jq -e --arg u "$u" 'select(.user == $u)' "$FINDINGS" >/dev/null 2>&1; then
      echo "   nothing found"
      continue
    fi
    echo "  RoleBindings"
    jq -r --arg u "$u" 'select(.user == $u) | "   - \(.target): \(.detail)"' "$FINDINGS"
    paste="$(jq -r --arg u "$u" 'select(.user == $u and (.cmd // "") != "") | .cmd' "$FINDINGS")"
    if [[ -n "$paste" ]]; then
      echo
      echo "$paste"
    fi
  done
  if [[ -s "$NOTES" ]]; then
    echo
    echo "Notes:"
    jq -r '"  - " + .note' "$NOTES"
  fi
fi

[[ "$count" -eq 0 ]] || exit 1
exit 0
