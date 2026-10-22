#!/bin/bash
#
# OpenShift Route and Vanity URL Discovery
# Usage:
#   ./list_routes.sh [OPTIONS]
#
# Discovers and inventories OpenShift routes across all namespaces accessible
# to the active oc session.
#
# Options:
#   -v, --vanity-only    Filter out default cluster wildcard routes
#                        (e.g. *.apps.*.gov.bc.ca, *.router.default.svc.cluster.local)
#   -u, --urls-only      Output only raw, unique hostnames/URLs
#   -j, --json           Output structured JSON array
#   -h, --help           Display this help message and exit
#
# Examples:
#   ./list_routes.sh
#   ./list_routes.sh -v
#   ./list_routes.sh -v -u
#   ./list_routes.sh -j
#

set -euo pipefail

vanity_only=false
urls_only=false
json_output=false

show_help() {
  cat << 'EOF'
Usage: list_routes.sh [OPTIONS]

Discover and inventory OpenShift routes across all accessible namespaces.

Options:
  -v, --vanity-only    Filter out default cluster wildcard routes
                       (e.g. *.apps.*.gov.bc.ca, *.router.default.svc.cluster.local)
  -u, --urls-only      Output only raw, unique hostnames/URLs
  -j, --json           Output structured JSON array
  -h, --help           Display this help message and exit

Examples:
  # Display tabular route inventory across all accessible namespaces
  ./list_routes.sh

  # Inventory only vanity/custom domain routes
  ./list_routes.sh -v

  # Extract unique vanity URLs for certificate monitoring (e.g. Prometheus rules)
  ./list_routes.sh -v -u > vanity-urls.txt

  # Output all routes as structured JSON
  ./list_routes.sh -j | jq .
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
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
    -[!-]* ) # grouped short flags (e.g. -vu, -uv, -vj)
      for (( i=1; i<${#1}; i++ )); do
        opt="${1:$i:1}"
        case "$opt" in
          h) show_help; exit 0 ;;
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

if ! oc whoami >/dev/null 2>&1; then
  echo "Error: No active OpenShift session detected. Please log in using 'oc login'." >&2
  exit 1
fi

# Regex pattern matching default cluster wildcard domains to exclude when --vanity-only is enabled
CLUSTER_DOMAIN_PATTERN="${CLUSTER_DOMAIN_PATTERN:-(\.apps\..+\.gov\.bc\.ca|\.apps\..+\.openshiftapps\.com|\.router\.default\.svc\.cluster\.local|\.svc\.cluster\.local|\.cluster\.local)$}"

# Query accessible namespaces
if ! projects=$(oc projects -q 2>&1); then
  echo "Error: Failed to retrieve accessible OpenShift projects:" >&2
  echo "$projects" >&2
  exit 1
fi

if [[ -z "${projects//[[:space:]]/}" ]]; then
  if [[ "$json_output" == true ]]; then
    echo "[]"
  elif [[ "$urls_only" == true ]]; then
    exit 0
  else
    printf '%s\t%s\t%s\t%s\t%s\n' "NAMESPACE" "NAME" "TERMINATION" "HOST" "URL" | column -t -s $'\t'
  fi
  exit 0
fi

# Iterate over accessible namespaces and collect routes
raw_routes=$(
  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    oc get routes -n "$ns" -o json 2>/dev/null || true
  done <<< "$projects"
)

if [[ -z "${raw_routes//[[:space:]]/}" ]]; then
  if [[ "$json_output" == true ]]; then
    echo "[]"
  elif [[ "$urls_only" == true ]]; then
    exit 0
  else
    printf '%s\t%s\t%s\t%s\t%s\n' "NAMESPACE" "NAME" "TERMINATION" "HOST" "URL" | column -t -s $'\t'
  fi
  exit 0
fi

# Transform and filter routes
parsed_json=$(
  printf '%s' "$raw_routes" | jq -s \
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
            (.host != "") and (.host | test($cluster_pattern) | not)
          else
            true
          end
        )
      )
    | sort_by(.namespace, .name)
    '
)

# Output formatting
if [[ "$json_output" == true ]]; then
  echo "$parsed_json"
elif [[ "$urls_only" == true ]]; then
  echo "$parsed_json" | jq -r 'map(.url) | unique[] | select(. != "")'
else
  echo "$parsed_json" | jq -r '
    ["NAMESPACE", "NAME", "TERMINATION", "HOST", "URL"],
    (.[] | [.namespace, .name, .termination, .host, .url])
    | @tsv
  ' | column -t -s $'\t'
fi
