#!/bin/bash

#############################################################################
# Grafana Data Migration Script v2
# Мигрирует grafana.db через tar архив между серверами
#############################################################################

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Конфигурация
NEW_SERVER="65.21.202.252"
NEW_SERVER_USER="yan"

echo "======================================================================"
echo "  Grafana Data Migration v2"
echo "  Target: ${NEW_SERVER_USER}@${NEW_SERVER}"
echo "======================================================================"
echo ""

#############################################################################
# 1. Проверка пользователей
#############################################################################

log_info "Проверка пользователей на текущем сервере..."
CURRENT_USERS=$(curl -s -u admin:admin123 http://localhost:3098/api/users | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data)); [print(f'  - {u[\"login\"]} ({u[\"name\"] or \"no name\"})') for u in data]")
log_success "Пользователей на текущем сервере: $(echo "$CURRENT_USERS" | head -1)"
echo "$CURRENT_USERS" | tail -n +2

echo ""
log_info "Проверка пользователей на новом сервере..."
NEW_USERS=$(ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "curl -s -u admin:admin123 http://localhost:3098/api/users" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data))")
log_success "Пользователей на новом сервере: $NEW_USERS"

USER_COUNT=$(echo "$CURRENT_USERS" | head -1)
if [ "$NEW_USERS" -ge "$USER_COUNT" ]; then
    log_warning "На новом сервере уже есть $NEW_USERS пользователей (на старом: $USER_COUNT)"
    echo ""
    read -p "Продолжить миграцию и ЗАМЕНИТЬ данные? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Миграция отменена"
        exit 0
    fi
fi

#############################################################################
# 2. Создание tar архива на текущем сервере
#############################################################################

log_info "Создание tar архива Grafana на текущем сервере..."
docker run --rm \
    -v litellm_grafana_data_external:/source \
    -v /tmp:/backup \
    alpine tar czf /backup/grafana_data_export.tar.gz -C /source .

if [ ! -f "/tmp/grafana_data_export.tar.gz" ]; then
    log_error "Не удалось создать архив"
    exit 1
fi

ARCHIVE_SIZE=$(du -h /tmp/grafana_data_export.tar.gz | cut -f1)
log_success "Архив создан: /tmp/grafana_data_export.tar.gz ($ARCHIVE_SIZE)"

#############################################################################
# 3. Копирование архива на новый сервер
#############################################################################

log_info "Копирование архива на новый сервер..."
scp /tmp/grafana_data_export.tar.gz "${NEW_SERVER_USER}@${NEW_SERVER}:/tmp/"
log_success "Архив скопирован"

#############################################################################
# 4. Создание бэкапа на новом сервере
#############################################################################

log_info "Создание бэкапа на новом сервере..."
ssh "${NEW_SERVER_USER}@${NEW_SERVER}" << 'ENDSSH'
docker run --rm \
    -v litellm_grafana_data_external:/source \
    -v /tmp:/backup \
    alpine tar czf /backup/grafana_backup_before_migration.tar.gz -C /source .
ENDSSH

log_success "Бэкап создан: /tmp/grafana_backup_before_migration.tar.gz"

#############################################################################
# 5. Остановка Grafana на новом сервере
#############################################################################

log_info "Остановка Grafana на новом сервере..."
ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "cd /home/yan/litellm && docker compose stop grafana"
log_success "Grafana остановлен"

#############################################################################
# 6. Очистка и восстановление на новом сервере
#############################################################################

log_info "Очистка старых данных на новом сервере..."
ssh "${NEW_SERVER_USER}@${NEW_SERVER}" << 'ENDSSH'
# Удаляем все содержимое volume
docker run --rm \
    -v litellm_grafana_data_external:/data \
    alpine sh -c "rm -rf /data/*"
ENDSSH

log_success "Старые данные удалены"

log_info "Восстановление данных на новом сервере..."
ssh "${NEW_SERVER_USER}@${NEW_SERVER}" << 'ENDSSH'
# Распаковываем новые данные
docker run --rm \
    -v litellm_grafana_data_external:/data \
    -v /tmp:/backup \
    alpine sh -c "cd /data && tar xzf /backup/grafana_data_export.tar.gz"

# Устанавливаем правильные права
docker run --rm \
    -v litellm_grafana_data_external:/data \
    alpine sh -c "chown -R 472:0 /data && chmod -R 755 /data && chmod 640 /data/grafana.db"
ENDSSH

log_success "Данные восстановлены"

#############################################################################
# 7. Запуск Grafana
#############################################################################

log_info "Запуск Grafana на новом сервере..."
ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "cd /home/yan/litellm && docker compose start grafana"
log_success "Grafana запущен"

# Ожидание готовности
log_info "Ожидание готовности Grafana (макс 60 сек)..."
sleep 5

for i in {1..12}; do
    if ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "curl -s http://localhost:3098/api/health" | grep -q "ok"; then
        log_success "Grafana готов!"
        break
    fi
    if [ $i -eq 12 ]; then
        log_error "Grafana не запустился за 60 секунд"
        echo ""
        log_info "Проверьте логи: ssh ${NEW_SERVER_USER}@${NEW_SERVER} 'docker logs litellm-grafana-1'"
        exit 1
    fi
    echo "Попытка $i/12..."
    sleep 5
done

#############################################################################
# 8. Проверка миграции
#############################################################################

echo ""
log_info "Проверка пользователей на новом сервере..."
sleep 2  # Даем Grafana время инициализироваться

MIGRATED_USERS=$(ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "curl -s -u admin:admin123 http://localhost:3098/api/users" | python3 -c "import sys, json; data=json.load(sys.stdin); print(len(data)); [print(f'  - {u[\"login\"]} ({u[\"name\"] or \"no name\"})') for u in data]" 2>/dev/null || echo "0")

MIGRATED_COUNT=$(echo "$MIGRATED_USERS" | head -1)
log_success "Пользователей после миграции: $MIGRATED_COUNT"
echo "$MIGRATED_USERS" | tail -n +2

if [ "$MIGRATED_COUNT" -eq "$USER_COUNT" ]; then
    log_success "Все пользователи мигрированы успешно!"
else
    log_warning "Количество пользователей отличается: ожидалось $USER_COUNT, получено $MIGRATED_COUNT"
fi

#############################################################################
# 9. Очистка
#############################################################################

log_info "Очистка временных файлов..."
rm -f /tmp/grafana_data_export.tar.gz
ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "rm -f /tmp/grafana_data_export.tar.gz"
log_success "Временные файлы удалены"

#############################################################################
# Итоговый отчет
#############################################################################

echo ""
echo "======================================================================"
echo -e "${GREEN}✓ Миграция Grafana завершена успешно!${NC}"
echo "======================================================================"
echo ""
echo "Результаты миграции:"
echo "  Пользователей на старом сервере: $USER_COUNT"
echo "  Пользователей на новом сервере:  $MIGRATED_COUNT"
echo ""
echo "Бэкап старых данных (на новом сервере):"
echo "  /tmp/grafana_backup_before_migration.tar.gz"
echo ""
echo "Проверьте доступ:"
echo "  http://65.21.202.252:3098"
echo "  Логин: admin / admin123"
echo ""
echo "Или (после настройки DNS и SSL):"
echo "  https://dash.pro-4.ru"
echo ""
echo "======================================================================"
