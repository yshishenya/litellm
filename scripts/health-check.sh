#!/bin/bash
#
# LiteLLM Health Check Script
# Проверяет все сервисы и отправляет уведомления при проблемах
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATUS_FILE="${PROJECT_DIR}/logs/.health_status"
COMMON_LIB="${SCRIPT_DIR}/lib/common.sh"
if [ -f "${COMMON_LIB}" ]; then
    source "${COMMON_LIB}"
else
    echo "ERROR: Missing ${COMMON_LIB}"
    exit 1
fi

TELEGRAM_LIB="${SCRIPT_DIR}/lib/telegram.sh"
if [ -f "${TELEGRAM_LIB}" ]; then
    source "${TELEGRAM_LIB}"
    telegram_load_env "${PROJECT_DIR}/.env"
else
    echo "ERROR: Missing ${TELEGRAM_LIB}"
    exit 1
fi

BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-/opt/backups/litellm}"

# Загрузить только необходимые переменные окружения
if [ -f "${PROJECT_DIR}/.env" ]; then
    export BACKUP_REMOTE_HOST=$(grep "^BACKUP_REMOTE_HOST" "${PROJECT_DIR}/.env" | cut -d'=' -f2- | sed 's/#.*//' | tr -d ' "')
    export BACKUP_REMOTE_USER=$(grep "^BACKUP_REMOTE_USER" "${PROJECT_DIR}/.env" | cut -d'=' -f2- | sed 's/#.*//' | tr -d ' "')
    export BACKUP_REMOTE_PATH=$(grep "^BACKUP_REMOTE_PATH" "${PROJECT_DIR}/.env" | cut -d'=' -f2- | sed 's/#.*//' | tr -d ' "')
    export BACKUP_REMOTE_PORT=$(grep "^BACKUP_REMOTE_PORT" "${PROJECT_DIR}/.env" | cut -d'=' -f2- | sed 's/#.*//' | tr -d ' "')
fi

# Счетчики
CHECKS_TOTAL=0
CHECKS_PASSED=0
CHECKS_FAILED=0
ERRORS=()
DISK_ROOT_USAGE="N/A"
DISK_DOCKER_USAGE="N/A"
MEM_USAGE="N/A"
BACKUP_AGE_HOURS="N/A"
SSL_SUMMARY=""

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    ERRORS+=("$1")
}

# Отправка в Telegram
send_telegram() {
    local message="$1"

    telegram_send "${message}" "HTML" "${PROJECT_DIR}/.env" &>/dev/null || true
}

check_requirements() {
    require_cmds docker curl openssl df free || exit 1
    if [ -n "${BACKUP_REMOTE_HOST:-}" ]; then
        require_cmds ssh || exit 1
    fi
}

# Получить предыдущий статус
get_previous_status() {
    if [ -f "$STATUS_FILE" ]; then
        cat "$STATUS_FILE"
    else
        echo "ok"
    fi
}

# Сохранить текущий статус
save_status() {
    local status="$1"
    mkdir -p "$(dirname "$STATUS_FILE")"
    echo "$status" > "$STATUS_FILE"
}

# Проверка Docker контейнеров
check_containers() {
    log_info "Проверка Docker контейнеров..."
    CHECKS_TOTAL=$((CHECKS_TOTAL + 6))

    if ! docker ps &>/dev/null; then
        log_error "Docker daemon не запущен"
        CHECKS_FAILED=$((CHECKS_FAILED + 6))
        ERRORS+=("Docker daemon не запущен")
        return
    fi

    local containers=(
        "litellm-litellm-1"
        "litellm_db"
        "litellm-redis-1"
        "litellm-prometheus-1"
        "litellm-grafana-1"
        "litellm-litellm-metrics-exporter-1"
    )

    for container in "${containers[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            # Проверяем наличие healthcheck
            local has_healthcheck=$(docker inspect --format='{{.State.Health}}' "${container}" 2>/dev/null)

            if [ "$has_healthcheck" == "<nil>" ] || [ -z "$has_healthcheck" ]; then
                # Нет healthcheck - проверяем просто что контейнер running
                local state=$(docker inspect --format='{{.State.Running}}' "${container}" 2>/dev/null)
                if [ "$state" == "true" ]; then
                    log_success "Контейнер ${container} работает"
                else
                    log_error "Контейнер ${container} не работает"
                fi
            else
                # Есть healthcheck - проверяем его статус
                local health_status=$(docker inspect --format='{{.State.Health.Status}}' "${container}" 2>/dev/null)
                if [ "$health_status" == "healthy" ]; then
                    log_success "Контейнер ${container} работает"
                else
                    log_error "Контейнер ${container} не здоров (status: ${health_status})"
                fi
            fi
        else
            log_error "Контейнер ${container} не запущен"
        fi
    done
}

