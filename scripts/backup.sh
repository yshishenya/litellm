#!/bin/bash
#
# LiteLLM Comprehensive Backup Script
# Implements 3-2-1 backup strategy with rotation
# Daily: 7 days, Weekly: 4 weeks, Monthly: 12 months
#

set -euo pipefail

# ==================== Configuration ====================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_BASE_DIR="${PROJECT_DIR}/backups"

# Database configuration
DB_HOST="localhost"
DB_PORT="5433"
DB_USER="llmproxy"
DB_PASSWORD="dbpassword9090"
DB_NAME="litellm"
DB_CONTAINER="litellm_db"

# Retention periods - OPTIMIZED for disk space
DAILY_RETENTION=3      # Keep 3 daily backups (rest on remote)
WEEKLY_RETENTION=0     # Disabled (kept only on remote)
MONTHLY_RETENTION=0    # Disabled (kept only on remote)

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

# Check if required commands exist
check_requirements() {
    local missing_cmds=()

    for cmd in docker pg_dump date find ln; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -gt 0 ]; then
        log_error "Missing required commands: ${missing_cmds[*]}"
        exit 1
    fi

    # Check if Docker daemon is running
    if ! docker ps &> /dev/null; then
        log_error "Docker daemon is not running"
        exit 1
    fi

    # Check if database container is running
    if ! docker ps --filter "name=${DB_CONTAINER}" --format "{{.Names}}" | grep -q "^${DB_CONTAINER}$"; then
        log_error "Database container '${DB_CONTAINER}' is not running"
        exit 1
    fi
}

# Get backup type based on date
get_backup_type() {
    local day_of_week=$(date +%u)  # 1=Monday, 7=Sunday
    local day_of_month=$(date +%d)

    if [ "$day_of_month" == "01" ]; then
        echo "monthly"
    elif [ "$day_of_week" == "7" ]; then  # Sunday
        echo "weekly"
    else
        echo "daily"
    fi
}

# Create backup directory structure
create_backup_dir() {
    local backup_type=$1
    local timestamp=$(date +%Y-%m-%d_%H%M%S)
    local backup_dir=""

    case $backup_type in
        daily)
            backup_dir="${BACKUP_BASE_DIR}/daily/${timestamp}"
            ;;
        weekly)
            local week_num=$(date +%Y-W%V)
            backup_dir="${BACKUP_BASE_DIR}/weekly/${week_num}"
            ;;
        monthly)
            local month=$(date +%Y-%m)
            backup_dir="${BACKUP_BASE_DIR}/monthly/${month}"
            ;;
    esac

    mkdir -p "$backup_dir"
    echo "$backup_dir"
}

# Backup PostgreSQL database
backup_database() {
    local backup_dir=$1
    local db_backup_file="${backup_dir}/postgresql_${DB_NAME}.sql.gz"

    log_info "Backing up PostgreSQL database (with gzip compression)..."

    # Backup with compression - saves ~80% disk space
    PGPASSWORD="${DB_PASSWORD}" pg_dump \
        -h "${DB_HOST}" \
        -p "${DB_PORT}" \
        -U "${DB_USER}" \
        -d "${DB_NAME}" \
        --clean \
        --if-exists \
        --create \
        | gzip -9 > "${db_backup_file}"

    if [ ! -s "${db_backup_file}" ]; then
        log_error "Database backup file is empty"
        return 1
    fi

    local db_size=$(du -h "${db_backup_file}" | cut -f1)
    log_success "Database backed up compressed (${db_size}): ${db_backup_file}"

    # Verify backup can be read (gzip test)
    if ! gzip -t "${db_backup_file}" 2>/dev/null; then
        log_error "Database backup file is corrupted"
        return 1
    fi
}

