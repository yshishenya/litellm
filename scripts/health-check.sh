#!/bin/bash
#
# LiteLLM Health Check Script
# Проверяет все сервисы и отправляет уведомления при проблемах
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Загрузить только необходимые переменные окружения
if [ -f "${PROJECT_DIR}/.env" ]; then
    # Загрузить только TELEGRAM переменные, игнорируя пробелы и комментарии
    export TELEGRAM_BOT_TOKEN=$(grep "^TELEGRAM_BOT_TOKEN" "${PROJECT_DIR}/.env" | cut -d'=' -f2- | sed 's/#.*//' | tr -d ' "')
    export TELEGRAM_CHAT_ID=$(grep "^TELEGRAM_CHAT_ID" "${PROJECT_DIR}/.env" | cut -d'=' -f2- | sed 's/#.*//' | tr -d ' "')
    export BACKUP_REMOTE_HOST=$(grep "^BACKUP_REMOTE_HOST" "${PROJECT_DIR}/.env" | cut -d'=' -f2- | sed 's/#.*//' | tr -d ' "')
    export BACKUP_REMOTE_USER=$(grep "^BACKUP_REMOTE_USER" "${PROJECT_DIR}/.env" | cut -d'=' -f2- | sed 's/#.*//' | tr -d ' "')
    export BACKUP_REMOTE_PATH=$(grep "^BACKUP_REMOTE_PATH" "${PROJECT_DIR}/.env" | cut -d'=' -f2- | sed 's/#.*//' | tr -d ' "')
fi

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Счетчики
CHECKS_TOTAL=0
CHECKS_PASSED=0
CHECKS_FAILED=0
ERRORS=()

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    ERRORS+=("$1")
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Отправка в Telegram
send_telegram() {
    local message="$1"

    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="${message}" \
            -d parse_mode="HTML" &>/dev/null || true
    fi
}

# Проверка Docker контейнеров
check_containers() {
    log_info "Проверка Docker контейнеров..."
    CHECKS_TOTAL=$((CHECKS_TOTAL + 6))

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
    if [ "$root_usage" -lt 80 ]; then
        log_success "Диск /: ${root_usage}% использовано"
    elif [ "$root_usage" -lt 90 ]; then
        log_warning "Диск /: ${root_usage}% использовано (предупреждение)"
    else
        log_error "Диск /: ${root_usage}% использовано (критично!)"
    fi

    # Docker volumes
    local docker_usage=$(df /var/lib/docker | awk 'NR==2 {print $5}' | sed 's/%//' || echo "0")
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

    for domain in "${domains[@]}"; do
        local expiry=$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null | \
            openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

        if [ -n "$expiry" ]; then
            local expiry_epoch=$(date -d "$expiry" +%s)
            local now_epoch=$(date +%s)
            local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

            if [ "$days_left" -gt 30 ]; then
                log_success "SSL ${domain}: ${days_left} дней до истечения"
            elif [ "$days_left" -gt 7 ]; then
                log_warning "SSL ${domain}: ${days_left} дней до истечения"
            else
                log_error "SSL ${domain}: ${days_left} дней до истечения (критично!)"
            fi
        else
            log_error "SSL ${domain}: не удалось проверить сертификат"
        fi
    done
}

# Проверка бэкапов
check_backups() {
    log_info "Проверка бэкапов..."
    CHECKS_TOTAL=$((CHECKS_TOTAL + 2))

    # Последний локальный бэкап
    if [ -L "${PROJECT_DIR}/backups/latest" ]; then
        local backup_age=$(( ($(date +%s) - $(stat -c %Y "${PROJECT_DIR}/backups/latest")) / 3600 ))

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
        if ssh -o ConnectTimeout=5 "${BACKUP_REMOTE_USER}@${BACKUP_REMOTE_HOST}" "test -L ${BACKUP_REMOTE_PATH}/latest" 2>/dev/null; then
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

    # Отправка уведомления при проблемах
    if [ ${CHECKS_FAILED} -gt 0 ]; then
        local message="🚨 <b>LiteLLM Health Check FAILED</b>%0A%0A"
        message+="Сервер: $(hostname)%0A"
        message+="Время: $(date '+%Y-%m-%d %H:%M:%S')%0A"
        message+="Пройдено: ${CHECKS_PASSED}/${CHECKS_TOTAL}%0A"
        message+="Провалено: ${CHECKS_FAILED}%0A%0A"
        message+="<b>Ошибки:</b>%0A"

        for error in "${ERRORS[@]}"; do
            message+="• ${error}%0A"
        done

        send_telegram "$message"

        log_error "Проверка завершена с ошибками!"
        exit 1
    else
        log_success "Все проверки пройдены!"

        # Отправляем успешное уведомление раз в день (только в 03:00)
        if [ "$(date +%H:%M)" == "03:00" ]; then
            local message="✅ <b>LiteLLM Health Check OK</b>%0A%0A"
            message+="Сервер: $(hostname)%0A"
            message+="Время: $(date '+%Y-%m-%d %H:%M:%S')%0A"
            message+="Все проверки пройдены: ${CHECKS_PASSED}/${CHECKS_TOTAL}"

            send_telegram "$message"
        fi

        exit 0
    fi
}

# Запуск
main "$@"
