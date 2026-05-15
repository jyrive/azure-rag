#!/usr/bin/env bash

set -euo pipefail

# Copy data from a provisioned Cosmos Mongo account to the new serverless account.
# Usage:
#   scripts/migrate-cosmos-serverless.sh [environment] [oldAccountName] [newAccountName]
# Example:
#   scripts/migrate-cosmos-serverless.sh dev

ENVIRONMENT="${1:-dev}"
OLD_ACCOUNT_NAME="${2:-}"
NEW_ACCOUNT_NAME="${3:-}"
RG="rg-azure-rag-${ENVIRONMENT}"
DEPLOYMENT_NAME="azure-rag-${ENVIRONMENT}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: $cmd"
    exit 1
  fi
}

require_cmd az

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

echo "Environment: $ENVIRONMENT"
echo "Resource group: $RG"

auto_new_account() {
  az deployment group show \
    --resource-group "$RG" \
    --name "$DEPLOYMENT_NAME" \
    --query properties.outputs.cosmosAccountNameOut.value \
    -o tsv
}

COSMOS_DB_NAME="$(az deployment group show -g "$RG" -n "$DEPLOYMENT_NAME" --query properties.outputs.cosmosDatabaseNameOut.value -o tsv)"
COSMOS_COL_NAME="$(az deployment group show -g "$RG" -n "$DEPLOYMENT_NAME" --query properties.outputs.cosmosCollectionNameOut.value -o tsv)"

if [[ -z "$NEW_ACCOUNT_NAME" ]]; then
  NEW_ACCOUNT_NAME="$(auto_new_account)"
fi

if [[ -z "$NEW_ACCOUNT_NAME" || "$NEW_ACCOUNT_NAME" == "null" ]]; then
  echo "ERROR: Could not resolve target (serverless) Cosmos account name from deployment outputs."
  exit 1
fi

if [[ -z "$OLD_ACCOUNT_NAME" ]]; then
  CANDIDATES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && CANDIDATES+=("$line")
  done < <(az cosmosdb list -g "$RG" --query "[?kind=='MongoDB' && name!='${NEW_ACCOUNT_NAME}'].name" -o tsv)

  if [[ ${#CANDIDATES[@]} -eq 1 ]]; then
    OLD_ACCOUNT_NAME="${CANDIDATES[0]}"
  else
    echo "ERROR: Could not auto-select source Cosmos account."
    echo "Provide it explicitly as the second argument."
    echo "Mongo account candidates in $RG:"
    az cosmosdb list -g "$RG" --query "[?kind=='MongoDB'].name" -o tsv
    exit 1
  fi
fi

if [[ "$OLD_ACCOUNT_NAME" == "$NEW_ACCOUNT_NAME" ]]; then
  echo "ERROR: Source and target Cosmos accounts are the same: $OLD_ACCOUNT_NAME"
  exit 1
fi

echo "Source account: $OLD_ACCOUNT_NAME"
echo "Target account: $NEW_ACCOUNT_NAME"
echo "Database: $COSMOS_DB_NAME"
echo "Collection: $COSMOS_COL_NAME"

OLD_CONN_STR="$(az cosmosdb keys list -g "$RG" -n "$OLD_ACCOUNT_NAME" --type connection-strings --query 'connectionStrings[0].connectionString' -o tsv)"
NEW_CONN_STR="$(az cosmosdb keys list -g "$RG" -n "$NEW_ACCOUNT_NAME" --type connection-strings --query 'connectionStrings[0].connectionString' -o tsv)"

if [[ -z "$OLD_CONN_STR" || "$OLD_CONN_STR" == "null" ]]; then
  echo "ERROR: Could not fetch source connection string."
  exit 1
fi

if [[ -z "$NEW_CONN_STR" || "$NEW_CONN_STR" == "null" ]]; then
  echo "ERROR: Could not fetch target connection string."
  exit 1
fi

OLD_CONN_STR="$OLD_CONN_STR" \
NEW_CONN_STR="$NEW_CONN_STR" \
COSMOS_DB_NAME="$COSMOS_DB_NAME" \
COSMOS_COL_NAME="$COSMOS_COL_NAME" \
"$PYTHON_BIN" - <<'PY'
import os
import sys
from pymongo import MongoClient, UpdateOne

src_conn = os.environ['OLD_CONN_STR']
dst_conn = os.environ['NEW_CONN_STR']
db_name = os.environ['COSMOS_DB_NAME']
col_name = os.environ['COSMOS_COL_NAME']

src_client = MongoClient(src_conn, serverSelectionTimeoutMS=30000)
dst_client = MongoClient(dst_conn, serverSelectionTimeoutMS=30000)

src_col = src_client[db_name][col_name]
dst_col = dst_client[db_name][col_name]

batch = []
read_count = 0
written_count = 0

for doc in src_col.find({}, no_cursor_timeout=True).batch_size(500):
    if '_id' not in doc:
        continue
    batch.append(UpdateOne({'_id': doc['_id']}, {'$set': doc}, upsert=True))
    read_count += 1

    if len(batch) >= 500:
        result = dst_col.bulk_write(batch, ordered=False)
        written_count += result.upserted_count + result.modified_count
        batch.clear()

if batch:
    result = dst_col.bulk_write(batch, ordered=False)
    written_count += result.upserted_count + result.modified_count

src_total = src_col.estimated_document_count()
dst_total = dst_col.estimated_document_count()

print(f"Read docs: {read_count}")
print(f"Writes (upsert+modify): {written_count}")
print(f"Source estimated count: {src_total}")
print(f"Target estimated count: {dst_total}")

if dst_total < src_total:
    print("ERROR: Target count is lower than source count after migration", file=sys.stderr)
    sys.exit(1)

print("Migration copy complete.")
PY

echo "Done."
echo "Next: run scripts/check-deploy.sh $ENVIRONMENT to validate backend reads via Key Vault secret."