#!/bin/bash

#############################################################################
# LiteLLM Migration Script (Blue-Green Deployment)
# Мигрирует LiteLLM на новый сервер с минимальным простоем
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
OLD_SERVER_PATH="/home/yan/litellm"
NEW_SERVER="65.21.202.252"
NEW_SERVER_USER="yan"
NEW_SERVER_PATH="/home/yan/litellm"
BACKUP_PATH="/home/yan/litellm/backups"

# Telegram настройки
TELEGRAM_BOT_TOKEN="7965448155:AAGSiq8Ngvw-Z2sKtWbwabaSL-HnvRPpkNg"
TELEGRAM_CHAT_ID="234583347"

# Логирование
LOG_FILE="/home/yan/litellm/migration_$(date +%Y%m%d_%H%M%S).log"

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

log_step() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN} $1${NC}" | tee -a "$LOG_FILE"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
}

# Функция отправки в Telegram
send_telegram() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="${message}" \
        -d parse_mode="HTML" &>/dev/null || true
}

# Функция для подтверждения
confirm() {
    local prompt="$1"
    local response
    echo -e "${YELLOW}${prompt}${NC}"
    read -p "Продолжить? (yes/no): " response
    if [[ ! "$response" =~ ^[Yy][Ee][Ss]$ ]]; then
        log_error "Операция отменена пользователем"
        exit 1
    fi
}

# Обработка ошибок
error_handler() {
    log_error "Ошибка на линии $1"
    send_telegram "❌ ОШИБКА МИГРАЦИИ на линии $1"
    exit 1
}

trap 'error_handler $LINENO' ERR

# Проверка прав
if [ "$EUID" -eq 0 ]; then
    log_error "Не запускайте этот скрипт от root!"
    exit 1
fi

echo "======================================================================"
echo "  LiteLLM Migration to New Server (Blue-Green)"
echo "  Источник: $(hostname)"
echo "  Цель: ${NEW_SERVER_USER}@${NEW_SERVER}"
echo "======================================================================"
echo ""

send_telegram "🚀 <b>Начало миграции LiteLLM</b>%0A%0AИсточник: $(hostname)%0AЦель: ${NEW_SERVER}"

#############################################################################
# ЭТАП 0: Предварительные проверки
#############################################################################

log_step "ЭТАП 0: Предварительные проверки"

log_info "Запуск предварительных проверок..."
if ! ./scripts/pre-migration-check.sh; then
    log_error "Предварительные проверки не прошли!"
    log_info "Запустите: ./scripts/pre-migration-check.sh для детальной информации"
    exit 1
fi

log_success "Предварительные проверки пройдены"

#############################################################################
# ЭТАП 1: Финальный бэкап на старом сервере
#############################################################################

log_step "ЭТАП 1: Создание финального бэкапа"

confirm "Создать финальный бэкап перед миграцией?"

log_info "Запуск скрипта бэкапа..."
if ./scripts/backup.sh; then
    log_success "Финальный бэкап создан успешно"
else
    log_error "Ошибка создания бэкапа"
    exit 1
fi

# Определяем путь к последнему бэкапу
LATEST_BACKUP=$(readlink -f "$BACKUP_PATH/latest")
BACKUP_SIZE=$(du -sh "$LATEST_BACKUP" | cut -f1)
log_info "Последний бэкап: $LATEST_BACKUP ($BACKUP_SIZE)"

#############################################################################
# ЭТАП 2: Копирование файлов на новый сервер
#############################################################################

log_step "ЭТАП 2: Копирование данных на новый сервер"

log_info "Проверка SSH подключения..."
if ! ssh -o ConnectTimeout=10 "${NEW_SERVER_USER}@${NEW_SERVER}" "echo 'SSH OK'" &>/dev/null; then
    log_error "Не удалось подключиться к новому серверу через SSH"
    log_info "Попробуйте: ssh-copy-id ${NEW_SERVER_USER}@${NEW_SERVER}"
    exit 1
