#!/bin/bash
#
# OpenShift Route and Vanity URL Discovery
# Usage:
#   ./list_routes.sh [OPTIONS]
#
# Discovers and inventories OpenShift routes across accessible namespaces.
# By default, filters out default cluster wildcard routes and unencrypted (None)
# routes to focus on custom vanity domains for TLS monitoring.
#
# Options:
#   -C, --all-clusters   Query all distinct authenticated clusters in kubeconfig (e.g. Silver and Gold)
#       --context <name> Target a specific kubeconfig context
#   -a, --all            Include all routes (including cluster wildcard and unencrypted routes)
#   -v, --vanity-only    Filter out cluster wildcard and unencrypted routes (default behavior)
#   -u, --urls-only      Output only raw, unique URLs
#   -j, --json           Output structured JSON array
#   -h, --help           Display this help message and exit
#
# Examples:
#   ./list_routes.sh
#   ./list_routes.sh -C
#   ./list_routes.sh -C -u
#   ./list_routes.sh -j
#

set -euo pipefail

all_clusters=false
target_context=""
vanity_only=true
urls_only=false
json_output=false

show_help() {
  cat << 'EOF'
Usage: list_routes.sh [OPTIONS]

Discover and inventory OpenShift routes across accessible namespaces.
By default, filters out default cluster wildcard routes and unencrypted (None) routes
to focus on custom vanity domains for TLS monitoring.

Options:
  -C, --all-clusters   Query all distinct authenticated clusters in kubeconfig (e.g. Silver and Gold)
      --context <name> Target a specific kubeconfig context
  -a, --all            Include all routes (including cluster wildcard and unencrypted routes)
  -v, --vanity-only    Filter out cluster wildcard and unencrypted routes (default behavior)
  -u, --urls-only      Output only raw, unique URLs
  -j, --json           Output structured JSON array
  -h, --help           Display this help message and exit

Examples:
  # Display tabular vanity route inventory for current cluster
  ./list_routes.sh

  # Discover vanity routes across both Silver and Gold clusters
  ./list_routes.sh -C

  # Extract combined unique vanity URLs across all clusters for certificate monitoring
  ./list_routes.sh -C -u > all-vanity-urls.txt

  # Output routes across all clusters as structured JSON
  ./list_routes.sh -C -j | jq .

  # Remote execution across all clusters
  curl -fsSL https://raw.githubusercontent.com/bcgov/devops-scripts/main/oc/list_routes.sh | bash -s -- -C -u
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    -C|--all-clusters)
      all_clusters=true
      shift
      ;;
    --context)
      if [[ $# -lt 2 ]]; then
        echo "Error: --context requires an argument." >&2
        exit 1
      fi
      target_context="$2"
      shift 2
      ;;
    -a|--all)
      vanity_only=false
      shift
      ;;
    -v|--vanity-only)
      vanity_only=true
      shift
      ;;
    -u|--urls-only)
      urls_only=true
      shift
      ;;
    -j|--json)
      json_output=true
      shift
      ;;
    -[!-]* ) # grouped short flags (e.g. -Cu, -Ca, -Cj)
      for (( i=1; i<${#1}; i++ )); do
        opt="${1:$i:1}"
        case "$opt" in
          h) show_help; exit 0 ;;
          C) all_clusters=true ;;
          a) vanity_only=false ;;
          v) vanity_only=true ;;
          u) urls_only=true ;;
          j) json_output=true ;;
          *) echo "Error: Unknown option: -$opt" >&2; exit 1 ;;
        esac
      done
      shift
      ;;
    *)
      echo "Error: Unknown argument: $1" >&2
      show_help >&2
      exit 1
      ;;
  esac
done

if [[ "$urls_only" == true && "$json_output" == true ]]; then
  echo "Error: --urls-only (-u) and --json (-j) cannot be used together." >&2
  exit 1
fi

# Fail-fast preconditions
if ! command -v oc >/dev/null 2>&1; then
  echo "Error: 'oc' CLI is not installed or not in PATH." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: 'jq' is not installed or not in PATH." >&2
  exit 1
fi

# Regex pattern matching default cluster wildcard domains to exclude when vanity_only is enabled
CLUSTER_DOMAIN_PATTERN="${CLUSTER_DOMAIN_PATTERN:-(\.apps\..+\.gov\.bc\.ca|\.apps\..+\.openshiftapps\.com|\.devops\.bcgov|\.router\.default\.svc\.cluster\.local|\.svc\.cluster\.local|\.cluster\.local)$}"

derive_cluster_alias() {
  local srv="$1"
  srv="${srv#http://}"
  srv="${srv#https://}"
  srv="${srv%%:[0-9]*}"
  if [[ "$srv" =~ devops\.gov\.bc\.ca$ ]]; then
    srv="${srv#api.}"
    srv="${srv%.devops.gov.bc.ca}"
  fi
  echo "${srv:-default}"
}

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
    echo "Error: No cluster contexts found in kubeconfig." >&2
    exit 1
  fi

  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    TARGET_CLUSTERS+=("$item")
  done < <(echo "$distinct_clusters" | jq -c '.[]')
