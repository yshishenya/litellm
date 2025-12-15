#!/bin/bash
#
# Setup Automated Backups via Cron
# Adds daily backup and sync jobs to crontab
#

set -euo pipefail

# ==================== Configuration ====================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

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

# Show banner
show_banner() {
    echo -e "${GREEN}"
    echo "╔════════════════════════════════════════════╗"
    echo "║   Cron Job Setup for Automated Backups    ║"
    echo "╚════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Check if cron job already exists
check_existing_cron() {
    if crontab -l 2>/dev/null | grep -q "${PROJECT_DIR}/scripts/backup.sh"; then
        return 0  # Exists
    else
        return 1  # Doesn't exist
    fi
}

# Add cron job
add_cron_job() {
    local schedule=$1
    local cron_line=$2

    log_info "Adding cron job..."

    # Get current crontab (or empty if none exists)
    local current_cron=$(crontab -l 2>/dev/null || echo "")

    # Add new job with header
    local new_cron="${current_cron}

# LiteLLM Automated Backups (added by setup-cron.sh)
${cron_line}
"

    # Install new crontab
    echo "${new_cron}" | crontab -

    log_success "Cron job installed successfully!"
}

# Remove cron job
remove_cron_job() {
    log_info "Removing existing cron jobs..."

    # Get current crontab and filter out LiteLLM backup lines
    local current_cron=$(crontab -l 2>/dev/null || echo "")
    local new_cron=$(echo "${current_cron}" | grep -v "${PROJECT_DIR}/scripts/backup.sh" | grep -v "LiteLLM Automated Backups")

    # Install cleaned crontab
    echo "${new_cron}" | crontab -

    log_success "Existing cron jobs removed"
}

# Show current cron jobs
show_current_jobs() {
    log_info "Current cron jobs related to LiteLLM:"
    echo ""

    if crontab -l 2>/dev/null | grep -q "${PROJECT_DIR}"; then
        crontab -l 2>/dev/null | grep "${PROJECT_DIR}" || echo "  (none)"
    else
        echo "  (none)"
    fi

    echo ""
}

# ==================== Main ====================

main() {
    show_banner

    # Check if running as root (not recommended for cron)
    if [ "$EUID" -eq 0 ]; then
        log_warning "Running as root. Cron jobs will be added to root's crontab."
        log_warning "It's better to run as regular user: su - $(logname)"
        echo ""
        read -p "Continue anyway? (y/N): " confirm
        if [ "${confirm,,}" != "y" ]; then
            log_info "Cancelled"
            exit 0
        fi
    fi

    # Show current jobs
    show_current_jobs

    # Check if already exists
    if check_existing_cron; then
        log_warning "LiteLLM backup cron jobs already exist"
        echo ""
        read -p "Remove existing jobs and reconfigure? (y/N): " reconfigure
        if [ "${reconfigure,,}" == "y" ]; then
            remove_cron_job
            echo ""
        else
            log_info "Keeping existing jobs. Run with --remove to remove them."
            exit 0
        fi
    fi

    # Ask for schedule
    echo ""
    log_info "Select backup schedule:"
    echo ""
    echo "1) Daily at 3:00 AM (recommended)"
    echo "2) Every 6 hours"
    echo "3) Every 12 hours"
    echo "4) Custom (manual entry)"
    echo "5) Cancel"
    echo ""
    read -p "Choice (1-5): " choice

    local cron_schedule=""
    local cron_command="${PROJECT_DIR}/scripts/backup.sh >> ${PROJECT_DIR}/backup.log 2>&1 && ${PROJECT_DIR}/scripts/sync-remote.sh >> ${PROJECT_DIR}/sync.log 2>&1"

    case $choice in
        1)
            cron_schedule="0 3 * * *"
            log_info "Schedule: Daily at 3:00 AM"
            ;;
        2)
            cron_schedule="0 */6 * * *"
            log_info "Schedule: Every 6 hours (at 00:00, 06:00, 12:00, 18:00)"
            ;;
        3)
            cron_schedule="0 */12 * * *"
            log_info "Schedule: Every 12 hours (at 00:00, 12:00)"
            ;;
        4)
            echo ""
            log_info "Enter custom cron schedule (e.g., '0 3 * * *' for daily at 3 AM):"
            log_info "Format: minute hour day month weekday"
            echo ""
            read -p "Schedule: " cron_schedule
            ;;
        5)
            log_info "Cancelled"
            exit 0
            ;;
        *)
            log_error "Invalid choice"
            exit 1
            ;;
    esac

    # Ask about remote sync
    echo ""
    read -p "Include remote sync after backup? (Y/n): " include_sync
    if [ "${include_sync,,}" == "n" ]; then
        cron_command="${PROJECT_DIR}/scripts/backup.sh >> ${PROJECT_DIR}/backup.log 2>&1"
        log_info "Remote sync disabled"
    else
        log_info "Remote sync enabled"
    fi

    # Confirm
    echo ""
    log_warning "The following cron job will be added:"
    echo ""
    echo "  ${cron_schedule} ${cron_command}"
    echo ""
    log_info "This means:"
    case $choice in
        1) echo "  • Backup runs daily at 3:00 AM" ;;
        2) echo "  • Backup runs every 6 hours" ;;
        3) echo "  • Backup runs every 12 hours" ;;
    esac
    if [ "${include_sync,,}" != "n" ]; then
        echo "  • After backup, sync to remote server"
    fi
    echo "  • Logs saved to: ${PROJECT_DIR}/backup.log"
    if [ "${include_sync,,}" != "n" ]; then
        echo "  • Sync logs saved to: ${PROJECT_DIR}/sync.log"
    fi
    echo ""
    read -p "Confirm installation? (y/N): " confirm

    if [ "${confirm,,}" != "y" ]; then
        log_info "Cancelled"
        exit 0
    fi

    # Install cron job
    add_cron_job "$cron_schedule" "${cron_schedule} ${cron_command}"

    echo ""
    log_success "╔════════════════════════════════════════════╗"
    log_success "║   Cron Jobs Installed Successfully!       ║"
    log_success "╚════════════════════════════════════════════╝"
    echo ""
    log_info "Cron jobs:"
    crontab -l | grep "${PROJECT_DIR}"
    echo ""
    log_info "View logs with:"
    echo "  tail -f ${PROJECT_DIR}/backup.log"
    if [ "${include_sync,,}" != "n" ]; then
        echo "  tail -f ${PROJECT_DIR}/sync.log"
    fi
    echo ""
    log_info "List all cron jobs:"
    echo "  crontab -l"
    echo ""
    log_info "Remove cron jobs:"
    echo "  $0 --remove"
    echo ""
}