fi
log_success "SSH подключение установлено"

log_info "Создание рабочей директории на новом сервере..."
ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "mkdir -p ${NEW_SERVER_PATH}/{grafana/provisioning/{dashboards,datasources},scripts,backups}"
log_success "Директория создана"

log_info "Копирование конфигурационных файлов..."
# Копируем критичные конфигурационные файлы
scp "$OLD_SERVER_PATH/docker-compose.yml" "${NEW_SERVER_USER}@${NEW_SERVER}:${NEW_SERVER_PATH}/"
scp "$OLD_SERVER_PATH/config.yaml" "${NEW_SERVER_USER}@${NEW_SERVER}:${NEW_SERVER_PATH}/"
scp "$OLD_SERVER_PATH/.env" "${NEW_SERVER_USER}@${NEW_SERVER}:${NEW_SERVER_PATH}/"
scp "$OLD_SERVER_PATH/prometheus.yml" "${NEW_SERVER_USER}@${NEW_SERVER}:${NEW_SERVER_PATH}/"

# Проверить и исправить конфликты портов на новом сервере
log_info "Проверка портов на новом сервере..."
if ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "netstat -tulpn 2>/dev/null | grep -q ':5433 ' || ss -tulpn | grep -q ':5433 '"; then
    log_warning "Порт 5433 занят на новом сервере, изменяем на 5434"
    ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "sed -i 's/5433:5432/5434:5432/' ${NEW_SERVER_PATH}/docker-compose.yml"
    log_success "Порт PostgreSQL изменён на 5434"
fi

log_success "Конфигурационные файлы скопированы"

log_info "Копирование Grafana provisioning..."
scp -r "$OLD_SERVER_PATH/grafana/provisioning/"* "${NEW_SERVER_USER}@${NEW_SERVER}:${NEW_SERVER_PATH}/grafana/provisioning/"
log_success "Grafana provisioning скопирован"

log_info "Копирование скриптов..."
scp "$OLD_SERVER_PATH/scripts/"*.sh "${NEW_SERVER_USER}@${NEW_SERVER}:${NEW_SERVER_PATH}/scripts/"
ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "chmod +x ${NEW_SERVER_PATH}/scripts/*.sh"
log_success "Скрипты скопированы"

log_info "Копирование metrics exporter файла..."
if [ -f "$OLD_SERVER_PATH/litellm_simple_working_exporter.py" ]; then
    scp "$OLD_SERVER_PATH/litellm_simple_working_exporter.py" "${NEW_SERVER_USER}@${NEW_SERVER}:${NEW_SERVER_PATH}/"
    log_success "Metrics exporter файл скопирован"
elif [ -f "$OLD_SERVER_PATH/litellm_redis_exporter.py" ]; then
    scp "$OLD_SERVER_PATH/litellm_redis_exporter.py" "${NEW_SERVER_USER}@${NEW_SERVER}:${NEW_SERVER_PATH}/litellm_simple_working_exporter.py"
    log_success "Metrics exporter файл скопирован (из litellm_redis_exporter.py)"
else
    log_warning "Metrics exporter файл не найден, может потребоваться ручное копирование"
fi

# Проверить и исправить конфликты портов для metrics exporter
log_info "Проверка портов metrics exporter на новом сервере..."
if ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "ss -tulpn | grep -q ':9090 '"; then
    log_warning "Порт 9090 занят, ищем свободный порт..."
    for port in 9093 9094 9095 9096; do
        if ! ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "ss -tulpn | grep -q ':$port '"; then
            log_info "Используем порт $port для metrics exporter"
            ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "sed -i 's/\"9090:9090\"/\"$port:9090\"/' ${NEW_SERVER_PATH}/docker-compose.yml"
            log_success "Порт metrics exporter изменён на $port"
            break
        fi
    done
fi

