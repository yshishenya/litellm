#!/bin/bash
#
# LiteLLM Offsite Backup Sync Script
# Copies latest backups to remote server 135.181.215.121
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

COMMON_LIB="${SCRIPT_DIR}/lib/common.sh"
if [ -f "${COMMON_LIB}" ]; then
    source "${COMMON_LIB}"
else
    echo "ERROR: Missing ${COMMON_LIB}"
    exit 1
fi

# Configuration (override via environment or .env)
if [ -f "${PROJECT_DIR}/.env" ]; then
    export BACKUP_REMOTE_HOST=$(grep "^BACKUP_REMOTE_HOST" "${PROJECT_DIR}/.env" | cut -d'=' -f2- | sed 's/#.*//' | tr -d ' "')
    export BACKUP_REMOTE_USER=$(grep "^BACKUP_REMOTE_USER" "${PROJECT_DIR}/.env" | cut -d'=' -f2- | sed 's/#.*//' | tr -d ' "')
    export BACKUP_REMOTE_PATH=$(grep "^BACKUP_REMOTE_PATH" "${PROJECT_DIR}/.env" | cut -d'=' -f2- | sed 's/#.*//' | tr -d ' "')
    export BACKUP_REMOTE_PORT=$(grep "^BACKUP_REMOTE_PORT" "${PROJECT_DIR}/.env" | cut -d'=' -f2- | sed 's/#.*//' | tr -d ' "')
    export BACKUP_BASE_DIR=$(grep "^BACKUP_BASE_DIR" "${PROJECT_DIR}/.env" | cut -d'=' -f2- | sed 's/#.*//' | tr -d ' "')
    export BACKUP_RETENTION_DAYS=$(grep "^BACKUP_RETENTION_DAYS" "${PROJECT_DIR}/.env" | cut -d'=' -f2- | sed 's/#.*//' | tr -d ' "')
fi

BACKUP_SOURCE="${BACKUP_SOURCE:-${BACKUP_BASE_DIR:-/opt/backups/litellm}}"
REMOTE_HOST="${BACKUP_REMOTE_HOST:-}"
REMOTE_USER="${BACKUP_REMOTE_USER:-}"
REMOTE_PATH="${BACKUP_REMOTE_PATH:-}"
REMOTE_PORT="${BACKUP_REMOTE_PORT:-22}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

require_cmds ssh rsync du readlink || exit 1

if [ -z "${REMOTE_HOST}" ] || [ -z "${REMOTE_USER}" ] || [ -z "${REMOTE_PATH}" ]; then
    log_error "Missing remote config. Set BACKUP_REMOTE_HOST/BACKUP_REMOTE_USER/BACKUP_REMOTE_PATH in .env"
    exit 1
fi

if [ ! -d "$BACKUP_SOURCE" ]; then
    log_error "Backup source directory not found: $BACKUP_SOURCE"
    exit 1
fi

echo ""
log_info "╔════════════════════════════════════════════╗"
log_info "║   LiteLLM Offsite Backup Sync              ║"
log_info "║   Remote: ${REMOTE_HOST}               ║"
log_info "╚════════════════════════════════════════════╝"
echo ""

# Test SSH connection
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 -p ${REMOTE_PORT}"
log_info "Testing SSH connection to ${REMOTE_HOST}..."
if ! ssh ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}" "echo OK" &>/dev/null; then
    log_error "Cannot connect to ${REMOTE_HOST}"
    exit 1
fi
log_success "SSH connection OK"

# Sync latest backup
log_info "Syncing latest backup..."
LATEST_BACKUP=$(readlink -f "${BACKUP_SOURCE}/latest" 2>/dev/null || echo "")

if [ -z "$LATEST_BACKUP" ] || [ ! -d "$LATEST_BACKUP" ]; then
    log_error "No latest backup found"
    exit 1
fi

BACKUP_NAME=$(basename "$LATEST_BACKUP")
log_info "Latest backup: ${BACKUP_NAME}"

# Calculate size
BACKUP_SIZE=$(du -sh "$LATEST_BACKUP" | cut -f1)
log_info "Backup size: ${BACKUP_SIZE}"

# Rsync to remote server
log_info "Copying to ${REMOTE_HOST}:${REMOTE_PATH}/${BACKUP_NAME}..."
START_TIME=$(date +%s)

rsync -az --info=progress2 \
    --delete \
    -e "ssh ${SSH_OPTS}" \
    "${LATEST_BACKUP}/" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/${BACKUP_NAME}/" 2>&1 | \
    grep -v "sending incremental file list" || true

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log_success "Backup copied in ${DURATION} seconds"

# Create latest symlink on remote
log_info "Updating remote 'latest' symlink..."
ssh ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}" \
    "mkdir -p ${REMOTE_PATH} && ln -sfn ${REMOTE_PATH}/${BACKUP_NAME} ${REMOTE_PATH}/latest"

# Cleanup old backups on remote server
log_info "Cleaning up old backups (older than ${RETENTION_DAYS} days)..."
DELETED_COUNT=$(ssh ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}" \
    "find ${REMOTE_PATH} -maxdepth 1 -type d -mtime +${RETENTION_DAYS} -not -path ${REMOTE_PATH} -exec rm -rf {} \; -print | wc -l")

if [ "$DELETED_COUNT" -gt 0 ]; then
    log_success "Deleted ${DELETED_COUNT} old backup(s)"
else
    log_info "No old backups to delete"
fi

# Verify remote backup
log_info "Verifying remote backup..."
REMOTE_SIZE=$(ssh ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}" "du -sh ${REMOTE_PATH}/${BACKUP_NAME} | cut -f1")
log_success "Remote backup size: ${REMOTE_SIZE}"

# List remote backups
REMOTE_COUNT=$(ssh ${SSH_OPTS} "${REMOTE_USER}@${REMOTE_HOST}" \
    "find ${REMOTE_PATH} -maxdepth 1 -type d -not -path ${REMOTE_PATH} | wc -l")
log_info "Total remote backups: ${REMOTE_COUNT}"

echo ""
log_success "╔════════════════════════════════════════════╗"
log_success "║   Offsite Backup Sync Completed!          ║"
log_success "╚════════════════════════════════════════════╝"
log_success "Local:  ${LATEST_BACKUP}"
log_success "Remote: ${REMOTE_HOST}:${REMOTE_PATH}/${BACKUP_NAME}"
log_success "Duration: ${DURATION} seconds"
echo ""
