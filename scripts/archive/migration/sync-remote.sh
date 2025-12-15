#!/bin/bash
#
# Remote Backup Synchronization Script
# Syncs local backups to remote server using rsync
#

set -euo pipefail

# ==================== Configuration ====================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load from environment or .env file
if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a
    source "${PROJECT_DIR}/.env" 2>/dev/null || true
    set +a
fi

# Remote server configuration
REMOTE_HOST="${BACKUP_REMOTE_HOST:-65.21.202.252}"
REMOTE_USER="${BACKUP_REMOTE_USER:-root}"
REMOTE_PATH="${BACKUP_REMOTE_PATH:-/var/backups/litellm}"
REMOTE_PORT="${BACKUP_REMOTE_PORT:-22}"

# Local backup directory
LOCAL_BACKUP_DIR="${PROJECT_DIR}/backups"

# Telegram notification script
TELEGRAM_SCRIPT="${SCRIPT_DIR}/telegram-notify.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ==================== Functions ====================

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

# Check if rsync is installed
check_requirements() {
    if ! command -v rsync &> /dev/null; then
        log_error "rsync is not installed. Install with: sudo apt-get install rsync"
        exit 1
    fi
}

# Test SSH connection to remote server
test_ssh_connection() {
    log_info "Testing SSH connection to ${REMOTE_USER}@${REMOTE_HOST}..."

    if ssh -p "${REMOTE_PORT}" -o ConnectTimeout=10 -o BatchMode=yes "${REMOTE_USER}@${REMOTE_HOST}" "echo 'SSH connection successful'" &> /dev/null; then
        log_success "SSH connection successful"
        return 0
    else
        log_error "SSH connection failed to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}"
        log_error "Please ensure:"
        log_error "  1. SSH keys are configured (ssh-copy-id ${REMOTE_USER}@${REMOTE_HOST})"
        log_error "  2. Remote server is reachable"
        log_error "  3. Firewall allows SSH on port ${REMOTE_PORT}"
        return 1
    fi
}

# Create remote backup directory if not exists
create_remote_directory() {
    log_info "Creating remote backup directory..."

    ssh -p "${REMOTE_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" \
        "mkdir -p ${REMOTE_PATH}/{daily,weekly,monthly}" 2>/dev/null || true

    log_success "Remote directory created: ${REMOTE_PATH}"
}

# Sync backups to remote server
sync_backups() {
    local backup_type=${1:-"all"}

    log_info "Starting rsync to remote server..."
    log_info "Local: ${LOCAL_BACKUP_DIR}"
    log_info "Remote: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"

    local rsync_opts=(
        -avz                          # Archive mode, verbose, compress
        --partial                     # Keep partially transferred files
        --progress                    # Show progress
        --delete                      # Delete files on remote that don't exist locally
        --exclude='.backup_status'    # Don't sync status file
        --exclude='latest'            # Don't sync symlink
        -e "ssh -p ${REMOTE_PORT}"    # SSH with custom port
    )

    # Sync specific type or all
    case ${backup_type} in
        daily)
            rsync "${rsync_opts[@]}" \
                "${LOCAL_BACKUP_DIR}/daily/" \
                "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/daily/"
            ;;
        weekly)
            rsync "${rsync_opts[@]}" \
                "${LOCAL_BACKUP_DIR}/weekly/" \
                "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/weekly/"
            ;;
        monthly)
            rsync "${rsync_opts[@]}" \
                "${LOCAL_BACKUP_DIR}/monthly/" \
                "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/monthly/"
            ;;
        all|*)
            # Sync all backup types
            for type in daily weekly monthly; do
                if [ -d "${LOCAL_BACKUP_DIR}/${type}" ]; then
                    log_info "Syncing ${type} backups..."
                    rsync "${rsync_opts[@]}" \
                        "${LOCAL_BACKUP_DIR}/${type}/" \
                        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/${type}/" || {
                        log_error "Failed to sync ${type} backups"
                        return 1
                    }
                fi
            done
            ;;
    esac

    log_success "Sync completed successfully"
}

# Get remote backup statistics
get_remote_stats() {
    log_info "Fetching remote backup statistics..."

    local remote_size=$(ssh -p "${REMOTE_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" \
        "du -sh ${REMOTE_PATH} 2>/dev/null | cut -f1" || echo "N/A")

    local remote_count=$(ssh -p "${REMOTE_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" \
        "find ${REMOTE_PATH} -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l" || echo "0")

    log_success "Remote backups: ${remote_count} directories, ${remote_size} total"
}

# Send Telegram notification
send_notification() {
    local status=$1
    local message=$2

    if [ -x "${TELEGRAM_SCRIPT}" ]; then
        case ${status} in
            success)
                "${TELEGRAM_SCRIPT}" custom success "Remote Sync Successful" "${message}" || true
                ;;
            failure)
                "${TELEGRAM_SCRIPT}" custom error "Remote Sync Failed" "${message}" || true
                ;;
            warning)
                "${TELEGRAM_SCRIPT}" warning "${message}" || true
                ;;
        esac
    fi
}

# ==================== Main Execution ====================

main() {
    local start_time=$(date +%s)
    local backup_type="${1:-all}"

    echo ""
    log_info "╔════════════════════════════════════════════╗"
    log_info "║   Remote Backup Sync                       ║"
    log_info "║   Started: $(date '+%Y-%m-%d %H:%M:%S')              ║"
    log_info "╚════════════════════════════════════════════╝"
    echo ""

    # Check requirements
    check_requirements

    # Check if local backup directory exists
    if [ ! -d "${LOCAL_BACKUP_DIR}" ]; then
        log_error "Local backup directory not found: ${LOCAL_BACKUP_DIR}"
        send_notification "failure" "Local backup directory not found"
        exit 1
    fi

    # Test SSH connection
    if ! test_ssh_connection; then
        send_notification "failure" "SSH connection to ${REMOTE_HOST} failed"
        exit 1
    fi

    # Create remote directory structure
    create_remote_directory

    # Sync backups
    echo ""
    if sync_backups "${backup_type}"; then
        # Get statistics
        get_remote_stats

        # Calculate execution time
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        echo ""
        log_success "╔════════════════════════════════════════════╗"
        log_success "║   Sync Completed Successfully!             ║"
        log_success "╚════════════════════════════════════════════╝"
        log_success "Remote: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"
        log_success "Duration: ${duration} seconds"
        echo ""

        send_notification "success" "Synced to ${REMOTE_HOST} in ${duration}s"
    else
        log_error "Sync failed"
        send_notification "failure" "Sync to ${REMOTE_HOST} failed"
        exit 1
    fi
}

# Command line usage
if [ "${1:-}" == "--help" ] || [ "${1:-}" == "-h" ]; then
    cat << EOF
Usage: $0 [backup_type]

Arguments:
  backup_type   - Type of backups to sync (daily|weekly|monthly|all)
                  Default: all

Examples:
  $0              # Sync all backups
  $0 daily        # Sync only daily backups
  $0 weekly       # Sync only weekly backups

Environment Variables (set in .env):
  BACKUP_REMOTE_HOST  - Remote server hostname/IP (default: 65.21.202.252)
  BACKUP_REMOTE_USER  - Remote SSH user (default: root)
  BACKUP_REMOTE_PATH  - Remote backup path (default: /var/backups/litellm)
  BACKUP_REMOTE_PORT  - SSH port (default: 22)

Prerequisites:
  1. rsync installed: sudo apt-get install rsync
  2. SSH key authentication configured: ssh-copy-id user@host
  3. Remote directory writable by SSH user

EOF
    exit 0
fi

# Run main function
main "$@"