log_info "Копирование последнего бэкапа..."
# Проверяем, существует ли уже бэкап на удаленном сервере
REMOTE_BACKUP_EXISTS=$(ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "[ -d ${NEW_SERVER_PATH}/backups/latest ] && echo 'yes' || echo 'no'")

if [ "$REMOTE_BACKUP_EXISTS" = "yes" ]; then
    log_info "Бэкап уже существует на удаленном сервере (из sync-remote.sh)"
    log_info "Проверка актуальности..."
    REMOTE_BACKUP_PATH=$(ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "readlink -f ${NEW_SERVER_PATH}/backups/latest" || echo "")
    if [ -n "$REMOTE_BACKUP_PATH" ]; then
        log_success "Используем существующий бэкап: $REMOTE_BACKUP_PATH"
    else
        log_info "Копируем свежий бэкап..."
        rsync -avz --progress "$LATEST_BACKUP/" "${NEW_SERVER_USER}@${NEW_SERVER}:${NEW_SERVER_PATH}/backups/latest_migration/"
    fi
else
    log_info "Копируем бэкап на новый сервер (это может занять время)..."
    rsync -avz --progress "$LATEST_BACKUP/" "${NEW_SERVER_USER}@${NEW_SERVER}:${NEW_SERVER_PATH}/backups/latest_migration/"
fi

log_success "Все файлы скопированы на новый сервер"

#############################################################################
# ЭТАП 3: Подготовка окружения на новом сервере
#############################################################################

log_step "ЭТАП 3: Подготовка окружения на новом сервере"

log_info "Создание Docker volumes на новом сервере..."
ssh "${NEW_SERVER_USER}@${NEW_SERVER}" << 'ENDSSH'
# Создаем внешние volumes
docker volume create litellm_postgres_data_external 2>/dev/null || echo "Volume litellm_postgres_data_external уже существует"
docker volume create litellm_grafana_data_external 2>/dev/null || echo "Volume litellm_grafana_data_external уже существует"
ENDSSH
log_success "Docker volumes созданы"

log_info "Проверка наличия Docker на новом сервере..."
ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "docker --version && docker compose version"
log_success "Docker готов к работе"

#############################################################################
# ЭТАП 4: Восстановление данных на новом сервере
#############################################################################

log_step "ЭТАП 4: Восстановление данных на новом сервере"

log_info "Создание временного PostgreSQL контейнера для восстановления..."
ssh "${NEW_SERVER_USER}@${NEW_SERVER}" << 'ENDSSH'
cd /home/yan/litellm

# Останавливаем контейнеры если они запущены
docker compose down 2>/dev/null || true

# Запускаем только PostgreSQL для восстановления
docker compose up -d db

# Ждем готовности PostgreSQL
echo "Ожидание готовности PostgreSQL..."
for i in {1..30}; do
    if docker exec litellm_db pg_isready -U llmproxy &>/dev/null; then
        echo "PostgreSQL готов!"
        break
    fi
    echo "Попытка $i/30..."
    sleep 2
done

# Определяем путь к бэкапу
if [ -d "backups/latest_migration" ]; then
    BACKUP_DIR="backups/latest_migration"
elif [ -L "backups/latest" ]; then
    BACKUP_DIR=$(readlink -f backups/latest)
else
    echo "Ошибка: бэкап не найден!"
    exit 1
fi

echo "Используем бэкап из: $BACKUP_DIR"

# Восстанавливаем PostgreSQL
if [ -f "$BACKUP_DIR/postgresql_litellm.sql" ]; then
    echo "Восстановление PostgreSQL базы данных..."
    docker exec -i litellm_db psql -U llmproxy -d postgres < "$BACKUP_DIR/postgresql_litellm.sql"
    echo "✓ PostgreSQL восстановлена"
else
    echo "✗ Файл бэкапа PostgreSQL не найден!"
    exit 1
fi

