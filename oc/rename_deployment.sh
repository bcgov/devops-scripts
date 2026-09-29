#!/bin/bash
#
# Usage:
#   ./rename_deployment.sh <source-deployment-name> [target-deployment-name]
#
# If [target-deployment-name] is not provided, defaults to <source-deployment-name>-prev
#
# This script renames an OpenShift deployment by exporting its manifest, updating the name,
# deleting the old deployment, and applying the new one.

# Strict mode: exit on error, unset vars, or failed pipes
set -euo pipefail

# Show usage from header if not enough arguments
if [[ $# -lt 1 ]]; then
  grep -v '^#!' "${0}" | awk '/^#/ { sub(/^# ?/, ""); print; next } NF==0 { exit }'
  exit 1
fi

SOURCE_DEPLOYMENT="${1}"
TARGET_DEPLOYMENT="${2:-${SOURCE_DEPLOYMENT}-prev}"
ORIGINAL_MANIFEST=$(mktemp "/tmp/${SOURCE_DEPLOYMENT}_orig_$(date +%Y%m%d)_XXXXXX.json")
MANIFEST=$(mktemp "/tmp/${SOURCE_DEPLOYMENT}_$(date +%Y%m%d)_XXXXXX.json")
SUCCESS=false
DELETED_SOURCE=false
APPLIED_TARGET=false

cleanup() {
  local exit_code=$?
  set +e
  rm -f "${MANIFEST}"
  if [[ "${SUCCESS}" == "true" ]]; then
    rm -f "${ORIGINAL_MANIFEST}"
  else
    if [[ -f "${ORIGINAL_MANIFEST}" && -s "${ORIGINAL_MANIFEST}" ]]; then
      echo "Original deployment manifest preserved at: ${ORIGINAL_MANIFEST}" >&2
      if [[ "${DELETED_SOURCE}" == "true" ]] && ! oc get deployment "${SOURCE_DEPLOYMENT}" &>/dev/null; then
        if [[ "${APPLIED_TARGET}" == "true" ]]; then
          echo "Removing failed target deployment '${TARGET_DEPLOYMENT}'..." >&2
          oc delete deployment "${TARGET_DEPLOYMENT}" --ignore-not-found=true &>/dev/null || true
        fi
        echo "Attempting to restore original deployment '${SOURCE_DEPLOYMENT}'..." >&2
        if oc apply -f "${ORIGINAL_MANIFEST}" &>/dev/null; then
          echo "Successfully restored original deployment '${SOURCE_DEPLOYMENT}'." >&2
        else
          echo "Failed to restore original deployment. Restore manually using: oc apply -f '${ORIGINAL_MANIFEST}'" >&2
        fi
      fi
    else
      rm -f "${ORIGINAL_MANIFEST}"
    fi
  fi
  exit "${exit_code}"
}
trap cleanup EXIT

# Fail fast if the new deployment already exists
if oc get deployment "${TARGET_DEPLOYMENT}" &>/dev/null; then
  echo "Deployment '${TARGET_DEPLOYMENT}' already exists. Aborting to avoid overwrite."
  exit 2
fi

# Check if the old deployment exists
if ! oc get deployment "${SOURCE_DEPLOYMENT}" &>/dev/null; then
  echo "Deployment '${SOURCE_DEPLOYMENT}' not found."
  exit 0
fi

# Export and sanitize original deployment manifest as backup
oc get deployment "${SOURCE_DEPLOYMENT}" -o json \
  | jq 'del(
      .metadata.uid,
      .metadata.resourceVersion,
      .metadata.selfLink,
      .metadata.creationTimestamp,
      .metadata.generation,
      .metadata.managedFields,
      .status
    )' \
  > "${ORIGINAL_MANIFEST}"

# Update deployment manifest for target
jq '.metadata.name = "'"${TARGET_DEPLOYMENT}"'"
  | .spec.selector.matchLabels.deployment = "'"${TARGET_DEPLOYMENT}"'"
  | .spec.template.metadata.labels.deployment = "'"${TARGET_DEPLOYMENT}"'"' \
  "${ORIGINAL_MANIFEST}" > "${MANIFEST}"

# Validate target deployment manifest before deleting source
echo "Validating target deployment manifest..."
if ! oc apply --dry-run=server -f "${MANIFEST}"; then
  echo "Error: Target deployment manifest validation failed." >&2
  exit 4
fi

# Delete the old deployment and apply the new one
DELETED_SOURCE=true
oc delete deployment "${SOURCE_DEPLOYMENT}"
oc apply -f "${MANIFEST}"
APPLIED_TARGET=true

# Wait for the new deployment to become available
echo "Waiting for deployment '${TARGET_DEPLOYMENT}' to become available..."
if ! oc rollout status deployment/"${TARGET_DEPLOYMENT}" --timeout=120s; then
  echo "Error: Deployment '${TARGET_DEPLOYMENT}' did not become available in time."
  exit 3
fi

SUCCESS=true

# Show matching deployments for confirmation
echo -e "\nMatching deployments after renaming:"
oc get deployments -o name | grep -iE "^deployment\.apps/(${SOURCE_DEPLOYMENT}|${TARGET_DEPLOYMENT})$"
