#!/usr/bin/env bash
# Read-only OpenShift offboarding audit. Run with -h for usage.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  offboard-openshift.sh --name STRING [--name STRING]... [OPTIONS]

Read-only report of OpenShift RoleBindings whose User subject contains one
of the names, across accessible OpenShift clusters in kubeconfig.
Matching ignores case. No suffix is added. GitHub is a separate script.

Options:
  --name STRING          Name to search for (repeatable).
  -c, --current-cluster  Query only the active cluster context (default is all clusters).
  --context <name>       Target a specific kubeconfig context directly.
  -C, --all-clusters     Query all distinct authenticated clusters in kubeconfig (default).
  --json                 Print JSON instead of text.
  -h, --help             Show this help.

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
all_clusters=true
target_context=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || die "--name needs a value"
      [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]] || die "not a valid name: $2"
      NAMES+=("$2")
      shift 2 ;;
    --name=*)
      val="${1#--name=}"
      [[ "$val" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]] || die "not a valid name: $val"
      NAMES+=("$val")
      shift ;;
    -c|--current-cluster)
      all_clusters=false
      shift ;;
    -C|--all-clusters)
      all_clusters=true
      shift ;;
    --context)
      [[ $# -ge 2 ]] || die "--context needs a value"
      all_clusters=false
      target_context="$2"
      shift 2 ;;
    --context=*)
      all_clusters=false
      target_context="${1#--context=}"
      shift ;;
    --json) JSON=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ ${#NAMES[@]} -gt 0 ]] || { usage >&2; die "pass --name"; }

command -v oc >/dev/null 2>&1 || die "oc is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

# Collect target cluster contexts
declare -a TARGET_CLUSTERS=()

if [[ "$all_clusters" == true ]]; then
  cfg_json=$(oc config view -o json 2>/dev/null || echo '{}')
  distinct_clusters=$(
    echo "$cfg_json" | jq -c '
      . as $root
      | (($root.clusters // []) | map({(.name): (.cluster.server // .name)}) | add // {}) as $cluster_servers
      | ($root.contexts // [])
      | group_by(.context.cluster)
      | map(
          ( (map(select(.name == $root["current-context"])) | first) // .[0] ) as $chosen
          | ($cluster_servers[$chosen.context.cluster] // $chosen.context.cluster) as $srv
          | (
              $srv
              | sub("^https?://"; "")
              | sub(":[0-9]+$"; "")
              | if test("devops\\.gov\\.bc\\.ca$") then
                  sub("^api\\."; "") | sub("\\.devops\\.gov\\.bc\\.ca$"; "")
                else
                  .
                end
            ) as $alias
          | {
              context: $chosen.name,
              cluster: $alias,
              cluster_name: $chosen.context.cluster
            }
        )
    ' 2>/dev/null || echo '[]'
  )

  if [[ "$distinct_clusters" == "[]" || -z "$distinct_clusters" ]]; then
    if oc whoami >/dev/null 2>&1; then
      TARGET_CLUSTERS+=('{"context":"","cluster":"current"}')
    else
      die "oc is not logged in (run: oc login)"
    fi
  else
    while IFS= read -r item; do
      [[ -z "$item" ]] && continue
      TARGET_CLUSTERS+=("$item")
    done < <(echo "$distinct_clusters" | jq -c '.[]')
  fi
else
  # Single cluster mode
  if [[ -n "$target_context" ]]; then
    ctx="$target_context"
    if ! oc --context "$ctx" whoami >/dev/null 2>&1; then
      die "oc is not logged in (run: oc login)"
    fi
  else
    if ! oc whoami >/dev/null 2>&1; then
      die "oc is not logged in (run: oc login)"
    fi
    ctx=""
  fi

  cfg_json=$(oc config view -o json 2>/dev/null || echo '{}')
  cluster_alias=$(
    echo "$cfg_json" | jq -r --arg ctx "$ctx" '
      . as $root
      | (if $ctx != "" then $ctx else ($root["current-context"] // "") end) as $target
      | ($root.contexts // [] | map(select(.name == $target)) | first) as $cur
      | ($root.clusters // [] | map(select(.name == $cur.context.cluster)) | first) as $cur_cluster
      | ($cur_cluster.cluster.server // $cur.context.cluster // "") as $srv
      | (
          $srv
          | sub("^https?://"; "")
          | sub(":[0-9]+$"; "")
          | if test("devops\\.gov\\.bc\\.ca$") then
              sub("^api\\."; "") | sub("\\.devops\\.gov\\.bc\\.ca$"; "")
            elif . == "" then
              "current"
            else
              .
            end
        )
    ' 2>/dev/null || echo "current"
  )

  TARGET_CLUSTERS+=("$(jq -nc --arg ctx "$ctx" --arg alias "$cluster_alias" '{context: $ctx, cluster: $alias}')")
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT
FINDINGS="${TMPD}/findings.jsonl"
NOTES="${TMPD}/notes.jsonl"
: > "$FINDINGS"
: > "$NOTES"
finding() { jq -nc --arg u "$1" --arg cl "$2" --arg c "$3" --arg t "$4" --arg d "$5" --arg cmd "${6:-}" '{user:$u, cluster:$cl, check:$c, target:$t, detail:$d, cmd:$cmd}' >> "$FINDINGS"; }
note() { jq -nc --arg n "$1" '{note:$n}' >> "$NOTES"; }

clusters_succeeded=0
total_namespaces=0

for item in "${TARGET_CLUSTERS[@]}"; do
  c_ctx=$(echo "$item" | jq -r '.context // ""')
  c_label=$(echo "$item" | jq -r '.cluster // "default"')

  c_oc=(oc)
  if [[ -n "$c_ctx" ]]; then
    c_oc+=(--context "$c_ctx")
  fi

  if ! "${c_oc[@]}" whoami >/dev/null 2>&1; then
    if [[ "$all_clusters" == true ]]; then
      echo "Warning: Skipping cluster '$c_label' (context: ${c_ctx:-default}): no active session or unreachable." >&2
      note "Cluster '$c_label' skipped: no active session or unreachable"
      continue
    else
      die "oc is not logged in (run: oc login)"
    fi
  fi

  if ! projects="$("${c_oc[@]}" projects -q 2>/dev/null)"; then
    if [[ "$all_clusters" == true ]]; then
      echo "Warning: Skipping cluster '$c_label': failed to retrieve projects." >&2
      note "Cluster '$c_label' skipped: failed to retrieve projects"
      continue
    else
      fail "oc projects failed"
    fi
  fi

  clusters_succeeded=$((clusters_succeeded + 1))

  c_namespaces=()
  if [[ -n "$projects" ]]; then
    mapfile -t c_namespaces <<< "$projects"
  fi
  total_namespaces=$((total_namespaces + ${#c_namespaces[@]}))

  progress "checking RoleBindings in ${#c_namespaces[@]} namespaces on cluster '$c_label'"

  c_unreadable=0
  for ns in "${c_namespaces[@]}"; do
    [[ -n "$ns" ]] || continue
    if ! rb="$("${c_oc[@]}" get rolebindings -n "$ns" -o json 2>/dev/null)"; then
      c_unreadable=$((c_unreadable + 1))
      continue
    fi
    while IFS=$'\t' read -r subject binding role; do
      [[ -n "$subject" ]] || continue
      subject_l="$(lower "$subject")"
      for name in "${NAMES[@]}"; do
        needle="$(lower "$name")"
        [[ "$subject_l" == *"$needle"* ]] || continue
        if [[ -n "$c_ctx" ]]; then
          cmd="$(printf 'oc --context %q adm policy remove-role-from-user %q %q -n %q' "$c_ctx" "$role" "$subject" "$ns")"
        else
          cmd="$(printf 'oc adm policy remove-role-from-user %q %q -n %q' "$role" "$subject" "$ns")"
        fi
        finding "$name" "$c_label" rolebinding "$ns" "${binding} -> ${role}" "$cmd"
      done
    done < <(printf '%s' "$rb" | jq -r \
      '.items[] | .metadata.name as $b | .roleRef.name as $r | .subjects[]? | select(.kind == "User") | [.name, $b, $r] | @tsv')
  done

  if (( c_unreadable > 0 )); then
    if [[ "$all_clusters" == true && ${#TARGET_CLUSTERS[@]} -gt 1 ]]; then
      note "RoleBindings not readable in ${c_unreadable} namespace(s) on cluster '${c_label}'"
    else
      note "RoleBindings not readable in ${c_unreadable} namespace(s)"
    fi
  fi
done

if [[ "$clusters_succeeded" -eq 0 ]]; then
  die "oc is not logged in (run: oc login)"
fi

count="$(wc -l < "$FINDINGS" | tr -d ' ')"
names_json="$(printf '%s\n' "${NAMES[@]}" | jq -R . | jq -sc .)"
multi_output=false
if [[ "$all_clusters" == true && "$clusters_succeeded" -gt 1 ]]; then
  multi_output=true
fi

if [[ "$JSON" == "true" ]]; then
  jq -n \
    --argjson names "$names_json" \
    --slurpfile f "$FINDINGS" \
    --slurpfile n "$NOTES" \
    --argjson ns "$total_namespaces" \
    --argjson clusters "$clusters_succeeded" \
    '{clusters_checked: $clusters, namespaces_checked: $ns, sections: [$names[] as $u | {name: $u, findings: [$f[] | select(.user == $u) | del(.user)]}], notes: [$n[] | .note]}'
else
  if [[ "$multi_output" == true ]]; then
    echo "Clusters checked: ${clusters_succeeded}"
    echo "Namespaces checked: ${total_namespaces}"
  else
    echo "Namespaces checked: ${total_namespaces}"
  fi
  for u in "${NAMES[@]}"; do
    echo
    echo "== ${u}"
    if ! jq -e --arg u "$u" 'select(.user == $u)' "$FINDINGS" >/dev/null 2>&1; then
      echo "   nothing found"
      continue
    fi
    echo "  RoleBindings"
    jq -r --arg u "$u" --argjson multi "$multi_output" '
      select(.user == $u)
      | (if $multi and (.cluster // "") != "" and .cluster != "current" then
           "   - [\(.cluster)] \(.target): \(.detail)"
         else
           "   - \(.target): \(.detail)"
         end)
    ' "$FINDINGS"
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