# Проверка API endpoints
check_api_endpoints() {
    log_info "Проверка API endpoints..."
    CHECKS_TOTAL=$((CHECKS_TOTAL + 5))

    # LiteLLM API
    if curl -sf --max-time 5 http://localhost:4000/health/liveliness | grep -q "alive"; then
        log_success "LiteLLM API работает"
    else
        log_error "LiteLLM API не отвечает"
    fi

    # Grafana
    if curl -sf --max-time 5 http://localhost:3098/api/health &>/dev/null; then
        log_success "Grafana API работает"
    else
        log_error "Grafana API не отвечает"
    fi

    # Prometheus
    if curl -sf --max-time 5 http://localhost:9092/-/healthy &>/dev/null; then
        log_success "Prometheus работает"
    else
        log_error "Prometheus не отвечает"
    fi

    # Redis
    if docker exec litellm-redis-1 redis-cli ping 2>/dev/null | grep -q "PONG"; then
        log_success "Redis работает"
    else
        log_error "Redis не отвечает"
    fi

    # Metrics Exporter (порт 9090, не 9093!)
    # Временно отключаем pipefail для избежания ложных ошибок от SIGPIPE
    set +o pipefail
    if curl -sf --max-time 5 http://localhost:9090/metrics 2>/dev/null | head -100 | grep -q "litellm_spend"; then
        log_success "Metrics Exporter работает"
    else
        log_error "Metrics Exporter не отвечает"
    fi
    set -o pipefail
}

# Проверка базы данных
check_database() {
    log_info "Проверка PostgreSQL..."
    CHECKS_TOTAL=$((CHECKS_TOTAL + 2))

    # Подключение к БД
    if docker exec litellm_db pg_isready -U llmproxy -d litellm &>/dev/null; then
        log_success "PostgreSQL доступна"
    else
        log_error "PostgreSQL недоступна"
        return
    fi

    # Проверка количества записей
    local count=$(docker exec litellm_db psql -U llmproxy -d litellm -t -c 'SELECT COUNT(*) FROM "LiteLLM_SpendLogs"' 2>/dev/null | xargs)

    if [ -n "$count" ] && [ "$count" -gt 0 ]; then
        log_success "База данных содержит ${count} записей"
    else
        log_error "Проблема с данными в базе"
    fi
}

# Проверка дискового пространства
check_disk_space() {
    log_info "Проверка дискового пространства..."
    CHECKS_TOTAL=$((CHECKS_TOTAL + 2))

    # Корневой раздел
    local root_usage=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
    DISK_ROOT_USAGE="${root_usage}%"
    if [ "$root_usage" -lt 80 ]; then
        log_success "Диск /: ${root_usage}% использовано"
    elif [ "$root_usage" -lt 90 ]; then
        log_warning "Диск /: ${root_usage}% использовано (предупреждение)"
    else
        log_error "Диск /: ${root_usage}% использовано (критично!)"
    fi

    # Docker volumes
    local docker_usage=$(df /var/lib/docker | awk 'NR==2 {print $5}' | sed 's/%//' || echo "0")
    DISK_DOCKER_USAGE="${docker_usage}%"
    if [ "$docker_usage" -lt 80 ]; then
        log_success "Docker volumes: ${docker_usage}% использовано"
    elif [ "$docker_usage" -lt 90 ]; then
        log_warning "Docker volumes: ${docker_usage}% использовано (предупреждение)"
    else
        log_error "Docker volumes: ${docker_usage}% использовано (критично!)"
    fi
}