# Backup Grafana dashboards
backup_grafana() {
    local backup_dir=$1
    local grafana_backup_dir="${backup_dir}/grafana"

    log_info "Backing up Grafana dashboards..."

    if [ -d "${PROJECT_DIR}/grafana/provisioning" ]; then
        mkdir -p "${grafana_backup_dir}"
        cp -r "${PROJECT_DIR}/grafana/provisioning" "${grafana_backup_dir}/"

        local dashboard_count=$(find "${grafana_backup_dir}/provisioning/dashboards" -name "*.json" 2>/dev/null | wc -l)
        log_success "Grafana backed up (${dashboard_count} dashboards)"
    else
        log_warning "Grafana provisioning directory not found"
    fi
}

# Backup configuration files
backup_configs() {
    local backup_dir=$1
    local config_backup_dir="${backup_dir}/configs"

    log_info "Backing up configuration files..."

    mkdir -p "${config_backup_dir}"

    # List of config files to backup
    local config_files=(
        "docker-compose.yml"
        "config.yaml"
        "prometheus.yml"
        ".env"
        "litellm_simple_working_exporter.py"
    )

    local backed_up=0
    for file in "${config_files[@]}"; do
        if [ -f "${PROJECT_DIR}/${file}" ]; then
            cp "${PROJECT_DIR}/${file}" "${config_backup_dir}/${file}.backup"
            backed_up=$((backed_up + 1))
        fi
    done

    log_success "Backed up ${backed_up} configuration files"
}

# Create backup inventory
create_inventory() {
    local backup_dir=$1
    local inventory_file="${backup_dir}/BACKUP_INVENTORY.txt"

    log_info "Creating backup inventory..."

    cat > "${inventory_file}" << EOF
===============================================
LiteLLM Backup Inventory
===============================================
Backup Date: $(date '+%Y-%m-%d %H:%M:%S')
Backup Type: $(basename $(dirname ${backup_dir}))
Backup Location: ${backup_dir}
===============================================

Contents:
EOF

    find "${backup_dir}" -type f -exec ls -lh {} \; | \
        awk '{print $9 "\t" $5}' >> "${inventory_file}"

    echo "" >> "${inventory_file}"
    echo "Total Size: $(du -sh ${backup_dir} | cut -f1)" >> "${inventory_file}"

    log_success "Inventory created"
}

