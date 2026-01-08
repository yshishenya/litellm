#!/bin/bash
#
# LiteLLM Universal Restore Script
# Interactive restoration from any backup (daily/weekly/monthly)
#

set -euo pipefail

# ==================== Configuration ====================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

COMMON_LIB="${SCRIPT_DIR}/lib/common.sh"
if [ -f "${COMMON_LIB}" ]; then
    source "${COMMON_LIB}"
else
    echo "ERROR: Missing ${COMMON_LIB}"
    exit 1
fi

# Telegram helper
TELEGRAM_LIB="${SCRIPT_DIR}/lib/telegram.sh"
if [ -f "${TELEGRAM_LIB}" ]; then
    source "${TELEGRAM_LIB}"
    telegram_load_env "${PROJECT_DIR}/.env"
else
    echo "ERROR: Missing ${TELEGRAM_LIB}"
    exit 1
fi

BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-/opt/backups/litellm}"

# Database configuration
DB_HOST="localhost"
DB_PORT="5433"
DB_USER="llmproxy"
DB_PASSWORD="dbpassword9090"
DB_NAME="litellm"
DB_CONTAINER="litellm_db"

# ==================== Functions ====================

check_requirements() {
    require_cmds docker psql gzip stat du find awk sed || exit 1
}

# Display banner
show_banner() {
    echo -e "${GREEN}"
    echo "╔════════════════════════════════════════════╗"
    echo "║   LiteLLM Backup Restore Tool              ║"
    echo "║   Recover from any backup point            ║"
    echo "╚════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# List available backups
list_backups() {
    local backup_type=$1
    local backup_dir="${BACKUP_BASE_DIR}/${backup_type}"

    if [ ! -d "${backup_dir}" ]; then
        return 1
    fi

    find "${backup_dir}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | \
        sort -rn | \
        cut -d' ' -f2-
}

# Display available backups
show_available_backups() {
    echo ""
    log_info "Available Backups:"
    echo ""

    local backup_types=("daily" "weekly" "monthly")
    local total_count=0

    for type in "${backup_types[@]}"; do
        local count=$(list_backups "$type" | wc -l)
        if [ ${count} -gt 0 ]; then
            echo -e "${YELLOW}${type^}:${NC} ${count} backup(s)"
            total_count=$((total_count + count))

            list_backups "$type" | while read backup_path; do
                local backup_name=$(basename "$backup_path")
                local backup_size=$(du -sh "$backup_path" 2>/dev/null | cut -f1 || echo "N/A")
                local backup_date=$(stat -c %y "$backup_path" | cut -d'.' -f1)
                echo "  • ${backup_name} (${backup_size}) - ${backup_date}"
            done
            echo ""
        fi
    done

    if [ ${total_count} -eq 0 ]; then
        log_error "No backups found in ${BACKUP_BASE_DIR}"
        return 1
    fi

    return 0
}

# Select backup interactively
select_backup_interactive() {
    show_available_backups || return 1

    echo ""
    log_info "Enter backup type (daily/weekly/monthly):"
    read -p "> " backup_type

    case ${backup_type} in
        daily|weekly|monthly)
            ;;
        *)
            log_error "Invalid backup type"
            return 1
            ;;
    esac

    local backups=($(list_backups "$backup_type"))

    if [ ${#backups[@]} -eq 0 ]; then
        log_error "No ${backup_type} backups found"
        return 1
    fi

    echo ""
    log_info "Available ${backup_type} backups:"
    echo ""

    local i=1
    for backup in "${backups[@]}"; do
        local backup_name=$(basename "$backup")
        local backup_size=$(du -sh "$backup" 2>/dev/null | cut -f1 || echo "N/A")
        local backup_date=$(stat -c %y "$backup" | cut -d'.' -f1)
        echo "${i}) ${backup_name} (${backup_size}) - ${backup_date}"
        i=$((i + 1))
    done

    echo ""
    read -p "Select backup number (1-${#backups[@]}): " selection

    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#backups[@]} ]; then
        log_error "Invalid selection"
        return 1
    fi

    local selected_backup="${backups[$((selection - 1))]}"
    echo "$selected_backup"
}

# Verify backup integrity
verify_backup() {
    local backup_dir=$1

    log_info "Verifying backup integrity..."

    # Check if backup directory exists
    if [ ! -d "${backup_dir}" ]; then
        log_error "Backup directory not found: ${backup_dir}"
        return 1
    fi

    local db_backup_gz="${backup_dir}/postgresql_${DB_NAME}.sql.gz"
    local db_backup_sql="${backup_dir}/postgresql_${DB_NAME}.sql"
    local db_backup=""

    if [ -f "${db_backup_gz}" ]; then
        db_backup="${db_backup_gz}"
        if ! gzip -t "${db_backup}" &> /dev/null; then
            log_error "Database backup is corrupted: ${db_backup}"
            return 1
        fi
    elif [ -f "${db_backup_sql}" ]; then
        db_backup="${db_backup_sql}"
        if ! head -n 1 "${db_backup}" &> /dev/null; then
            log_error "Database backup is not readable or corrupted"
            return 1
        fi
    else
        log_error "Database backup not found: ${db_backup_gz} or ${db_backup_sql}"
        return 1
    fi

    local db_size=$(stat -c%s "${db_backup}")
    if [ ${db_size} -lt 1000 ]; then
        log_error "Database backup is suspiciously small (${db_size} bytes)"
        return 1
    fi

    log_success "Backup integrity verified"
    return 0
}

# Stop dependent services
stop_services() {
    log_info "Stopping dependent services..."

    cd "${PROJECT_DIR}"

    if docker compose ps --services | grep -q "^litellm$"; then
        docker compose stop litellm litellm-metrics-exporter 2>/dev/null || true
        log_success "Services stopped"
    else
        log_warning "Services not running"
    fi
}

# Start services
start_services() {
    log_info "Starting services..."

    cd "${PROJECT_DIR}"
    docker compose start litellm litellm-metrics-exporter 2>/dev/null || true

    log_success "Services started"
}

# Restore database
restore_database() {
    local backup_dir=$1
    local db_backup_gz="${backup_dir}/postgresql_${DB_NAME}.sql.gz"
    local db_backup_sql="${backup_dir}/postgresql_${DB_NAME}.sql"

    log_info "Restoring PostgreSQL database..."

    # Drop existing connections
    PGPASSWORD="${DB_PASSWORD}" psql \
        -h "${DB_HOST}" \
        -p "${DB_PORT}" \
        -U "${DB_USER}" \
        -d postgres \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();" \
        &> /dev/null || true

    local restore_log="${backup_dir}/restore_${DB_NAME}.log"
    if [ -f "${db_backup_gz}" ]; then
        if ! PGPASSWORD="${DB_PASSWORD}" gzip -dc "${db_backup_gz}" | \
            psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
            > "${restore_log}" 2>&1; then
            log_error "Database restoration failed (see ${restore_log})"
            return 1
        fi
    elif [ -f "${db_backup_sql}" ]; then
        if ! PGPASSWORD="${DB_PASSWORD}" psql \
            -h "${DB_HOST}" \
            -p "${DB_PORT}" \
            -U "${DB_USER}" \
            -d "${DB_NAME}" \
            < "${db_backup_sql}" > "${restore_log}" 2>&1; then
            log_error "Database restoration failed (see ${restore_log})"
            return 1
        fi
    else
        log_error "Database backup not found"
        return 1
    fi

    local record_count=$(PGPASSWORD="${DB_PASSWORD}" psql \
        -h "${DB_HOST}" \
        -p "${DB_PORT}" \
        -U "${DB_USER}" \
        -d "${DB_NAME}" \
        -t -c "SELECT COUNT(*) FROM \"LiteLLM_SpendLogs\";" | xargs)

    log_success "Database restored (${record_count} records in LiteLLM_SpendLogs)"
    return 0
}

# Restore Grafana dashboards
restore_grafana() {
    local backup_dir=$1
    local grafana_backup="${backup_dir}/grafana/provisioning"

    if [ -d "${grafana_backup}" ]; then
        log_info "Restoring Grafana dashboards..."

        # Backup current dashboards first
        if [ -d "${PROJECT_DIR}/grafana/provisioning" ]; then
            local timestamp=$(date +%Y%m%d_%H%M%S)
            mv "${PROJECT_DIR}/grafana/provisioning" \
               "${PROJECT_DIR}/grafana/provisioning.backup_${timestamp}"
            log_info "Current dashboards backed up"
        fi

        # Restore dashboards
        cp -r "${grafana_backup}" "${PROJECT_DIR}/grafana/"

        log_success "Grafana dashboards restored"
    else
        log_warning "No Grafana backup found, skipping"
    fi
}

# Restore configuration files
restore_configs() {
    local backup_dir=$1
    local config_backup="${backup_dir}/configs"

    if [ -d "${config_backup}" ]; then
        log_info "Restoring configuration files..."

        local restored=0
        for file in "${config_backup}"/*.backup; do
            if [ -f "$file" ]; then
                local original_name=$(basename "$file" .backup)

                # Don't restore .env by default (contains secrets)
                if [ "$original_name" == ".env" ]; then
                    echo ""
                    log_warning ".env file found in backup"
                    read -p "Restore .env file? (y/N): " confirm_env
                    if [ "${confirm_env,,}" != "y" ]; then
                        log_info "Skipping .env restoration"
                        continue
                    fi
                fi

                # Backup current file
                if [ -f "${PROJECT_DIR}/${original_name}" ]; then
                    local timestamp=$(date +%Y%m%d_%H%M%S)
                    cp "${PROJECT_DIR}/${original_name}" \
                       "${PROJECT_DIR}/${original_name}.backup_${timestamp}"
                fi

                # Restore file
                cp "$file" "${PROJECT_DIR}/${original_name}"
                log_success "Restored ${original_name}"
                restored=$((restored + 1))
            fi
        done

        log_success "Restored ${restored} configuration file(s)"
    else
        log_warning "No config backup found, skipping"
    fi
}

# Send notification
send_notification() {
    local status=$1
    local message=$2

    telegram_send "<b>Database Restore</b>\n\n${message}" "HTML" "${PROJECT_DIR}/.env" &>/dev/null || true
}

# ==================== Main ====================

main() {
    local start_time=$(date +%s)

    show_banner
    check_requirements

    # Check if backup directory exists
    if [ ! -d "${BACKUP_BASE_DIR}" ]; then
        log_error "Backup directory not found: ${BACKUP_BASE_DIR}"
        exit 1
    fi

    # Select backup
    local backup_dir=""

    if [ $# -gt 0 ]; then
        # Use provided backup path
        backup_dir="$1"
        if [ ! -d "${backup_dir}" ]; then
            log_error "Backup directory not found: ${backup_dir}"
            exit 1
        fi
    else
        # Interactive selection
        backup_dir=$(select_backup_interactive)
        if [ $? -ne 0 ]; then
            exit 1
        fi
    fi

    log_info "Selected backup: $(basename ${backup_dir})"

    # Verify backup
    if ! verify_backup "${backup_dir}"; then
        log_error "Backup verification failed"
        exit 1
    fi

    # Show backup information
    echo ""
    log_info "Backup Information:"
    if [ -f "${backup_dir}/BACKUP_INVENTORY.txt" ]; then
        echo ""
        head -n 15 "${backup_dir}/BACKUP_INVENTORY.txt" || true
        echo ""
    fi

    # Confirmation
    echo ""
    log_danger "⚠️  WARNING: This will replace current data with backup data!"
    log_warning "Current database will be overwritten"
    echo ""
    read -p "Are you sure you want to restore from this backup? (yes/NO): " confirm

    if [ "${confirm}" != "yes" ]; then
        log_info "Restoration cancelled"
        exit 0
    fi

    echo ""
    log_info "Starting restoration process..."
    echo ""

    # Stop services
    stop_services
    sleep 2

    # Restore database
    if ! restore_database "${backup_dir}"; then
        log_error "Database restoration failed"
        send_notification "error" "Database restoration failed"
        start_services
        exit 1
    fi

    # Restore Grafana
    restore_grafana "${backup_dir}"

    # Restore configs
    restore_configs "${backup_dir}"

    # Start services
    echo ""
    start_services

    # Calculate duration
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo ""
    log_success "╔════════════════════════════════════════════╗"
    log_success "║   Restoration Completed Successfully!     ║"
    log_success "╚════════════════════════════════════════════╝"
    log_success "Restored from: $(basename ${backup_dir})"
    log_success "Duration: ${duration} seconds"
    echo ""
    log_info "Please verify that services are working correctly:"
    log_info "  • Check database: docker compose logs litellm"
    log_info "  • Access Grafana: http://localhost:3098"
    log_info "  • Test LiteLLM: curl http://localhost:4000/health/liveliness"
    echo ""

    send_notification "success" "Database restored successfully from $(basename ${backup_dir})"
}

# Run main
if [ "${1:-}" == "--help" ] || [ "${1:-}" == "-h" ]; then
    cat << EOF
LiteLLM Restore Script - Recover from backups

Usage: $0 [backup_directory]

Interactive Mode (recommended):
  $0

Direct Restore:
  $0 /path/to/backup/directory

Examples:
  $0                                           # Interactive selection
  $0 /opt/backups/litellm/daily/2025-10-28_030000          # Restore specific backup
  $0 /opt/backups/litellm/latest                            # Restore latest backup

What will be restored:
  ✓ PostgreSQL database (all tables and data)
  ✓ Grafana dashboards and settings
  ✓ Configuration files (with confirmation)

Safety Features:
  • Backup integrity verification before restore
  • Current files backed up before overwriting
  • Services stopped during restoration
  • Confirmation prompts for critical actions

EOF
    exit 0
fi

main "$@"
