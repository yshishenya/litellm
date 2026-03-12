# LiteLLM Safe Update Plan (anti-schema-drift)

## Why incidents happened
Root cause was schema drift loop:
- runtime expected new columns (input_policy, output_policy, guardrails.status)
- litellm_proxy_extras auto-migration generated/applied baseline_diff and reverted schema back to old (call_policy)
- service stayed up but produced cyclic DataError.

## Guardrails introduced
1. DISABLE_SCHEMA_UPDATE=true in docker-compose.override.yml for litellm:local.
2. scripts/litellm-schema-guard.sh — verifies required columns + no recent schema errors in logs.
3. scripts/litellm-update-safe.sh — backup -> recreate -> db push -> guard -> rollback on fail.

## Scenarios

### A) Routine local rebuild (litellm:local)
Use:
```bash
cd /opt/projects/litellm
./scripts/litellm-update-safe.sh
```

### B) Switch to upstream image (ghcr.io/berriai/litellm:<tag>)
1. edit compose image/tag
2. run ./scripts/litellm-update-safe.sh
3. run smoke checks (health, chat completion, guardrails/tool policy endpoints)

### C) Emergency rollback
litellm-update-safe.sh already attempts rollback to saved image ID as litellm:rollback-current.
If needed manually:
```bash
cd /opt/projects/litellm
docker compose logs --tail=200 litellm
./scripts/litellm-schema-guard.sh
```

## Pre-update checklist
- backup succeeded
- DB healthy
- ./scripts/litellm-schema-guard.sh returns OK before update
- maintenance window announced

## Post-update checklist
- container healthy
- schema guard OK
- no DataError/column does not exist in last 5-10 min logs
- core API smoke test ok

