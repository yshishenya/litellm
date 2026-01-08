#!/bin/bash
#
# Shared Telegram helpers for scripts/
#

telegram_load_env() {
    local env_path="${1:-}"
    if [ -z "${env_path}" ]; then
        if [ -n "${PROJECT_DIR:-}" ]; then
            env_path="${PROJECT_DIR}/.env"
        else
            return 0
        fi
    fi

    if [ -d "${env_path}" ]; then
        env_path="${env_path%/}/.env"
    fi

    if [ ! -f "${env_path}" ]; then
        return 0
    fi

    while IFS='=' read -r key value; do
        value=$(echo "${value}" | sed 's/#.*//' | sed 's/^"//' | sed 's/".*$//' | sed "s/^'//" | sed "s/'.*$//")
        export "${key}=${value}"
    done < <(grep -E '^TELEGRAM_[A-Z_]+=' "${env_path}")
}

telegram_is_configured() {
    [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_IDS:-${TELEGRAM_CHAT_ID:-}}" ]
}

telegram_send() {
    local message="$1"
    local parse_mode="${2:-HTML}"
    local env_path="${3:-}"

    if ! telegram_is_configured; then
        [ -n "${env_path}" ] && telegram_load_env "${env_path}"
    fi

    if ! telegram_is_configured; then
        return 1
    fi

    local api_url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    local ids_raw="${TELEGRAM_CHAT_IDS:-${TELEGRAM_CHAT_ID:-}}"
    ids_raw="${ids_raw// /,}"
    ids_raw=$(echo "${ids_raw}" | tr -s ',')

    local ok_count=0
    local total_count=0
    IFS=',' read -r -a chat_ids <<< "${ids_raw}"

    for chat_id in "${chat_ids[@]}"; do
        [ -z "${chat_id}" ] && continue
        total_count=$((total_count + 1))
        local response
        response=$(curl -sS -X POST "${api_url}" \
            --data-urlencode "chat_id=${chat_id}" \
            --data-urlencode "parse_mode=${parse_mode}" \
            --data-urlencode "text=${message}")

        if echo "${response}" | grep -q '"ok":true'; then
            ok_count=$((ok_count + 1))
        else
            echo "ERROR: Failed to send Telegram message to chat_id=${chat_id}" >&2
            echo "${response}" >&2
        fi
    done

    [ "${ok_count}" -gt 0 ]
}
