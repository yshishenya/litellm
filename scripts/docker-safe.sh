#!/bin/bash
#
# Docker Safe Wrapper Script
# Prevents accidental data loss from dangerous docker compose commands
#

set -euo pipefail

# ==================== Configuration ====================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_SCRIPT="${SCRIPT_DIR}/backup.sh"

COMMON_LIB="${SCRIPT_DIR}/lib/common.sh"
if [ -f "${COMMON_LIB}" ]; then
    source "${COMMON_LIB}"
else
    echo "ERROR: Missing ${COMMON_LIB}"
    exit 1
fi

# ==================== Functions ====================

# Display banner
show_banner() {
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════╗"
    echo "║        Docker Safe Wrapper                 ║"
    echo "║   Protecting your data from accidents      ║"
    echo "╚════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Check if command contains dangerous flags
is_dangerous_command() {
    local cmd="$*"

    # Check for volume deletion flags
    if [[ "$cmd" =~ "down".*"-v" ]] || [[ "$cmd" =~ "down".*"--volumes" ]]; then
        return 0  # Dangerous
    fi

    # Check for force removal
    if [[ "$cmd" =~ "rm".*"-f" ]] || [[ "$cmd" =~ "rm".*"--force" ]]; then
        return 0  # Dangerous
    fi

    # Check for volume prune
    if [[ "$cmd" =~ "volume".*"prune" ]]; then
        return 0  # Dangerous
    fi

    return 1  # Safe
}

# Display warning for dangerous command
show_danger_warning() {
    local cmd="$*"

    echo ""
    log_danger "⚠️  DANGEROUS COMMAND DETECTED ⚠️"
    echo ""
    log_error "Command: ${cmd}"
    echo ""
    log_warning "This command will DELETE all Docker volumes, including:"
    log_warning "  • PostgreSQL database (88,030+ records)"
    log_warning "  • Grafana dashboards and settings"
    log_warning "  • Prometheus metrics data"
    log_warning "  • Redis cache"
    echo ""
    log_info "Safer alternatives:"
    log_info "  docker compose restart          # Restart without losing data"
    log_info "  docker compose down && docker compose up -d  # Recreate without -v flag"
    log_info "  ./scripts/docker-safe.sh down   # Safe wrapper that prompts"
    echo ""
}

# Create backup before dangerous operation
create_safety_backup() {
    log_warning "Creating safety backup before proceeding..."

    if [ -x "${BACKUP_SCRIPT}" ]; then
        if "${BACKUP_SCRIPT}"; then
            log_success "Safety backup created successfully"
            return 0
        else
            log_error "Failed to create safety backup"
            return 1
        fi
    else
        log_error "Backup script not found or not executable: ${BACKUP_SCRIPT}"
        return 1
    fi
}

# Confirm dangerous action with user
confirm_dangerous_action() {
    local cmd="$*"

    echo -e "${RED}${BOLD}"
    read -p "Are you ABSOLUTELY SURE you want to delete all volumes? Type 'DELETE VOLUMES' to confirm: " confirmation
    echo -e "${NC}"

    if [ "$confirmation" != "DELETE VOLUMES" ]; then
        log_info "Operation cancelled by user"
        return 1
    fi

    echo ""
    log_warning "Creating mandatory backup before proceeding..."
    if ! create_safety_backup; then
        log_error "Cannot proceed without successful backup"
        return 1
    fi

    echo ""
    log_warning "Last chance to cancel!"
    read -p "Type 'YES' to proceed with volume deletion: " final_confirm

    if [ "$final_confirm" != "YES" ]; then
        log_info "Operation cancelled by user"
        return 1
    fi

    return 0
}

# Execute docker compose command safely
execute_command() {
    local cmd="$*"

    cd "${PROJECT_DIR}"

    if is_dangerous_command "$cmd"; then
        show_danger_warning "$cmd"

        if confirm_dangerous_action "$cmd"; then
            log_warning "Executing dangerous command: $cmd"
            docker compose $cmd
        else
            log_info "Command not executed"
            exit 1
        fi
    else
        log_info "Executing: docker compose $cmd"
        docker compose $cmd
    fi
}

# Show usage information
show_usage() {
    cat << EOF
Docker Safe Wrapper - Protects against accidental data loss

Usage: $0 <docker-compose-command>

Common Safe Commands:
  $0 up -d                 # Start services
  $0 down                  # Stop and remove containers (KEEPS volumes)
  $0 restart               # Restart all services
  $0 restart <service>     # Restart specific service
  $0 logs -f <service>     # View service logs
  $0 ps                    # List running containers

Dangerous Commands (will prompt for confirmation):
  $0 down -v               # ⚠️  DELETES ALL VOLUMES
  $0 down --volumes        # ⚠️  DELETES ALL VOLUMES
  $0 rm -f                 # ⚠️  Force remove containers

Safe Alternatives:
  Instead of: docker compose down -v
  Use:        docker compose restart

Aliases (add to ~/.bashrc or ~/.zshrc):
  alias dcup='cd ${PROJECT_DIR} && ./scripts/docker-safe.sh up -d'
  alias dcdown='cd ${PROJECT_DIR} && ./scripts/docker-safe.sh down'
  alias dcrestart='cd ${PROJECT_DIR} && ./scripts/docker-safe.sh restart'
  alias dclogs='cd ${PROJECT_DIR} && ./scripts/docker-safe.sh logs -f'
  alias dcps='cd ${PROJECT_DIR} && ./scripts/docker-safe.sh ps'

EOF
}

# ==================== Main ====================

main() {
    # Check if no arguments provided
    if [ $# -eq 0 ]; then
        show_banner
        show_usage
        exit 0
    fi

    # Check for help flag
    if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
        show_banner
        show_usage
        exit 0
    fi

    # Check if docker compose is available
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed or not in PATH"
        exit 1
    fi

    # Execute the command
    execute_command "$@"
}

# Run main function with all arguments
main "$@"