# Create restore script
create_restore_script() {
    local backup_dir=$1
    local restore_script="${backup_dir}/RESTORE.sh"

    cat > "${restore_script}" << 'RESTORE_EOF'
#!/bin/bash
# Auto-generated restore script

set -e

BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "🔄 Restoring from: ${BACKUP_DIR}"

# Stop services
echo "⏸️  Stopping services..."
cd "$(dirname $(dirname ${BACKUP_DIR}))"
docker compose stop litellm litellm-metrics-exporter

# Restore database
echo "🗄️  Restoring PostgreSQL database..."
if [ -f "${BACKUP_DIR}/postgresql_litellm.sql" ]; then
    PGPASSWORD=dbpassword9090 psql -h localhost -p 5433 -U llmproxy litellm < "${BACKUP_DIR}/postgresql_litellm.sql"
    echo "✅ Database restored"
else
    echo "⚠️  Database backup not found"
fi

# Restore configs
echo "📝 Restoring configuration files..."
if [ -d "${BACKUP_DIR}/configs" ]; then
    for file in ${BACKUP_DIR}/configs/*.backup; do
        if [ -f "$file" ]; then
            original_name=$(basename "$file" .backup)
            cp "$file" "$(dirname $(dirname ${BACKUP_DIR}))/${original_name}"
            echo "  ✅ Restored ${original_name}"
        fi
    done
fi

# Restore Grafana
echo "📊 Restoring Grafana dashboards..."
if [ -d "${BACKUP_DIR}/grafana/provisioning" ]; then
    cp -r "${BACKUP_DIR}/grafana/provisioning" "$(dirname $(dirname ${BACKUP_DIR}))/grafana/"
    echo "✅ Grafana restored"
fi

# Restart services
echo "▶️  Starting services..."
docker compose start litellm litellm-metrics-exporter

echo ""
echo "✨ Restore completed successfully!"
echo "Please verify the services are working correctly."
RESTORE_EOF

    chmod +x "${restore_script}"
    log_success "Restore script created"
}

# Rotate old backups
rotate_backups() {
    local backup_type=$1
    local retention=$2
    local backup_subdir="${BACKUP_BASE_DIR}/${backup_type}"

    if [ ! -d "${backup_subdir}" ]; then
        return 0
    fi

    log_info "Rotating ${backup_type} backups (keeping last ${retention})..."

    # Find and sort backups by modification time (oldest first)
    local backup_count=$(find "${backup_subdir}" -maxdepth 1 -type d -not -path "${backup_subdir}" | wc -l)

    if [ ${backup_count} -gt ${retention} ]; then
        local to_delete=$((backup_count - retention))

        find "${backup_subdir}" -maxdepth 1 -type d -not -path "${backup_subdir}" -printf '%T+ %p\n' | \
            sort | \
            head -n ${to_delete} | \
            cut -d' ' -f2- | \
            while read dir; do
                local size=$(du -sh "$dir" | cut -f1)
                log_warning "Removing old backup: $(basename $dir) (${size})"
                rm -rf "$dir"
            done

        log_success "Removed ${to_delete} old ${backup_type} backup(s)"
    else
        log_info "No ${backup_type} backups to rotate (${backup_count}/${retention})"
    fi
}

# Update latest symlink
update_latest_symlink() {
    local backup_dir=$1
    local latest_link="${BACKUP_BASE_DIR}/latest"

    # Remove old symlink if exists
    [ -L "${latest_link}" ] && rm "${latest_link}"

    # Create new symlink
    ln -sf "${backup_dir}" "${latest_link}"
    log_success "Updated 'latest' symlink"
}

# Write backup status for monitoring
write_backup_status() {
    local status=$1
    local backup_dir=$2
    local error_msg=${3:-""}

    local status_file="${BACKUP_BASE_DIR}/.backup_status"

    cat > "${status_file}" << EOF
{
  "timestamp": "$(date -Iseconds)",
  "status": "${status}",
  "backup_dir": "${backup_dir}",
  "backup_size": "$(du -sh ${backup_dir} 2>/dev/null | cut -f1 || echo 'N/A')",
  "error": "${error_msg}"
}
EOF
}

# ==================== Main Execution ====================

main() {
    local start_time=$(date +%s)

    echo ""
    log_info "╔════════════════════════════════════════════╗"
    log_info "║   LiteLLM Backup Script                    ║"
    log_info "║   Started: $(date '+%Y-%m-%d %H:%M:%S')              ║"
    log_info "╚════════════════════════════════════════════╝"
    echo ""

    # Check requirements
    check_requirements

    # Determine backup type
    local backup_type=$(get_backup_type)
    log_info "Backup type: ${backup_type}"

    # Create backup directory
    local backup_dir=$(create_backup_dir "${backup_type}")
    log_success "Backup directory: ${backup_dir}"
    echo ""

    # Perform backups
    if ! backup_database "${backup_dir}"; then
        log_error "Database backup failed"
        write_backup_status "failed" "${backup_dir}" "Database backup failed"
        exit 1
    fi

    backup_grafana "${backup_dir}"
    backup_configs "${backup_dir}"

    # Create inventory and restore script
    create_inventory "${backup_dir}"
    create_restore_script "${backup_dir}"

    # Update latest symlink
    update_latest_symlink "${backup_dir}"

    # Rotate old backups
    echo ""
    rotate_backups "daily" ${DAILY_RETENTION}
    rotate_backups "weekly" ${WEEKLY_RETENTION}
    rotate_backups "monthly" ${MONTHLY_RETENTION}

    # Write status
    write_backup_status "success" "${backup_dir}"

    # Calculate execution time
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local backup_size=$(du -sh "${backup_dir}" | cut -f1)

    echo ""
    log_success "╔════════════════════════════════════════════╗"
    log_success "║   Backup Completed Successfully!          ║"
    log_success "╚════════════════════════════════════════════╝"
    log_success "Location: ${backup_dir}"
    log_success "Size: ${backup_size}"
    log_success "Duration: ${duration} seconds"
    echo ""
}

# Run main function
main "$@"