# Проверка памяти
check_memory() {
    log_info "Проверка памяти..."
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))

    local mem_usage=$(free | awk 'NR==2 {printf "%.0f", $3/$2 * 100}')
    MEM_USAGE="${mem_usage}%"

    if [ "$mem_usage" -lt 80 ]; then
        log_success "RAM: ${mem_usage}% использовано"
    elif [ "$mem_usage" -lt 90 ]; then
        log_warning "RAM: ${mem_usage}% использовано (предупреждение)"
    else
        log_error "RAM: ${mem_usage}% использовано (критично!)"
    fi
}

# Проверка SSL сертификатов
check_ssl_certificates() {
    log_info "Проверка SSL сертификатов..."
    CHECKS_TOTAL=$((CHECKS_TOTAL + 2))

    local domains=("litellm.pro-4.ru" "dash.pro-4.ru")

    SSL_SUMMARY=""
    for domain in "${domains[@]}"; do
        local openssl_cmd="echo | openssl s_client -servername \"${domain}\" -connect \"${domain}:443\" 2>/dev/null"
        local expiry=""

        if command -v timeout &> /dev/null; then
            expiry=$(timeout 5 bash -c "${openssl_cmd}" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
        else
            expiry=$(bash -c "${openssl_cmd}" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
        fi

        if [ -n "$expiry" ]; then
            local expiry_epoch=$(date -d "$expiry" +%s)
            local now_epoch=$(date +%s)
            local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
            SSL_SUMMARY+="${domain}: ${days_left}d"$'\n'

            if [ "$days_left" -gt 30 ]; then
                log_success "SSL ${domain}: ${days_left} дней до истечения"
            elif [ "$days_left" -gt 7 ]; then
                log_warning "SSL ${domain}: ${days_left} дней до истечения"
            else
                log_error "SSL ${domain}: ${days_left} дней до истечения (критично!)"
            fi
        else
            log_error "SSL ${domain}: не удалось проверить сертификат"
            SSL_SUMMARY+="${domain}: error"$'\n'
        fi
    done

    SSL_SUMMARY="${SSL_SUMMARY%$'\n'}"
}

# Проверка бэкапов
check_backups() {
    log_info "Проверка бэкапов..."
    CHECKS_TOTAL=$((CHECKS_TOTAL + 2))

    # Последний локальный бэкап
    if [ -L "${BACKUP_BASE_DIR}/latest" ]; then
        local backup_age=$(( ($(date +%s) - $(stat -c %Y "${BACKUP_BASE_DIR}/latest")) / 3600 ))
        BACKUP_AGE_HOURS="${backup_age}"

        if [ "$backup_age" -lt 30 ]; then
            log_success "Последний бэкап: ${backup_age} часов назад"
        else
            log_error "Последний бэкап: ${backup_age} часов назад (устарел!)"
        fi
    else
        log_error "Бэкап не найден"
    fi

    # Проверка офсайт бэкапа (если настроен)
    if [ -n "${BACKUP_REMOTE_HOST:-}" ]; then
        local remote_port="${BACKUP_REMOTE_PORT:-22}"
        if ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 -p "${remote_port}" \
            "${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}" "test -L ${BACKUP_REMOTE_PATH}/latest" 2>/dev/null; then
            log_success "Офсайт бэкап доступен"
        else
            log_error "Офсайт бэкап недоступен"
        fi
    else
        log_warning "Офсайт бэкап не настроен"
    fi
}

# Проверка Nginx
check_nginx() {
    log_info "Проверка Nginx..."
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))

    if systemctl is-active --quiet nginx; then
        log_success "Nginx работает"
    else
        log_error "Nginx не запущен"
    fi
}