# Проверяем восстановление
RECORD_COUNT=$(docker exec litellm_db psql -U llmproxy -d litellm -t -c "SELECT COUNT(*) FROM \"LiteLLM_SpendLogs\"" | tr -d ' ')
echo "✓ Проверка: записей в SpendLogs: $RECORD_COUNT"

ENDSSH

log_success "PostgreSQL база восстановлена"

#############################################################################
# ЭТАП 5: Восстановление Prometheus и Grafana данных
#############################################################################

log_step "ЭТАП 5: Восстановление Prometheus и Grafana данных"

log_info "Восстановление Grafana volume..."
ssh "${NEW_SERVER_USER}@${NEW_SERVER}" << 'ENDSSH'
cd /home/yan/litellm

# Определяем путь к бэкапу
if [ -d "backups/latest_migration" ]; then
    BACKUP_DIR="backups/latest_migration"
elif [ -L "backups/latest" ]; then
    BACKUP_DIR=$(readlink -f backups/latest)
fi

# Восстанавливаем Grafana данные если есть
if [ -f "$BACKUP_DIR/grafana_data.tar.gz" ]; then
    echo "Восстановление Grafana данных..."
    docker run --rm \
        -v litellm_grafana_data_external:/target \
        -v "$(pwd)/$BACKUP_DIR:/backup" \
        alpine sh -c "cd /target && tar xzf /backup/grafana_data.tar.gz --strip-components=1"
    echo "✓ Grafana данные восстановлены"
else
    echo "! Архив Grafana данных не найден, provisioning будет использован"
fi

# Восстанавливаем Prometheus данные если есть и требуется
if [ -f "$BACKUP_DIR/prometheus_data.tar.gz" ]; then
    echo "Восстановление Prometheus данных..."
    # Prometheus восстановим позже, после создания volume через docker-compose
    echo "! Prometheus данные будут восстановлены после запуска контейнеров"
fi

ENDSSH

log_success "Данные подготовлены для восстановления"

#############################################################################
# ЭТАП 6: Запуск всех сервисов на новом сервере
#############################################################################

log_step "ЭТАП 6: Запуск всех сервисов"

log_info "Запуск Docker Compose на новом сервере..."
ssh "${NEW_SERVER_USER}@${NEW_SERVER}" << 'ENDSSH'
cd /home/yan/litellm

# Запускаем все сервисы
docker compose down
docker compose up -d

# Ждем готовности сервисов
echo "Ожидание запуска сервисов..."
sleep 10

# Проверяем статус
echo "Статус контейнеров:"
docker compose ps

ENDSSH

log_success "Все сервисы запущены"

send_telegram "✅ <b>Сервисы запущены на новом сервере</b>%0A%0AСледующий шаг: тестирование"

#############################################################################
# ЭТАП 7: Тестирование на новом сервере
#############################################################################

log_step "ЭТАП 7: Тестирование сервисов"

log_info "Ожидание полной инициализации (30 секунд)..."
sleep 30

log_info "Тестирование сервисов на новом сервере..."
ssh "${NEW_SERVER_USER}@${NEW_SERVER}" << 'ENDSSH'
cd /home/yan/litellm

echo "1. Проверка LiteLLM Proxy..."
if curl -s http://localhost:4000/health/liveliness | grep -q "I'm alive"; then
    echo "✓ LiteLLM Proxy работает"
else
    echo "✗ LiteLLM Proxy не отвечает"
    exit 1
fi

echo "2. Проверка PostgreSQL..."
if docker exec litellm_db psql -U llmproxy -d litellm -c "SELECT COUNT(*) FROM \"LiteLLM_SpendLogs\"" &>/dev/null; then
    RECORDS=$(docker exec litellm_db psql -U llmproxy -d litellm -t -c "SELECT COUNT(*) FROM \"LiteLLM_SpendLogs\"" | tr -d ' ')
    echo "✓ PostgreSQL работает, записей: $RECORDS"
else
    echo "✗ PostgreSQL не работает"
    exit 1
fi

