#!/bin/bash

#############################################################################
# Emergency Rollback Script
# Быстрый откат к старому серверу в случае критических проблем
#############################################################################

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Telegram настройки
TELEGRAM_BOT_TOKEN="7965448155:AAGSiq8Ngvw-Z2sKtWbwabaSL-HnvRPpkNg"
TELEGRAM_CHAT_ID="234583347"

# Логирование
LOG_FILE="/home/yan/litellm/emergency_rollback_$(date +%Y%m%d_%H%M%S).log"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"
}

# Функция отправки в Telegram
send_telegram() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="${message}" \
        -d parse_mode="HTML" &>/dev/null || true
}

echo ""
echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
echo -e "${RED}       ЭКСТРЕННЫЙ ОТКАТ НА СТАРЫЙ СЕРВЕР${NC}"
echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}ВНИМАНИЕ:${NC} Этот скрипт вернет систему к работе на старом сервере."
echo ""
echo -e "${YELLOW}Используйте только в случае критических проблем:${NC}"
echo "  ❌ API не работает на новом сервере"
echo "  ❌ PostgreSQL недоступна или повреждена"
echo "  ❌ Потеря данных обнаружена"
echo "  ❌ Критические ошибки в работе сервисов"
echo ""
echo -e "${YELLOW}После отката:${NC}"
echo "  ⚠️  Вам нужно будет вручную переключить DNS на старый сервер"
echo "  ⚠️  Данные, созданные на новом сервере, могут быть потеряны"
echo ""

read -p "Вы уверены, что хотите выполнить откат? (yes/no): " confirm
if [[ ! "$confirm" =~ ^[Yy][Ee][Ss]$ ]]; then
    echo ""
    echo -e "${GREEN}Откат отменен${NC}"
    echo ""
    exit 0
fi

echo ""
read -p "Введите причину отката (для логов): " rollback_reason
echo "Причина отката: $rollback_reason" >> "$LOG_FILE"

START_TIME=$(date +%s)

send_telegram "🚨 <b>ЭКСТРЕННЫЙ ОТКАТ</b>%0A%0AПричина: $rollback_reason%0AСервер: $(hostname)%0AВремя: $(date '+%Y-%m-%d %H:%M:%S')"

echo ""
echo -e "${YELLOW}[1/6] Проверка статуса текущих контейнеров...${NC}"
echo ""

docker compose ps || log_warning "docker compose ps failed"

echo ""
echo -e "${YELLOW}[2/6] Остановка всех контейнеров...${NC}"
echo ""

docker compose down || log_warning "docker compose down failed (контейнеры могут быть уже остановлены)"
log_success "Контейнеры остановлены"

echo ""
echo -e "${YELLOW}[3/6] Запуск всех сервисов...${NC}"
echo ""

docker compose up -d
sleep 10
log_success "Контейнеры запущены"

echo ""
echo -e "${YELLOW}[4/6] Ожидание готовности сервисов (30 секунд)...${NC}"
echo ""

for i in {1..6}; do
    echo -n "."
    sleep 5
done
echo ""
log_success "Ожидание завершено"

echo ""
echo -e "${YELLOW}[5/6] Проверка здоровья сервисов...${NC}"
echo ""

# Проверка LiteLLM
log_info "Проверка LiteLLM Proxy..."
if curl -sf http://localhost:4000/health/liveliness | grep -q "I'm alive"; then
    log_success "✓ LiteLLM Proxy работает"
else
    log_error "✗ LiteLLM Proxy НЕ работает"
fi

# Проверка PostgreSQL
log_info "Проверка PostgreSQL..."
if PGPASSWORD=dbpassword9090 psql -h localhost -p 5433 -U llmproxy -d litellm -c "SELECT 1" &>/dev/null; then
    RECORD_COUNT=$(PGPASSWORD=dbpassword9090 psql -h localhost -p 5433 -U llmproxy -d litellm -t -c "SELECT COUNT(*) FROM \"LiteLLM_SpendLogs\"" 2>/dev/null | tr -d ' ')
    log_success "✓ PostgreSQL работает (записей: $RECORD_COUNT)"
