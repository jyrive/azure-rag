#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   scripts/check-deploy.sh [environment]
# Example:
#   scripts/check-deploy.sh dev

ENVIRONMENT="${1:-dev}"
WORKFLOW_NAME="Deploy Azure RAG"
AZURE_RESOURCE_GROUP="rg-azure-rag-${ENVIRONMENT}"
DEPLOYMENT_NAME="azure-rag-${ENVIRONMENT}"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: $cmd"
    exit 1
  fi
}

require_cmd az
require_cmd curl
require_cmd jq

# 1) Resolve backend URL from deployment outputs.
BACKEND_FQDN="$(az deployment group show \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$DEPLOYMENT_NAME" \
  --query properties.outputs.backendAppFqdn.value \
  -o tsv)"

if [[ -z "$BACKEND_FQDN" || "$BACKEND_FQDN" == "null" ]]; then
  echo "ERROR: Could not resolve backend FQDN from deployment outputs."
  echo "Resource group: $AZURE_RESOURCE_GROUP"
  echo "Deployment:     $DEPLOYMENT_NAME"
  exit 1
fi

BACKEND_URL="https://${BACKEND_FQDN}"
HEALTH_URL="${BACKEND_URL}/health"
CONFIG_URL="${BACKEND_URL}/api/config"

echo "Checking environment: $ENVIRONMENT"
echo "Backend URL: $BACKEND_URL"

# 2) Health check.
printf '\n[1/3] Health check\n'
HEALTH_BODY="$(curl --fail --silent --show-error \
  --retry 8 \
  --retry-all-errors \
  --retry-delay 5 \
  --max-time 20 \
  "$HEALTH_URL")"

echo "$HEALTH_BODY" | jq '.' >/dev/null 2>&1 || {
  echo "ERROR: /health did not return valid JSON"
  echo "$HEALTH_BODY"
  exit 1
}

HEALTH_STATUS="$(echo "$HEALTH_BODY" | jq -r '.status // empty')"
if [[ "$HEALTH_STATUS" != "ok" ]]; then
  echo "ERROR: /health status was not ok"
  echo "$HEALTH_BODY" | jq '.'
  exit 1
fi
echo "PASS: /health returned status=ok"

# 3) Config checks.
printf '\n[2/3] Config check\n'
CONFIG_BODY="$(curl --fail --silent --show-error \
  --retry 5 \
  --retry-all-errors \
  --retry-delay 3 \
  --max-time 20 \
  "$CONFIG_URL")"

echo "$CONFIG_BODY" | jq '.' >/dev/null 2>&1 || {
  echo "ERROR: /api/config did not return valid JSON"
  echo "$CONFIG_BODY"
  exit 1
}

KEYVAULT_CONFIGURED="$(echo "$CONFIG_BODY" | jq -r '.keyVaultConfigured')"
HAS_COSMOS_CONNECTION="$(echo "$CONFIG_BODY" | jq -r '.hasCosmosConnection')"
SECRET_LOAD_ERRORS_LEN="$(echo "$CONFIG_BODY" | jq -r '(.secretLoadErrors // []) | length')"

if [[ "$KEYVAULT_CONFIGURED" != "true" ]]; then
  echo "ERROR: keyVaultConfigured is not true"
  echo "$CONFIG_BODY" | jq '.'
  exit 1
fi

if [[ "$HAS_COSMOS_CONNECTION" != "true" ]]; then
  echo "ERROR: hasCosmosConnection is not true"
  echo "$CONFIG_BODY" | jq '.'
  exit 1
fi

if [[ "$SECRET_LOAD_ERRORS_LEN" != "0" ]]; then
  echo "ERROR: secretLoadErrors is not empty"
  echo "$CONFIG_BODY" | jq '.'
  exit 1
fi

echo "PASS: Key Vault and Cosmos config checks passed"

# 4) Latest workflow status (optional, if gh is available).
printf '\n[3/3] Workflow status check\n'
if command -v gh >/dev/null 2>&1; then
  RUN_JSON="$(gh run list --workflow "$WORKFLOW_NAME" --limit 1 --json databaseId,status,conclusion,url,displayTitle,createdAt)"
  RUN_ID="$(echo "$RUN_JSON" | jq -r '.[0].databaseId // empty')"
  RUN_STATUS="$(echo "$RUN_JSON" | jq -r '.[0].status // empty')"
  RUN_CONCLUSION="$(echo "$RUN_JSON" | jq -r '.[0].conclusion // empty')"
  RUN_URL="$(echo "$RUN_JSON" | jq -r '.[0].url // empty')"

  if [[ -z "$RUN_ID" ]]; then
    echo "WARN: Could not read latest workflow run for $WORKFLOW_NAME"
  else
    echo "Latest run: $RUN_ID"
    echo "Status: $RUN_STATUS"
    echo "Conclusion: ${RUN_CONCLUSION:-n/a}"
    echo "URL: $RUN_URL"

    if [[ "$RUN_STATUS" == "completed" && "$RUN_CONCLUSION" != "success" ]]; then
      echo "ERROR: Latest workflow run is completed but not successful"
      exit 1
    fi
  fi
else
  echo "WARN: gh CLI not found, skipping workflow status check"
fi

printf '\nAll checks passed for environment: %s\n' "$ENVIRONMENT"