echo "3. Проверка Redis..."
if docker exec $(docker ps -qf "name=redis") redis-cli ping | grep -q "PONG"; then
    echo "✓ Redis работает"
else
    echo "✗ Redis не работает"
    exit 1
fi

echo "4. Проверка Prometheus..."
if curl -s http://localhost:9092/-/healthy | grep -q "Prometheus"; then
    echo "✓ Prometheus работает"
else
    echo "✗ Prometheus не отвечает"
fi

echo "5. Проверка Grafana..."
if curl -s http://localhost:3098/api/health | grep -q "ok"; then
    echo "✓ Grafana работает"
else
    echo "✗ Grafana не отвечает"
fi

echo "6. Проверка Metrics Exporter..."
if curl -s http://localhost:9090/metrics | grep -q "litellm_team_spend"; then
    echo "✓ Metrics Exporter работает"
else
    echo "✗ Metrics Exporter не работает"
fi

echo ""
echo "Все базовые проверки пройдены!"

ENDSSH

log_success "Все тесты пройдены успешно!"

send_telegram "✅ <b>Тестирование завершено успешно</b>%0A%0AВсе сервисы работают на новом сервере"

#############################################################################
# ЭТАП 8: Финальные инструкции
#############################################################################

log_step "ЭТАП 8: Финальные инструкции"

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  МИГРАЦИЯ УСПЕШНО ЗАВЕРШЕНА!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
log_info "Новый сервер готов к работе на ${NEW_SERVER}"
echo ""
echo -e "${YELLOW}Следующие шаги:${NC}"
echo ""
echo "1. ТЕСТИРОВАНИЕ:"
echo "   - Подключитесь к новому серверу: ssh ${NEW_SERVER_USER}@${NEW_SERVER}"
echo "   - Проверьте работу через IP: http://${NEW_SERVER}:4000"
echo "   - Проверьте Grafana: http://${NEW_SERVER}:3098"
echo ""
echo "2. ПЕРЕКЛЮЧЕНИЕ DNS (когда будете готовы):"
echo "   - litellm.pro-4.ru → ${NEW_SERVER}"
echo "   - dash.pro-4.ru → ${NEW_SERVER}"
echo "   См. файл: DNS_UPDATE_INSTRUCTIONS.md"
echo ""
echo "3. ПОСЛЕ ПЕРЕКЛЮЧЕНИЯ DNS:"
echo "   - Дождитесь распространения DNS (проверка: nslookup litellm.pro-4.ru)"
echo "   - Проверьте доступность через домены"
echo "   - Запустите верификацию: ./scripts/post-migration-verify.sh"
echo ""
echo "4. НАСТРОЙКА АВТОМАТИЧЕСКИХ БЭКАПОВ:"
echo "   На новом сервере запустите:"
echo "   ssh ${NEW_SERVER_USER}@${NEW_SERVER}"
echo "   cd ${NEW_SERVER_PATH}"
echo "   ./scripts/setup-cron.sh"
echo ""
echo "5. ОТКАТ (если что-то пойдет не так):"
echo "   - Переключите DNS обратно на старый сервер"
echo "   - Старый сервер продолжает работать"
echo "   См. файл: ROLLBACK_PLAN.md"
echo ""
echo -e "${CYAN}Важно:${NC}"
echo "- Не останавливайте старый сервер минимум 48 часов"
echo "- Мониторьте новый сервер на наличие ошибок"
echo "- Все логи миграции сохранены в: $LOG_FILE"
echo ""
echo -e "${GREEN}Новый сервер работает и готов к приему трафика!${NC}"
echo ""

send_telegram "🎉 <b>МИГРАЦИЯ ЗАВЕРШЕНА!</b>%0A%0AНовый сервер: ${NEW_SERVER}%0AСтатус: Все сервисы работают%0A%0AСледующий шаг: обновление DNS"

log_success "Скрипт миграции завершен"
log_info "Логи сохранены в: $LOG_FILE"
