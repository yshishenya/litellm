#!/bin/bash
#
# Telegram Notification Script for LiteLLM
# Sends backup status notifications via Telegram Bot
#

set -euo pipefail

# ==================== Configuration ====================

# Load from environment or .env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source .env if exists
if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a
    source "${PROJECT_DIR}/.env" 2>/dev/null || true
    set +a
fi

# Telegram configuration
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# ==================== Functions ====================

# Check if Telegram is configured
check_telegram_config() {
    if [ -z "${TELEGRAM_BOT_TOKEN}" ] || [ -z "${TELEGRAM_CHAT_ID}" ]; then
        echo "WARNING: Telegram not configured. Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in .env"
        return 1
    fi
    return 0
}

# Send message to Telegram
send_telegram_message() {
    local message=$1
    local parse_mode="${2:-HTML}"

    if ! check_telegram_config; then
        return 1
    fi

    local api_url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

    local response=$(curl -s -X POST "${api_url}" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode="${parse_mode}" \
        -d text="${message}")

    if echo "${response}" | grep -q '"ok":true'; then
        return 0
    else
        echo "ERROR: Failed to send Telegram message"
        echo "${response}"
        return 1
    fi
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

    send_telegram_message "${message}"
}

# Send backup failure notification
send_backup_failure() {
    local error_msg=$1

    local message="<b>❌ Backup Failed</b>

<b>Error:</b> ${error_msg}
<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')

<i>LiteLLM backup failed. Please check logs.</i>"

    send_telegram_message "${message}"
}

# Send backup warning
send_backup_warning() {
    local warning_msg=$1

    local message="<b>⚠️ Backup Warning</b>

<b>Warning:</b> ${warning_msg}
<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')

<i>Please review the backup process.</i>"

    send_telegram_message "${message}"
}

# Send info message
send_info() {
    local info_msg=$1

    local message="<b>ℹ️ Info</b>

${info_msg}

<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')"

    send_telegram_message "${message}"
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

    send_telegram_message "${message}"
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
            if send_telegram_message "<b>🧪 Test Message</b>

This is a test message from LiteLLM backup system.

<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')

<i>If you received this, Telegram notifications are working correctly!</i>"; then
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