# Handle command line arguments
if [ $# -gt 0 ]; then
    case $1 in
        --remove|-r)
            show_banner
            show_current_jobs

            if ! check_existing_cron; then
                log_info "No LiteLLM cron jobs found"
                exit 0
            fi

            read -p "Remove all LiteLLM cron jobs? (y/N): " confirm
            if [ "${confirm,,}" == "y" ]; then
                remove_cron_job
                log_success "Cron jobs removed"
            else
                log_info "Cancelled"
            fi
            exit 0
            ;;
        --status|-s)
            show_banner
            show_current_jobs
            exit 0
            ;;
        --help|-h)
            show_banner
            cat << EOF
Usage: $0 [OPTIONS]

Interactive setup of automated backups via cron.

Options:
  (none)          Interactive setup
  --remove, -r    Remove existing cron jobs
  --status, -s    Show current cron jobs
  --help, -h      Show this help message

Examples:
  $0              # Interactive setup
  $0 --status     # Show current jobs
  $0 --remove     # Remove jobs

Manual cron setup:
  # Edit crontab
  crontab -e

  # Add this line for daily backups at 3 AM:
  0 3 * * * cd ${PROJECT_DIR} && ./scripts/backup.sh >> ${PROJECT_DIR}/backup.log 2>&1

EOF
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            log_info "Use --help for usage information"
            exit 1
            ;;
    esac
fi

# Run interactive setup
main "$@"
