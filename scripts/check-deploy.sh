#!/usr/bin/env bash

# If invoked as `sh check-deploy.sh`, re-exec under bash for consistent behavior.
if [[ -z "${BASH_VERSION:-}" ]]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

# Usage:
#   scripts/check-deploy.sh [environment]
# Example:
#   scripts/check-deploy.sh dev

ENVIRONMENT="${1:-dev}"
WORKFLOW_NAME="Deploy Azure RAG"
AZURE_RESOURCE_GROUP="rg-azure-rag-${ENVIRONMENT}"
DEPLOYMENT_NAME="azure-rag-${ENVIRONMENT}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKIP_WORKFLOW_STATUS="${SKIP_WORKFLOW_STATUS:-0}"

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

resolve_python() {
  if [[ -x "$REPO_ROOT/.venv/bin/python" ]]; then
    echo "$REPO_ROOT/.venv/bin/python"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi

  echo "ERROR: Python runtime not found. Expected $REPO_ROOT/.venv/bin/python or python3 on PATH."
  exit 1
}

PYTHON_BIN="$(resolve_python)"

"$PYTHON_BIN" -c 'import pymongo' >/dev/null 2>&1 || {
  echo "ERROR: pymongo is not available in $PYTHON_BIN"
  exit 1
}

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

BACKEND_PROTECTED=0

# 2) Health check.
printf '\n[1/4] Health check\n'
HEALTH_HTTP_CODE="$(curl --silent --show-error \
  --output /tmp/backend-health.txt \
  --write-out "%{http_code}" \
  --retry 8 \
  --retry-all-errors \
  --retry-delay 5 \
  --max-time 20 \
  "$HEALTH_URL")"

if [[ "$HEALTH_HTTP_CODE" == "200" ]]; then
  HEALTH_BODY="$(cat /tmp/backend-health.txt)"
  printf '%s' "$HEALTH_BODY" | jq '.' >/dev/null 2>&1 || {
    echo "ERROR: /health did not return valid JSON"
    echo "$HEALTH_BODY"
    exit 1
  }

  HEALTH_STATUS="$(printf '%s' "$HEALTH_BODY" | jq -r '.status // empty')"
  if [[ "$HEALTH_STATUS" != "ok" ]]; then
    echo "ERROR: /health status was not ok"
    printf '%s' "$HEALTH_BODY" | jq '.'
    exit 1
  fi
  echo "PASS: /health returned status=ok"
elif [[ "$HEALTH_HTTP_CODE" == "401" ]]; then
  BACKEND_PROTECTED=1
  echo "PASS: /health is reachable but protected (HTTP 401)."
else
  echo "ERROR: Unexpected /health status code: $HEALTH_HTTP_CODE"
  if [[ -s /tmp/backend-health.txt ]]; then
    cat /tmp/backend-health.txt
  fi
  exit 1
fi

# 3) Config checks.
printf '\n[2/4] Config check\n'
if [[ "$BACKEND_PROTECTED" == "1" ]]; then
  echo "SKIP: /api/config requires auth in protected backend mode"
else
  CONFIG_BODY="$(curl --fail --silent --show-error \
    --retry 5 \
    --retry-all-errors \
    --retry-delay 3 \
    --max-time 20 \
    "$CONFIG_URL")"

  printf '%s' "$CONFIG_BODY" | jq '.' >/dev/null 2>&1 || {
    echo "ERROR: /api/config did not return valid JSON"
    echo "$CONFIG_BODY"
    exit 1
  }

  KEYVAULT_CONFIGURED="$(printf '%s' "$CONFIG_BODY" | jq -r '.keyVaultConfigured')"
  HAS_COSMOS_CONNECTION="$(printf '%s' "$CONFIG_BODY" | jq -r '.hasCosmosConnection')"
  COSMOS_SECRET_ERROR_COUNT="$(printf '%s' "$CONFIG_BODY" | jq -r '(.secretLoadErrors // []) | map(select(startswith("cosmos-connection-string:"))) | length')"
  OPTIONAL_SECRET_ERROR_COUNT="$(printf '%s' "$CONFIG_BODY" | jq -r '(.secretLoadErrors // []) | map(select((startswith("cosmos-connection-string:") | not))) | length')"

  if [[ "$KEYVAULT_CONFIGURED" != "true" ]]; then
    echo "ERROR: keyVaultConfigured is not true"
    printf '%s' "$CONFIG_BODY" | jq '.'
    exit 1
  fi

  if [[ "$HAS_COSMOS_CONNECTION" != "true" ]]; then
    echo "ERROR: hasCosmosConnection is not true"
    printf '%s' "$CONFIG_BODY" | jq '.'
    exit 1
  fi

  if [[ "$COSMOS_SECRET_ERROR_COUNT" != "0" ]]; then
    echo "ERROR: Cosmos Key Vault secret still has load errors"
    printf '%s' "$CONFIG_BODY" | jq '.'
    exit 1
  fi

  if [[ "$OPTIONAL_SECRET_ERROR_COUNT" != "0" ]]; then
    echo "WARN: Optional secrets are missing (OpenAI/Event Grid), but core Cosmos check passed"
  fi

  echo "PASS: Key Vault and Cosmos config checks passed"
fi