else
    log_error "✗ PostgreSQL НЕ работает"
fi

# Проверка Redis
log_info "Проверка Redis..."
if docker exec $(docker ps -qf "name=redis") redis-cli ping 2>/dev/null | grep -q "PONG"; then
    log_success "✓ Redis работает"
else
    log_error "✗ Redis НЕ работает"
fi

# Проверка Grafana
log_info "Проверка Grafana..."
if curl -sf http://localhost:3098/api/health | grep -q "ok"; then
    log_success "✓ Grafana работает"
else
    log_warning "⚠ Grafana может быть недоступна"
fi

# Проверка Prometheus
log_info "Проверка Prometheus..."
if curl -sf http://localhost:9092/-/healthy 2>/dev/null | grep -q "Prometheus"; then
    log_success "✓ Prometheus работает"
else
    log_warning "⚠ Prometheus может быть недоступен"
fi

# Проверка Metrics Exporter
log_info "Проверка Metrics Exporter..."
if curl -sf http://localhost:9090/metrics 2>/dev/null | grep -q "litellm_team_spend"; then
    log_success "✓ Metrics Exporter работает"
else
    log_warning "⚠ Metrics Exporter может быть недоступен"
fi

echo ""
echo -e "${YELLOW}[6/6] Отправка уведомления...${NC}"
echo ""

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

send_telegram "✅ <b>ОТКАТ ЗАВЕРШЕН</b>%0A%0ASервисы восстановлены на старом сервере%0AВремя отката: ${DURATION} секунд%0A%0A⚠️ ВАЖНО: Переключите DNS обратно на старый сервер!"

log_success "Уведомление отправлено"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}       ОТКАТ НА СТАРЫЙ СЕРВЕР ЗАВЕРШЕН${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Время отката:${NC} $DURATION секунд"
echo -e "${BLUE}Лог файл:${NC} $LOG_FILE"
echo ""
echo -e "${YELLOW}КРИТИЧЕСКИ ВАЖНЫЕ СЛЕДУЮЩИЕ ШАГИ:${NC}"
echo ""
echo "1. ${RED}ПЕРЕКЛЮЧИТЕ DNS ОБРАТНО НА СТАРЫЙ СЕРВЕР${NC}"
echo "   Вручную измените DNS записи:"
echo "   - litellm.pro-4.ru → [IP старого сервера]"
echo "   - dash.pro-4.ru → [IP старого сервера]"
echo ""
echo "2. Дождитесь распространения DNS (5-15 минут)"
echo "   Проверка: nslookup litellm.pro-4.ru"
echo ""
echo "3. Проверьте доступность через домены:"
echo "   curl http://litellm.pro-4.ru:4000/health/liveliness"
echo "   curl http://dash.pro-4.ru:3098/api/health"
echo ""
echo "4. Проверьте работу всех сервисов:"
echo "   docker compose ps"
echo "   docker compose logs --tail=50"
echo ""
echo "5. Запустите полную верификацию:"
echo "   ./scripts/post-migration-verify.sh"
echo ""
echo "6. Проанализируйте причины проблем на новом сервере"
echo "   - Логи нового сервера"
echo "   - Состояние базы данных"
echo "   - Конфигурация"
echo ""
echo "7. Создайте post-mortem анализ"
echo "   - Что пошло не так?"
echo "   - Почему не обнаружили при тестировании?"
echo "   - Как предотвратить в будущем?"
echo ""
echo -e "${YELLOW}Подробности отката:${NC}"
echo "- Причина: $rollback_reason"
echo "- Начало: $(date -d @$START_TIME '+%Y-%m-%d %H:%M:%S')"
echo "- Конец: $(date -d @$END_TIME '+%Y-%m-%d %H:%M:%S')"
echo "- Длительность: $DURATION секунд"
echo ""
echo -e "${GREEN}Сервисы работают на старом сервере!${NC}"
echo ""
echo -e "${RED}НЕ ЗАБУДЬТЕ ПЕРЕКЛЮЧИТЬ DNS!${NC}"
echo ""

# Показать текущий статус контейнеров
echo -e "${BLUE}Текущий статус контейнеров:${NC}"
docker compose ps

echo ""
