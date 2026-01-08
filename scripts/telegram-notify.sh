#!/bin/bash
#
# Telegram Notification Script for LiteLLM
# Sends backup status notifications via Telegram Bot
#

set -euo pipefail

# ==================== Configuration ====================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

TELEGRAM_LIB="${SCRIPT_DIR}/lib/telegram.sh"
if [ ! -f "${TELEGRAM_LIB}" ]; then
    echo "ERROR: Missing ${TELEGRAM_LIB}"
    exit 1
fi
source "${TELEGRAM_LIB}"
telegram_load_env "${PROJECT_DIR}/.env"

# ==================== Functions ====================

# Check if Telegram is configured
check_telegram_config() {
    if ! telegram_is_configured; then
        echo "WARNING: Telegram not configured. Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID/TELEGRAM_CHAT_IDS in .env"
        return 1
    fi
    return 0
}

# Send backup success notification
send_backup_success() {
    local backup_dir=$1
    local backup_size=$2
    local duration=${3:-"N/A"}

    local backup_name=$(basename "${backup_dir}")
    local backup_type=$(basename $(dirname "${backup_dir}"))

    local message="<b>✅ Backup Successful</b>

<b>Type:</b> ${backup_type}
<b>Name:</b> ${backup_name}
<b>Size:</b> ${backup_size}
<b>Duration:</b> ${duration}s
<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')

<i>LiteLLM backup completed successfully.</i>"

    telegram_send "${message}" "HTML" "${PROJECT_DIR}/.env"
}

# Send backup failure notification
send_backup_failure() {
    local error_msg=$1

    local message="<b>❌ Backup Failed</b>

<b>Error:</b> ${error_msg}
<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')

<i>LiteLLM backup failed. Please check logs.</i>"

    telegram_send "${message}" "HTML" "${PROJECT_DIR}/.env"
}

# Send backup warning
send_backup_warning() {
    local warning_msg=$1

    local message="<b>⚠️ Backup Warning</b>

<b>Warning:</b> ${warning_msg}
<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')

<i>Please review the backup process.</i>"

    telegram_send "${message}" "HTML" "${PROJECT_DIR}/.env"
}

# Send info message
send_info() {
    local info_msg=$1

    local message="<b>ℹ️ Info</b>

${info_msg}

<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')"

    telegram_send "${message}" "HTML" "${PROJECT_DIR}/.env"
}

# Send custom message with emoji
send_custom() {
    local level=$1  # success, error, warning, info
    local title=$2
    local body=$3

    case ${level} in
        success)
            emoji="✅"
            ;;
        error)
            emoji="❌"
            ;;
        warning)
            emoji="⚠️"
            ;;
        info)
            emoji="ℹ️"
            ;;
        *)
            emoji="📝"
            ;;
    esac

    local message="<b>${emoji} ${title}</b>

${body}

<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')"

    telegram_send "${message}" "HTML" "${PROJECT_DIR}/.env"
}

# ==================== Main ====================

# Command line usage
if [ $# -eq 0 ]; then
    cat << EOF
Usage: $0 <command> [arguments]

Commands:
  success <backup_dir> <size> <duration>  - Send backup success notification
  failure <error_message>                  - Send backup failure notification
  warning <warning_message>                - Send backup warning
  info <message>                           - Send info message
  custom <level> <title> <body>            - Send custom message
  test                                      - Test Telegram configuration

Examples:
  $0 success /path/to/backup 1.5GB 120
  $0 failure "Database connection failed"
  $0 warning "Disk space low"
  $0 info "Backup process started"
  $0 custom success "Title" "Body text"
  $0 test

Environment Variables:
  TELEGRAM_BOT_TOKEN  - Telegram bot token from @BotFather
  TELEGRAM_CHAT_ID    - Your Telegram chat ID
  TELEGRAM_CHAT_IDS   - Comma-separated chat IDs to notify (overrides TELEGRAM_CHAT_ID)

EOF
    exit 1
fi

command=$1
shift

case ${command} in
    success)
        if [ $# -lt 3 ]; then
            echo "ERROR: success command requires 3 arguments"
            exit 1
        fi
        send_backup_success "$1" "$2" "$3"
        ;;
    failure)
        if [ $# -lt 1 ]; then
            echo "ERROR: failure command requires 1 argument"
            exit 1
        fi
        send_backup_failure "$1"
        ;;
    warning)
        if [ $# -lt 1 ]; then
            echo "ERROR: warning command requires 1 argument"
            exit 1
        fi
        send_backup_warning "$1"
        ;;
    info)
        if [ $# -lt 1 ]; then
            echo "ERROR: info command requires 1 argument"
            exit 1
        fi
        send_info "$1"
        ;;
    custom)
        if [ $# -lt 3 ]; then
            echo "ERROR: custom command requires 3 arguments"
            exit 1
        fi
        send_custom "$1" "$2" "$3"
        ;;
    test)
        if check_telegram_config; then
            echo "Testing Telegram configuration..."
            if telegram_send "<b>🧪 Test Message</b>

This is a test message from LiteLLM backup system.

<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')

<i>If you received this, Telegram notifications are working correctly!</i>" "HTML" "${PROJECT_DIR}/.env"; then
                echo "✅ Telegram test successful!"
            else
                echo "❌ Telegram test failed"
                exit 1
            fi
        else
            echo "❌ Telegram not configured"
            exit 1
        fi
        ;;
    *)
        echo "ERROR: Unknown command '${command}'"
        exit 1
        ;;
esac
