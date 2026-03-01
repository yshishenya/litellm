#!/bin/bash
#
# Shared notification helpers for scripts/
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
    done < <(grep -E '^(TELEGRAM_|OPENCLAW_HOOK_)[A-Z0-9_]+=' "${env_path}")
}

telegram_is_configured() {
    [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_IDS:-${TELEGRAM_CHAT_ID:-}}" ]
}

openclaw_hook_is_configured() {
    [ -n "${OPENCLAW_HOOK_URL:-}" ] && [ -n "${OPENCLAW_HOOK_TOKEN:-}" ]
}

openclaw_hook_send() {
    local message="$1"
    local name="${2:-LiteLLM Alert}"
    local env_path="${3:-}"

    if ! openclaw_hook_is_configured; then
        [ -n "${env_path}" ] && telegram_load_env "${env_path}"
    fi

    if ! openclaw_hook_is_configured; then
        return 2
    fi

    local to="${OPENCLAW_HOOK_TO:-}"
    local channel="${OPENCLAW_HOOK_CHANNEL:-telegram}"
    local agent_id="${OPENCLAW_HOOK_AGENT_ID:-main}"
    local thinking="${OPENCLAW_HOOK_THINKING:-off}"

    local payload
    if [ -n "${to}" ]; then
        payload=$(jq -nc \
          --arg message "${message}" \
          --arg name "${name}" \
          --arg agentId "${agent_id}" \
          --arg channel "${channel}" \
          --arg to "${to}" \
          --arg thinking "${thinking}" \
          '{message:$message,name:$name,agentId:$agentId,wakeMode:"now",deliver:true,channel:$channel,to:$to,thinking:$thinking}')
    else
        payload=$(jq -nc \
          --arg message "${message}" \
          --arg name "${name}" \
          --arg agentId "${agent_id}" \
          --arg thinking "${thinking}" \
          '{message:$message,name:$name,agentId:$agentId,wakeMode:"now",deliver:true,thinking:$thinking}')
    fi

    local http_code
    http_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${OPENCLAW_HOOK_URL%/}/hooks/agent" \
      -H "Authorization: Bearer ${OPENCLAW_HOOK_TOKEN}" \
      -H 'Content-Type: application/json' \
      -d "${payload}") || return 1

    [[ "${http_code}" =~ ^2 ]] || return 1
    return 0
}

telegram_send() {
    local message="$1"
    local parse_mode="${2:-HTML}"
    local env_path="${3:-}"

    if ! telegram_is_configured; then
        [ -n "${env_path}" ] && telegram_load_env "${env_path}"
    fi

    local telegram_ok=0

    if telegram_is_configured; then
        local api_url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
        local ids_raw="${TELEGRAM_CHAT_IDS:-${TELEGRAM_CHAT_ID:-}}"
        local telegram_thread_id="${TELEGRAM_MESSAGE_THREAD_ID:-${TELEGRAM_CHAT_TOPIC_ID:-}}"
        ids_raw="${ids_raw// /,}"
        ids_raw=$(echo "${ids_raw}" | tr -s ',')

        local ok_count=0
        IFS=',' read -r -a chat_ids <<< "${ids_raw}"

        for chat_id in "${chat_ids[@]}"; do
            [ -z "${chat_id}" ] && continue
            local response
            if [ -n "${telegram_thread_id}" ]; then
                response=$(curl -sS -X POST "${api_url}" \
                    --data-urlencode "chat_id=${chat_id}" \
                    --data-urlencode "message_thread_id=${telegram_thread_id}" \
                    --data-urlencode "parse_mode=${parse_mode}" \
                    --data-urlencode "text=${message}")
            else
                response=$(curl -sS -X POST "${api_url}" \
                    --data-urlencode "chat_id=${chat_id}" \
                    --data-urlencode "parse_mode=${parse_mode}" \
                    --data-urlencode "text=${message}")
            fi

            if echo "${response}" | grep -q '"ok":true'; then
                ok_count=$((ok_count + 1))
            else
                echo "ERROR: Failed to send Telegram message to chat_id=${chat_id}" >&2
                echo "${response}" >&2
            fi
        done

        if [ "${ok_count}" -gt 0 ]; then
            telegram_ok=1
        fi
    fi

    local hook_ok=0
    local plain_message
    plain_message=$(echo "${message}" | sed -E 's/<[^>]+>//g')
    if openclaw_hook_send "${plain_message}" "LiteLLM alert" "${env_path}"; then
        hook_ok=1
    fi

    [ "${telegram_ok}" -eq 1 ] || [ "${hook_ok}" -eq 1 ]
}
