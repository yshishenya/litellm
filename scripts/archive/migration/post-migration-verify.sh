#!/bin/bash

#############################################################################
# Post-Migration Verification Script
# Проверяет работоспособность всех сервисов после миграции
#############################################################################

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Конфигурация
DOMAINS=("litellm.pro-4.ru" "dash.pro-4.ru")
LITELLM_DOMAIN="litellm.pro-4.ru"
GRAFANA_DOMAIN="dash.pro-4.ru"

# Счетчики
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNING=0

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    CHECKS_WARNING=$((CHECKS_WARNING + 1))
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
}

log_step() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN} $1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

echo "======================================================================"
echo "  Post-Migration Verification"
echo "  Проверка работоспособности после миграции"
echo "======================================================================"
echo ""

#############################################################################
# 1. Проверка Docker контейнеров
#############################################################################

log_step "1. Проверка Docker контейнеров"

log_info "Проверка запущенных контейнеров..."
EXPECTED_CONTAINERS=6
RUNNING_CONTAINERS=$(docker ps --filter "name=litellm" --format "{{.Names}}" | wc -l)

if [ "$RUNNING_CONTAINERS" -eq "$EXPECTED_CONTAINERS" ]; then
    log_success "Все контейнеры запущены ($RUNNING_CONTAINERS/$EXPECTED_CONTAINERS)"
    docker ps --filter "name=litellm" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
else
    log_error "Запущено только $RUNNING_CONTAINERS из $EXPECTED_CONTAINERS контейнеров"
    docker ps --filter "name=litellm" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
fi

# Проверка здоровья контейнеров
log_info "Проверка состояния health check..."
UNHEALTHY=$(docker ps --filter "name=litellm" --filter "health=unhealthy" --format "{{.Names}}" | wc -l)
if [ "$UNHEALTHY" -eq 0 ]; then
    log_success "Все контейнеры здоровы"
else
    log_warning "Обнаружены нездоровые контейнеры: $UNHEALTHY"
    docker ps --filter "name=litellm" --filter "health=unhealthy" --format "table {{.Names}}\t{{.Status}}"
fi

#############################################################################
# 2. Проверка локальных портов
#############################################################################

log_step "2. Проверка локальных портов"

PORTS=("4000:LiteLLM Proxy" "5433:PostgreSQL" "6381:Redis" "9092:Prometheus" "3098:Grafana" "9090:Metrics Exporter")

for port_info in "${PORTS[@]}"; do
    PORT="${port_info%%:*}"
    NAME="${port_info##*:}"

    log_info "Проверка порта $PORT ($NAME)..."
    if nc -z localhost "$PORT" 2>/dev/null; then
        log_success "Порт $PORT ($NAME) доступен"
    else
        log_error "Порт $PORT ($NAME) недоступен"
    fi
done

#############################################################################
# 3. Проверка LiteLLM Proxy API
#############################################################################

log_step "3. Проверка LiteLLM Proxy API"

# Health check
log_info "Проверка health endpoint..."
if curl -sf http://localhost:4000/health/liveliness | grep -q "I'm alive"; then
    log_success "LiteLLM health check пройден"
else
    log_error "LiteLLM health check провалился"
fi

# Readiness check
log_info "Проверка readiness endpoint..."
if curl -sf http://localhost:4000/health/readiness &>/dev/null; then
    log_success "LiteLLM readiness check пройден"
else
    log_warning "LiteLLM readiness check провалился"
fi

