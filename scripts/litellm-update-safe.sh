#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/projects/litellm}"
SERVICE="${SERVICE:-litellm}"
BACKUP_SCRIPT="${BACKUP_SCRIPT:-$PROJECT_DIR/scripts/backup.sh}"
GUARD_SCRIPT="${GUARD_SCRIPT:-$PROJECT_DIR/scripts/litellm-schema-guard.sh}"

cd "$PROJECT_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
STATE_DIR="$PROJECT_DIR/.update-safe"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/state_${TS}.env"

log(){ echo "[update-safe] $*"; }

CURRENT_IMAGE="$(docker inspect litellm-litellm-1 --format '{{.Image}}' 2>/dev/null || true)"
CURRENT_ENV_DISABLE="$(docker inspect litellm-litellm-1 --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep '^DISABLE_SCHEMA_UPDATE=' || true)"

cat > "$STATE_FILE" <<EOF_STATE
TS=$TS
CURRENT_IMAGE=$CURRENT_IMAGE
CURRENT_ENV_DISABLE=$CURRENT_ENV_DISABLE
EOF_STATE

log "state snapshot: $STATE_FILE"

if [[ -x "$BACKUP_SCRIPT" ]]; then
  log "running backup"
  "$BACKUP_SCRIPT"
else
  log "backup script not found: $BACKUP_SCRIPT"
  exit 1
fi

if grep -q 'image: litellm:local' docker-compose.override.yml 2>/dev/null; then
  if ! grep -q 'DISABLE_SCHEMA_UPDATE: "true"' docker-compose.override.yml; then
    log "patching docker-compose.override.yml -> DISABLE_SCHEMA_UPDATE=true"
    cp docker-compose.override.yml "docker-compose.override.yml.bak_${TS}"
    cat > docker-compose.override.yml <<'YAML'
services:
  litellm:
    build:
      context: .
      dockerfile: docker/Dockerfile.dev
    image: litellm:local
    environment:
      DISABLE_SCHEMA_UPDATE: "true"
YAML
  fi
fi

log "recreate $SERVICE"
docker compose up -d "$SERVICE"

for i in {1..40}; do
  hs="$(docker inspect --format '{{.State.Health.Status}}' litellm-litellm-1 2>/dev/null || echo starting)"
  log "health=$hs"
  [[ "$hs" == "healthy" ]] && break
  sleep 6
done

log "prisma db push"
docker exec litellm-litellm-1 sh -lc "cd /app && prisma db push --schema /app/schema.prisma --accept-data-loss --skip-generate"

if ! "$GUARD_SCRIPT"; then
  log "guard failed, attempting rollback"
  if [[ -n "$CURRENT_IMAGE" ]]; then
    docker tag "$CURRENT_IMAGE" litellm:rollback-current || true
    cat > docker-compose.override.yml <<'YAML'
services:
  litellm:
    image: litellm:rollback-current
    environment:
      DISABLE_SCHEMA_UPDATE: "true"
YAML
    docker compose up -d "$SERVICE" || true
  fi
  log "rollback attempted; manual check required"
  exit 1
fi

log "SUCCESS"
