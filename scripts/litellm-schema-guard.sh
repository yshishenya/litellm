#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/projects/litellm}"
DB_CONTAINER="${DB_CONTAINER:-litellm_db}"
DB_NAME="${DB_NAME:-litellm}"
DB_USER="${DB_USER:-llmproxy}"

cd "$PROJECT_DIR"

if ! docker ps --format "{{.Names}}" | grep -q '^litellm-litellm-1$'; then
  echo "[guard] litellm container is not running"
  exit 2
fi

required_tool=(input_policy output_policy)
required_guard=(status reviewed_at submitted_at)
missing=0

for col in "${required_tool[@]}"; do
  if ! docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -Atc "select 1 from information_schema.columns where table_schema='public' and table_name='LiteLLM_ToolTable' and column_name='${col}'" | grep -q 1; then
    echo "[guard] MISSING: LiteLLM_ToolTable.${col}"
    missing=1
  fi
done

for col in "${required_guard[@]}"; do
  if ! docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -Atc "select 1 from information_schema.columns where table_schema='public' and table_name='LiteLLM_GuardrailsTable' and column_name='${col}'" | grep -q 1; then
    echo "[guard] MISSING: LiteLLM_GuardrailsTable.${col}"
    missing=1
  fi
done

if docker logs --since 3m litellm-litellm-1 2>&1 | egrep -qi "column .* does not exist|DataError|_init_guardrails_in_db|_init_tool_policy_in_db"; then
  echo "[guard] Runtime log contains schema-related errors"
  missing=1
fi

if [[ "$missing" -ne 0 ]]; then
  echo "[guard] FAIL"
  exit 1
fi

echo "[guard] OK"