# Models endpoint
log_info "Проверка models endpoint..."
if curl -sf http://localhost:4000/v1/models &>/dev/null; then
    MODEL_COUNT=$(curl -s http://localhost:4000/v1/models | grep -o '"id"' | wc -l)
    log_success "Models endpoint работает, доступно моделей: $MODEL_COUNT"
else
    log_error "Models endpoint недоступен"
fi

#############################################################################
# 4. Проверка PostgreSQL
#############################################################################

log_step "4. Проверка PostgreSQL"

log_info "Проверка подключения к PostgreSQL..."
if PGPASSWORD=dbpassword9090 psql -h localhost -p 5433 -U llmproxy -d litellm -c "SELECT 1" &>/dev/null; then
    log_success "PostgreSQL доступна"
else
    log_error "PostgreSQL недоступна"
fi

log_info "Проверка данных в базе..."
SPEND_COUNT=$(PGPASSWORD=dbpassword9090 psql -h localhost -p 5433 -U llmproxy -d litellm -t -c "SELECT COUNT(*) FROM \"LiteLLM_SpendLogs\"" 2>/dev/null | tr -d ' ')
if [ -n "$SPEND_COUNT" ] && [ "$SPEND_COUNT" -gt 0 ]; then
    log_success "Записей в LiteLLM_SpendLogs: $SPEND_COUNT"
else
    log_warning "LiteLLM_SpendLogs пуста или недоступна"
fi

USER_COUNT=$(PGPASSWORD=dbpassword9090 psql -h localhost -p 5433 -U llmproxy -d litellm -t -c "SELECT COUNT(*) FROM \"LiteLLM_UserTable\"" 2>/dev/null | tr -d ' ')
if [ -n "$USER_COUNT" ]; then
    log_success "Пользователей в системе: $USER_COUNT"
fi

TEAM_COUNT=$(PGPASSWORD=dbpassword9090 psql -h localhost -p 5433 -U llmproxy -d litellm -t -c "SELECT COUNT(*) FROM \"LiteLLM_TeamTable\"" 2>/dev/null | tr -d ' ')
if [ -n "$TEAM_COUNT" ]; then
    log_success "Команд в системе: $TEAM_COUNT"
fi

#############################################################################
# 5. Проверка Redis
#############################################################################

log_step "5. Проверка Redis"

log_info "Проверка Redis..."
if docker exec $(docker ps -qf "name=redis") redis-cli ping 2>/dev/null | grep -q "PONG"; then
    log_success "Redis работает"

    # Проверка ключей
    KEY_COUNT=$(docker exec $(docker ps -qf "name=redis") redis-cli DBSIZE 2>/dev/null | grep -o '[0-9]*')
    if [ -n "$KEY_COUNT" ]; then
        log_success "Ключей в Redis: $KEY_COUNT"
    fi
else
    log_error "Redis недоступен"
fi

#############################################################################
# 6. Проверка Prometheus
#############################################################################

log_step "6. Проверка Prometheus"

log_info "Проверка Prometheus health..."
if curl -sf http://localhost:9092/-/healthy | grep -q "Prometheus"; then
    log_success "Prometheus работает"
else
    log_error "Prometheus недоступен"
fi

log_info "Проверка targets в Prometheus..."
if curl -sf http://localhost:9092/api/v1/targets 2>/dev/null | grep -q "litellm-unified-metrics"; then
    log_success "Prometheus target 'litellm-unified-metrics' активен"
else
    log_warning "Prometheus target 'litellm-unified-metrics' не найден"
fi

log_info "Проверка метрик в Prometheus..."
if curl -sf "http://localhost:9092/api/v1/query?query=litellm_team_spend" 2>/dev/null | grep -q "success"; then
    log_success "Метрики litellm_team_spend доступны"
else
    log_warning "Метрики litellm_team_spend не найдены (может потребоваться время)"
fi

#############################################################################
# 7. Проверка Grafana
#############################################################################

log_step "7. Проверка Grafana"

log_info "Проверка Grafana API..."
if curl -sf http://localhost:3098/api/health | grep -q "ok"; then
    log_success "Grafana API работает"
else
    log_error "Grafana API недоступен"
fi

log_info "Проверка Grafana datasources..."
DATASOURCES=$(curl -sf -u admin:admin123 http://localhost:3098/api/datasources 2>/dev/null | grep -o '"name"' | wc -l)
if [ "$DATASOURCES" -ge 2 ]; then
    log_success "Datasources настроены: $DATASOURCES"
else
    log_warning "Datasources не найдены или не полностью настроены"
fi

log_info "Проверка Grafana dashboards..."
DASHBOARDS=$(curl -sf -u admin:admin123 http://localhost:3098/api/search?type=dash-db 2>/dev/null | grep -o '"id"' | wc -l)
if [ "$DASHBOARDS" -ge 4 ]; then
    log_success "Dashboards загружены: $DASHBOARDS"
else
    log_warning "Найдено только $DASHBOARDS dashboards (ожидалось 4+)"
fi

#############################################################################
# 8. Проверка Metrics Exporter
#############################################################################

log_step "8. Проверка Metrics Exporter"

log_info "Проверка Metrics Exporter..."
if curl -sf http://localhost:9090/metrics | grep -q "litellm_team_spend"; then
    log_success "Metrics Exporter работает и экспортирует метрики"

    # Подсчет метрик
    METRICS_COUNT=$(curl -s http://localhost:9090/metrics | grep "^litellm_" | wc -l)
    log_success "Экспортируемых метрик: $METRICS_COUNT"
else
    log_error "Metrics Exporter не работает или не экспортирует метрики"
fi

#############################################################################
# 9. Проверка DNS и доменов
#############################################################################

log_step "9. Проверка DNS и доменов"

for domain in "${DOMAINS[@]}"; do
    log_info "Проверка DNS для $domain..."

    # Проверка DNS резолвинга
    RESOLVED_IP=$(nslookup "$domain" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -1)
    if [ -n "$RESOLVED_IP" ]; then
        log_success "DNS резолвится: $domain → $RESOLVED_IP"

        # Проверка, что IP указывает на текущий сервер
        CURRENT_IP=$(hostname -I | awk '{print $1}')
        if [ "$RESOLVED_IP" = "$CURRENT_IP" ] || [ "$RESOLVED_IP" = "65.21.202.252" ]; then
            log_success "DNS указывает на текущий сервер"
        else
            log_warning "DNS указывает на другой IP: $RESOLVED_IP (текущий: $CURRENT_IP)"
        fi
    else
        log_warning "Не удалось резолвить DNS для $domain"
    fi
done

# Проверка доступности через домен (если DNS настроен)
log_info "Проверка доступности LiteLLM через домен..."
if curl -sf "http://${LITELLM_DOMAIN}:4000/health/liveliness" 2>/dev/null | grep -q "I'm alive"; then
    log_success "LiteLLM доступен через домен $LITELLM_DOMAIN"
elif curl -sf "https://${LITELLM_DOMAIN}/health/liveliness" 2>/dev/null | grep -q "I'm alive"; then
    log_success "LiteLLM доступен через HTTPS домен $LITELLM_DOMAIN"
else
    log_warning "LiteLLM недоступен через домен (DNS может еще распространяться)"
fi

log_info "Проверка доступности Grafana через домен..."
if curl -sf "http://${GRAFANA_DOMAIN}:3098/api/health" 2>/dev/null | grep -q "ok"; then
    log_success "Grafana доступен через домен $GRAFANA_DOMAIN"
elif curl -sf "https://${GRAFANA_DOMAIN}/api/health" 2>/dev/null | grep -q "ok"; then
    log_success "Grafana доступен через HTTPS домен $GRAFANA_DOMAIN"
else
    log_warning "Grafana недоступен через домен (DNS может еще распространяться)"
fi

#############################################################################
# 10. Проверка автоматических бэкапов
#############################################################################

log_step "10. Проверка автоматических бэкапов"

log_info "Проверка скриптов бэкапов..."
if [ -f "./scripts/backup.sh" ] && [ -x "./scripts/backup.sh" ]; then
    log_success "Скрипт backup.sh найден и исполняемый"
else
    log_warning "Скрипт backup.sh не найден или не исполняемый"
fi

log_info "Проверка cron задач..."
if crontab -l 2>/dev/null | grep -q "backup.sh"; then
    CRON_SCHEDULE=$(crontab -l | grep "backup.sh" | grep -v "^#")
    log_success "Cron задача для бэкапов найдена:"
    echo "   $CRON_SCHEDULE"
else
    log_warning "Cron задача для бэкапов не настроена"
    log_info "Настройте: ./scripts/setup-cron.sh"
fi

#############################################################################
# 11. Проверка логов на ошибки
#############################################################################

log_step "11. Проверка логов на ошибки"

log_info "Проверка логов контейнеров на критические ошибки..."

for container in $(docker ps --filter "name=litellm" --format "{{.Names}}"); do
    ERROR_COUNT=$(docker logs "$container" --since 10m 2>&1 | grep -i "error\|critical\|fatal" | wc -l)
    if [ "$ERROR_COUNT" -eq 0 ]; then
        log_success "Контейнер $container: ошибок не найдено"
    else
        log_warning "Контейнер $container: найдено $ERROR_COUNT ошибок за последние 10 минут"
        log_info "Проверьте: docker logs $container"
    fi
done

#############################################################################
# 12. Проверка использования ресурсов
#############################################################################

log_step "12. Проверка использования ресурсов"

log_info "Использование дискового пространства..."
DISK_USAGE=$(df -h / | tail -1 | awk '{print $5}')
DISK_AVAIL=$(df -h / | tail -1 | awk '{print $4}')
log_success "Диск: использовано $DISK_USAGE, доступно $DISK_AVAIL"

log_info "Использование памяти контейнерами..."
docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}" \
    $(docker ps --filter "name=litellm" --format "{{.Names}}")

#############################################################################
# Итоговый отчет
#############################################################################

echo ""
echo "======================================================================"
echo "  ИТОГОВЫЙ ОТЧЕТ ВЕРИФИКАЦИИ"
echo "======================================================================"
echo ""
echo -e "${GREEN}Успешных проверок:${NC} $CHECKS_PASSED"
echo -e "${YELLOW}Предупреждений:${NC} $CHECKS_WARNING"
echo -e "${RED}Неудачных проверок:${NC} $CHECKS_FAILED"
echo ""

if [ $CHECKS_FAILED -eq 0 ] && [ $CHECKS_WARNING -eq 0 ]; then
    echo -e "${GREEN}✓ МИГРАЦИЯ ПОЛНОСТЬЮ УСПЕШНА!${NC}"
    echo ""
    echo "Все системы работают нормально. Можно:"
    echo "1. Мониторить систему в течение 24-48 часов"
    echo "2. Остановить старый сервер через 48 часов"
    echo "3. Удалить старые данные после подтверждения стабильности"
    exit 0
elif [ $CHECKS_FAILED -eq 0 ]; then
    echo -e "${YELLOW}⚠ Миграция успешна, но есть предупреждения${NC}"
    echo ""
    echo "Основные системы работают, но рекомендуется:"
    echo "1. Проверить предупреждения выше"
    echo "2. Настроить отсутствующие компоненты"
    echo "3. Продолжить мониторинг"
    exit 0
else
    echo -e "${RED}✗ Обнаружены критические проблемы!${NC}"
    echo ""
    echo "Рекомендуется:"
    echo "1. Изучить ошибки выше"
    echo "2. Проверить логи: docker compose logs"
    echo "3. При необходимости выполнить rollback (см. ROLLBACK_PLAN.md)"
    exit 1
fi
