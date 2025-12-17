#!/bin/bash
#
# LiteLLM Offsite Backup Sync Script
# Copies latest backups to remote server 135.181.215.121
#

set -euo pipefail

# Configuration
BACKUP_SOURCE="/opt/projects/litellm/backups"
REMOTE_HOST="135.181.215.121"
REMOTE_USER="yan"
REMOTE_PATH="/opt/backups/projects/litellm"
RETENTION_DAYS=30  # Keep 30 days of backups on remote server

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if source exists
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
log_info "Testing SSH connection to ${REMOTE_HOST}..."
if ! ssh -o ConnectTimeout=10 ${REMOTE_USER}@${REMOTE_HOST} "echo OK" &>/dev/null; then
    log_error "Cannot connect to ${REMOTE_HOST}"
    exit 1
fi
log_success "SSH connection OK"

# Sync latest backup
log_info "Syncing latest backup..."
LATEST_BACKUP=$(readlink -f ${BACKUP_SOURCE}/latest 2>/dev/null || echo "")

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
    "${LATEST_BACKUP}/" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/${BACKUP_NAME}/" 2>&1 | \
    grep -v "sending incremental file list" || true

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log_success "Backup copied in ${DURATION} seconds"

# Create latest symlink on remote
log_info "Updating remote 'latest' symlink..."
ssh ${REMOTE_USER}@${REMOTE_HOST} \
    "ln -sfn ${REMOTE_PATH}/${BACKUP_NAME} ${REMOTE_PATH}/latest"

# Cleanup old backups on remote server
log_info "Cleaning up old backups (older than ${RETENTION_DAYS} days)..."
DELETED_COUNT=$(ssh ${REMOTE_USER}@${REMOTE_HOST} \
    "find ${REMOTE_PATH} -maxdepth 1 -type d -mtime +${RETENTION_DAYS} -not -path ${REMOTE_PATH} -exec rm -rf {} \; -print | wc -l")

if [ "$DELETED_COUNT" -gt 0 ]; then
    log_success "Deleted ${DELETED_COUNT} old backup(s)"
else
    log_info "No old backups to delete"
fi

# Verify remote backup
log_info "Verifying remote backup..."
REMOTE_SIZE=$(ssh ${REMOTE_USER}@${REMOTE_HOST} "du -sh ${REMOTE_PATH}/${BACKUP_NAME} | cut -f1")
log_success "Remote backup size: ${REMOTE_SIZE}"

# List remote backups
REMOTE_COUNT=$(ssh ${REMOTE_USER}@${REMOTE_HOST} \
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