# 4) Cosmos DB round-trip validation.
printf '\n[3/4] Cosmos round-trip check\n'
if [[ "$BACKEND_PROTECTED" == "1" ]]; then
  echo "SKIP: Direct backend is protected; skipping unauthenticated config/cosmos deep checks"
else
  COSMOS_ACCOUNT_NAME="$(az deployment group show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$DEPLOYMENT_NAME" \
    --query properties.outputs.cosmosAccountNameOut.value \
    -o tsv)"

  COSMOS_DATABASE_NAME="$(az deployment group show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$DEPLOYMENT_NAME" \
    --query properties.outputs.cosmosDatabaseNameOut.value \
    -o tsv)"

  COSMOS_COLLECTION_NAME="$(az deployment group show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$DEPLOYMENT_NAME" \
    --query properties.outputs.cosmosCollectionNameOut.value \
    -o tsv)"

  COSMOS_CONNECTION_STRING="$(az cosmosdb keys list \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name "$COSMOS_ACCOUNT_NAME" \
    --type connection-strings \
    --query 'connectionStrings[0].connectionString' \
    -o tsv)"

  if [[ -z "$COSMOS_ACCOUNT_NAME" || "$COSMOS_ACCOUNT_NAME" == "null" ]]; then
    echo "ERROR: Could not resolve Cosmos account name from deployment outputs."
    exit 1
  fi

  if [[ -z "$COSMOS_DATABASE_NAME" || "$COSMOS_DATABASE_NAME" == "null" ]]; then
    echo "ERROR: Could not resolve Cosmos database name from deployment outputs."
    exit 1
  fi

  if [[ -z "$COSMOS_COLLECTION_NAME" || "$COSMOS_COLLECTION_NAME" == "null" ]]; then
    echo "ERROR: Could not resolve Cosmos collection name from deployment outputs."
    exit 1
  fi

  if [[ -z "$COSMOS_CONNECTION_STRING" || "$COSMOS_CONNECTION_STRING" == "null" ]]; then
    echo "ERROR: Could not resolve Cosmos connection string from account keys."
    exit 1
  fi

  COSMOS_RESULT="$(COSMOS_CONN_STR="$COSMOS_CONNECTION_STRING" \
    COSMOS_DB_NAME="$COSMOS_DATABASE_NAME" \
    COSMOS_COL_NAME="$COSMOS_COLLECTION_NAME" \
    "$PYTHON_BIN" - <<'PY'
import os
from datetime import datetime, timezone
from uuid import uuid4

from pymongo import MongoClient

connection_string = os.environ["COSMOS_CONN_STR"]
database_name = os.environ["COSMOS_DB_NAME"]
collection_name = os.environ["COSMOS_COL_NAME"]

document_id = f"tier2-validate-{uuid4()}"
payload = {
    "_id": document_id,
    "text": "tier2 validation document",
    "metadata": {"source": "check-deploy", "company_id": "validation"},
    "createdAt": datetime.now(timezone.utc).isoformat(),
}

client = MongoClient(connection_string, serverSelectionTimeoutMS=30000)
collection = client[database_name][collection_name]

insert_result = collection.insert_one(payload)
found = collection.find_one({"_id": document_id}, {"_id": 1})
delete_result = collection.delete_one({"_id": document_id})

print(f"INSERTED_ID={insert_result.inserted_id}")
print(f"READ_BACK={'yes' if found else 'no'}")
print(f"DELETED_COUNT={delete_result.deleted_count}")
print(f"DB={database_name}")
print(f"COLLECTION={collection_name}")
PY
  )"

  READ_BACK="$(printf '%s\n' "$COSMOS_RESULT" | awk -F= '/^READ_BACK=/{print $2}')"
  DELETED_COUNT="$(printf '%s\n' "$COSMOS_RESULT" | awk -F= '/^DELETED_COUNT=/{print $2}')"

  if [[ "$READ_BACK" != "yes" ]]; then
    echo "ERROR: Cosmos round-trip read-back failed"
    printf '%s\n' "$COSMOS_RESULT"
    exit 1
  fi

  if [[ "$DELETED_COUNT" != "1" ]]; then
    echo "ERROR: Cosmos round-trip cleanup failed"
    printf '%s\n' "$COSMOS_RESULT"
    exit 1
  fi

  echo "PASS: Cosmos round-trip succeeded"
  printf '%s\n' "$COSMOS_RESULT"
fi

# 5) Latest workflow status (optional, if gh is available).
printf '\n[4/4] Workflow status check\n'
if [[ "$SKIP_WORKFLOW_STATUS" == "1" ]]; then
  echo "SKIP: Workflow status check disabled"
elif command -v gh >/dev/null 2>&1; then
  RUN_JSON="$(gh run list --workflow "$WORKFLOW_NAME" --limit 1 --json databaseId,status,conclusion,url,displayTitle,createdAt)"
  RUN_ID="$(printf '%s' "$RUN_JSON" | jq -r '.[0].databaseId // empty')"
  RUN_STATUS="$(printf '%s' "$RUN_JSON" | jq -r '.[0].status // empty')"
  RUN_CONCLUSION="$(printf '%s' "$RUN_JSON" | jq -r '.[0].conclusion // empty')"
  RUN_URL="$(printf '%s' "$RUN_JSON" | jq -r '.[0].url // empty')"

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