# Основная функция
main() {
    echo ""
    log_info "════════════════════════════════════════════"
    log_info "  LiteLLM Health Check"
    log_info "  $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "════════════════════════════════════════════"
    echo ""

    check_requirements

    # Запуск проверок
    check_containers
    echo ""
    check_api_endpoints
    echo ""
    check_database
    echo ""
    check_disk_space
    echo ""
    check_memory
    echo ""
    check_ssl_certificates
    echo ""
    check_backups
    echo ""
    check_nginx

    # Итоги
    echo ""
    log_info "════════════════════════════════════════════"
    log_info "  Итоги проверки"
    log_info "════════════════════════════════════════════"
    echo -e "${GREEN}Пройдено:${NC} ${CHECKS_PASSED}/${CHECKS_TOTAL}"
    echo -e "${RED}Провалено:${NC} ${CHECKS_FAILED}/${CHECKS_TOTAL}"
    echo ""

    # Получаем предыдущий статус
    local previous_status=$(get_previous_status)

    # Отправка уведомления при проблемах
    if [ ${CHECKS_FAILED} -gt 0 ]; then
        local message="🚨 <b>LiteLLM Health Check FAILED</b>"
        message+=$'\n\n'
        message+="Сервер: $(hostname)"
        message+=$'\n'
        message+="Время: $(date '+%Y-%m-%d %H:%M:%S')"
        message+=$'\n'
        message+="Пройдено: ${CHECKS_PASSED}/${CHECKS_TOTAL}"
        message+=$'\n'
        message+="Провалено: ${CHECKS_FAILED}"
        message+=$'\n\n'
        message+="Сводка:"
        message+=$'\n'
        message+="Диск /: ${DISK_ROOT_USAGE}, Docker: ${DISK_DOCKER_USAGE}"
        message+=$'\n'
        message+="RAM: ${MEM_USAGE}"
        message+=$'\n'
        message+="Бэкап: ${BACKUP_AGE_HOURS} ч назад"
        message+=$'\n'
        message+="SSL:"
        message+=$'\n'
        message+="${SSL_SUMMARY}"
        message+=$'\n\n'
        message+="<b>Ошибки:</b>"
        message+=$'\n'

        for error in "${ERRORS[@]}"; do
            message+="• ${error}"
            message+=$'\n'
        done

        send_telegram "$message"
        save_status "failed"

        log_error "Проверка завершена с ошибками!"
        exit 1
    else
        echo -e "${GREEN}[✓]${NC} Все проверки пройдены!"

        # Уведомление о восстановлении (если предыдущий статус был failed)
        if [ "$previous_status" == "failed" ]; then
            local message="✅ <b>LiteLLM RECOVERED</b>"
            message+=$'\n\n'
            message+="Сервер: $(hostname)"
            message+=$'\n'
            message+="Время: $(date '+%Y-%m-%d %H:%M:%S')"
            message+=$'\n'
            message+="Все проверки пройдены: ${CHECKS_PASSED}/${CHECKS_TOTAL}"
            message+=$'\n'
            message+="Диск /: ${DISK_ROOT_USAGE}, Docker: ${DISK_DOCKER_USAGE}"
            message+=$'\n'
            message+="RAM: ${MEM_USAGE}"
            message+=$'\n'
            message+="Бэкап: ${BACKUP_AGE_HOURS} ч назад"
            message+=$'\n'
            message+="SSL:"
            message+=$'\n'
            message+="${SSL_SUMMARY}"
            message+=$'\n\n'
            message+="Проблема устранена!"

            send_telegram "$message"
            log_info "Отправлено уведомление о восстановлении"
        fi

        save_status "ok"

        # Отправляем успешное уведомление раз в день (только в 03:00)
        if [ "$(date +%H:%M)" == "03:00" ]; then
            local message="✅ <b>LiteLLM Health Check OK</b>"
            message+=$'\n\n'
            message+="Сервер: $(hostname)"
            message+=$'\n'
            message+="Время: $(date '+%Y-%m-%d %H:%M:%S')"
            message+=$'\n'
            message+="Все проверки пройдены: ${CHECKS_PASSED}/${CHECKS_TOTAL}"
            message+=$'\n'
            message+="Диск /: ${DISK_ROOT_USAGE}, Docker: ${DISK_DOCKER_USAGE}"
            message+=$'\n'
            message+="RAM: ${MEM_USAGE}"
            message+=$'\n'
            message+="Бэкап: ${BACKUP_AGE_HOURS} ч назад"
            message+=$'\n'
            message+="SSL:"
            message+=$'\n'
            message+="${SSL_SUMMARY}"

            send_telegram "$message"
        fi

        exit 0
    fi
}

# Запуск
main "$@"
