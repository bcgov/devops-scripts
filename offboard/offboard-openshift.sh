#!/usr/bin/env bash
# Read-only OpenShift offboarding audit. Run with -h for usage.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  offboard-openshift.sh [options] [github-username ...]

Read-only report of OpenShift RoleBindings for departed people, using your
own oc login. GitHub is a separate script.

Options:
  --email ADDR  Match this address as a User subject (repeatable).
  --idir NAME   Also match NAME and NAME@idir (repeatable).
  --json        Print JSON instead of text.
  -h, --help    Show this help.

Each GitHub username is matched as that name and as name@github.
Exit codes: 0 nothing found, 1 access found, 2 usage or dependency error,
            3 an oc call failed.
EOF
}
die() { echo "offboard-openshift: $*" >&2; exit 2; }
fail() { echo "offboard-openshift: $*" >&2; exit 3; }
progress() { echo "offboard-openshift: $*" >&2; }
lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

EMAILS=()
IDIRS=()
JSON=false
USERS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email) [[ $# -ge 2 ]] || die "--email needs a value"; EMAILS+=("$2"); shift 2 ;;
    --idir) [[ $# -ge 2 ]] || die "--idir needs a value"; IDIRS+=("$2"); shift 2 ;;
    --json) JSON=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; USERS+=("$@"); break ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) USERS+=("$1"); shift ;;
  esac
done

[[ ${#USERS[@]} -gt 0 || ${#EMAILS[@]} -gt 0 || ${#IDIRS[@]} -gt 0 ]] \
  || { usage >&2; die "at least one GitHub username, --email, or --idir is required"; }
for u in "${USERS[@]}"; do
  [[ "$u" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]] || die "not a valid GitHub username: $u"
done
for e in "${EMAILS[@]}"; do
  [[ "$e" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "not an email address: $e"
done
for i in "${IDIRS[@]}"; do
  [[ "$i" =~ ^[A-Za-z0-9._-]+$ ]] || die "not a valid IDIR name: $i"
done

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

declare -A LABEL=()
remember() { LABEL["$(lower "$1")"]="$2"; }
for u in "${USERS[@]}"; do
  remember "$u" "$u"
  remember "${u}@github" "$u"
done
for e in "${EMAILS[@]}"; do remember "$e" "$e"; done
for i in "${IDIRS[@]}"; do
  remember "$i" "$i"
  remember "${i}@idir" "$i"
done

names_json="$(printf '%s\n' "${!LABEL[@]}" | jq -R . | jq -sc .)"
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
    finding "${LABEL[$subject]}" rolebinding "$ns" "${binding} -> ${role} (subject ${subject})"
  done < <(printf '%s' "$rb" | jq -r --argjson n "$names_json" \
    '.items[] | .metadata.name as $b | .roleRef.name as $r | .subjects[]? | select(.kind == "User") | (.name | ascii_downcase) as $s | select($n | index($s)) | [$s, $b, $r] | @tsv')
done
if (( unreadable > 0 )); then note "RoleBindings not readable in ${unreadable} namespace(s)"; fi

SECTIONS=("${USERS[@]}" "${EMAILS[@]}" "${IDIRS[@]}")
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