else
  # Single cluster mode
  if [[ -n "$target_context" ]]; then
    ctx="$target_context"
    if ! oc --context "$ctx" whoami >/dev/null 2>&1; then
      echo "Error: No active OpenShift session detected for context '$ctx'. Please log in using 'oc login'." >&2
      exit 1
    fi
  else
    if ! oc whoami >/dev/null 2>&1; then
      echo "Error: No active OpenShift session detected. Please log in using 'oc login'." >&2
      exit 1
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

declare -a ALL_PARSED_CHUNKS=()
clusters_succeeded=0

for item in "${TARGET_CLUSTERS[@]}"; do
  c_ctx=$(echo "$item" | jq -r '.context // ""')
  c_label=$(echo "$item" | jq -r '.cluster // "default"')

  c_oc=(oc)
  if [[ -n "$c_ctx" ]]; then
    c_oc+=(--context "$c_ctx")
  fi

  # In multi-cluster mode, gracefully skip unauthenticated or unreachable clusters
  if ! "${c_oc[@]}" whoami >/dev/null 2>&1; then
    if [[ "$all_clusters" == true ]]; then
      echo "Warning: Skipping cluster '$c_label' (context: ${c_ctx:-default}): no active session or unreachable." >&2
      continue
    else
      echo "Error: No active OpenShift session detected. Please log in using 'oc login'." >&2
      exit 1
    fi
  fi

  if ! projects=$("${c_oc[@]}" projects -q 2>/dev/null); then
    if [[ "$all_clusters" == true ]]; then
      echo "Warning: Skipping cluster '$c_label': failed to retrieve projects." >&2
      continue
    else
      echo "Error: Failed to retrieve accessible OpenShift projects." >&2
      exit 1
    fi
  fi

  clusters_succeeded=$((clusters_succeeded + 1))

  if [[ -z "${projects//[[:space:]]/}" ]]; then
    continue
  fi

  # Iterate over accessible namespaces in this cluster and collect routes
  raw_routes=$(
    while IFS= read -r ns; do
      [[ -z "$ns" ]] && continue
      "${c_oc[@]}" get routes -n "$ns" -o json 2>/dev/null || true
    done <<< "$projects"
  )

  if [[ -z "${raw_routes//[[:space:]]/}" ]]; then
    continue
  fi

  cluster_parsed=$(
    printf '%s' "$raw_routes" | jq -s \
      --arg cluster "$c_label" \
      --argjson vanity_only "$vanity_only" \
      --arg cluster_pattern "$CLUSTER_DOMAIN_PATTERN" \
      '
      [ .[].items[]? ]
      | map(
          .spec.host as $host |
          (if .spec.path and .spec.path != "" and .spec.path != "/" then
             (if (.spec.path | startswith("/")) then .spec.path else "/" + .spec.path end)
           else "" end) as $path |
          (if .spec.tls and .spec.tls.termination then
             (.spec.tls.termination | ascii_downcase |
               if . == "edge" then "Edge"
               elif . == "passthrough" then "Passthrough"
               elif . == "reencrypt" then "Reencrypt"
               else ((.[:1] | ascii_upcase) + (.[1:]))
               end
             )
           else "None" end) as $term |
          (if $term == "None" then "http://" else "https://" end) as $proto |
          (if ($host // "") != "" then "\($proto)\($host)\($path)" else "" end) as $url |
          {
            cluster: $cluster,
            namespace: .metadata.namespace,
            name: .metadata.name,
            termination: $term,
            host: ($host // ""),
            url: $url
          }
        )
      | map(
          select(
            if $vanity_only then
              (.host != "") and (.termination != "None") and (.host | test($cluster_pattern) | not)
            else
              true
            end
          )
        )
      '
  )

  if [[ -n "$cluster_parsed" && "$cluster_parsed" != "[]" ]]; then
    ALL_PARSED_CHUNKS+=("$cluster_parsed")
  fi
done

if [[ "$clusters_succeeded" -eq 0 ]]; then
  echo "Error: No reachable or authenticated OpenShift clusters found." >&2
  exit 1
fi

if [[ ${#ALL_PARSED_CHUNKS[@]} -eq 0 ]]; then
  combined_json="[]"
else
  combined_json=$(
    printf '%s\n' "${ALL_PARSED_CHUNKS[@]}" | jq -s 'add // [] | sort_by(.cluster, .namespace, .name)'
  )
fi

# Output formatting
if [[ "$json_output" == true ]]; then
  echo "$combined_json"
elif [[ "$urls_only" == true ]]; then
  echo "$combined_json" | jq -r 'map(.url) | unique[] | select(. != "")'
else
  echo "$combined_json" | jq -r \
    --argjson all_clusters "$all_clusters" \
    '
    (if $all_clusters then
      ["CLUSTER", "NAMESPACE", "NAME", "TERMINATION", "URL"],
      (.[] | [.cluster, .namespace, .name, .termination, .url])
    else
      ["NAMESPACE", "NAME", "TERMINATION", "URL"],
      (.[] | [.namespace, .name, .termination, .url])
    end)
    | @tsv
    ' | column -t -s $'\t'
fi
