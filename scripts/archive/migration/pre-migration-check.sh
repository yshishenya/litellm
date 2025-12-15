#!/bin/bash

#############################################################################
# Pre-Migration Check Script for LiteLLM
# Проверяет готовность к миграции на новый сервер
#############################################################################

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Конфигурация
NEW_SERVER="65.21.202.252"
NEW_SERVER_USER="yan"
NEW_SERVER_PATH="/home/yan/litellm"
BACKUP_PATH="/home/yan/litellm/backups"

# Функции для логирования
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

# Счетчики проверок
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNING=0

check_passed() {
    log_success "$1"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
}

check_failed() {
    log_error "$1"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
}

check_warning() {
    log_warning "$1"
    CHECKS_WARNING=$((CHECKS_WARNING + 1))
}

echo "======================================================================"
echo "  LiteLLM Pre-Migration Checklist"
echo "  Целевой сервер: ${NEW_SERVER_USER}@${NEW_SERVER}"
echo "======================================================================"
echo ""

#############################################################################
# 1. Проверка текущего сервера
#############################################################################

echo -e "${BLUE}[1] Проверка текущего сервера${NC}"
echo "----------------------------------------------------------------------"

# 1.1 Проверка Docker
log_info "Проверка Docker..."
if docker --version &>/dev/null; then
    DOCKER_VERSION=$(docker --version)
    check_passed "Docker установлен: $DOCKER_VERSION"
else
    check_failed "Docker не установлен"
fi

# 1.2 Проверка Docker Compose
log_info "Проверка Docker Compose..."
if docker compose version &>/dev/null; then
    COMPOSE_VERSION=$(docker compose version)
    check_passed "Docker Compose установлен: $COMPOSE_VERSION"
else
    check_failed "Docker Compose не установлен"
fi

# 1.3 Проверка запущенных контейнеров
log_info "Проверка запущенных контейнеров..."
RUNNING_CONTAINERS=$(docker ps --filter "name=litellm" --format "{{.Names}}" | wc -l)
if [ "$RUNNING_CONTAINERS" -ge 6 ]; then
    check_passed "Все контейнеры запущены ($RUNNING_CONTAINERS/6)"
    docker ps --filter "name=litellm" --format "table {{.Names}}\t{{.Status}}"
else
    check_warning "Запущено только $RUNNING_CONTAINERS контейнеров (ожидается 6)"
fi

# 1.4 Проверка volumes
log_info "Проверка Docker volumes..."
if docker volume ls | grep -q "litellm_postgres_data_external"; then
    check_passed "PostgreSQL volume существует"
else
    check_failed "PostgreSQL volume не найден"
fi

if docker volume ls | grep -q "litellm_grafana_data_external"; then
    check_passed "Grafana volume существует"
else
    check_failed "Grafana volume не найден"
fi

# 1.5 Проверка PostgreSQL
log_info "Проверка PostgreSQL базы данных..."
if PGPASSWORD=dbpassword9090 psql -h localhost -p 5433 -U llmproxy -d litellm -c "SELECT 1" &>/dev/null; then
    RECORD_COUNT=$(PGPASSWORD=dbpassword9090 psql -h localhost -p 5433 -U llmproxy -d litellm -t -c "SELECT COUNT(*) FROM \"LiteLLM_SpendLogs\"" 2>/dev/null | tr -d ' ')
    check_passed "PostgreSQL доступна, записей в SpendLogs: $RECORD_COUNT"
else
    check_failed "PostgreSQL недоступна"
fi

echo ""

#############################################################################
# 2. Проверка бэкапов
#############################################################################

echo -e "${BLUE}[2] Проверка бэкапов${NC}"
echo "----------------------------------------------------------------------"

# 2.1 Проверка директории бэкапов
log_info "Проверка директории бэкапов..."
if [ -d "$BACKUP_PATH" ]; then
    BACKUP_SIZE=$(du -sh "$BACKUP_PATH" 2>/dev/null | cut -f1)
    check_passed "Директория бэкапов существует: $BACKUP_SIZE"
else
    check_failed "Директория бэкапов не найдена: $BACKUP_PATH"
fi

# 2.2 Проверка последнего бэкапа
log_info "Проверка последнего бэкапа..."
if [ -L "$BACKUP_PATH/latest" ]; then
    LATEST_BACKUP=$(readlink -f "$BACKUP_PATH/latest")
    BACKUP_DATE=$(stat -c %y "$LATEST_BACKUP" 2>/dev/null | cut -d' ' -f1)
    check_passed "Последний бэкап: $LATEST_BACKUP (дата: $BACKUP_DATE)"

    # Проверка содержимого бэкапа
    if [ -f "$LATEST_BACKUP/postgresql_litellm.sql" ]; then
        SQL_SIZE=$(du -sh "$LATEST_BACKUP/postgresql_litellm.sql" | cut -f1)
        check_passed "PostgreSQL dump найден: $SQL_SIZE"
    else
        check_failed "PostgreSQL dump не найден в бэкапе"
    fi

    if [ -f "$LATEST_BACKUP/docker-compose.yml" ]; then
        check_passed "docker-compose.yml найден в бэкапе"
    else
        check_warning "docker-compose.yml не найден в бэкапе"
    fi

    if [ -f "$LATEST_BACKUP/.env" ]; then
        check_passed ".env файл найден в бэкапе"
    else
        check_warning ".env файл не найден в бэкапе"
    fi
else
    check_failed "Симлинк последнего бэкапа не найден"
fi

echo ""

#############################################################################
# 3. Проверка конфигурационных файлов
#############################################################################

echo -e "${BLUE}[3] Проверка конфигурационных файлов${NC}"
echo "----------------------------------------------------------------------"

# 3.1 Проверка .env
log_info "Проверка .env файла..."
if [ -f "/home/yan/litellm/.env" ]; then
    check_passed ".env файл существует"

    # Проверка критичных переменных
    if grep -q "OPENAI_API_KEY" /home/yan/litellm/.env; then
        check_passed "OPENAI_API_KEY найден в .env"
    else
        check_warning "OPENAI_API_KEY не найден в .env"
    fi

    if grep -q "LITELLM_MASTER_KEY" /home/yan/litellm/.env; then
        check_passed "LITELLM_MASTER_KEY найден в .env"
    else
        check_warning "LITELLM_MASTER_KEY не найден в .env"
    fi
else
    check_failed ".env файл не найден"
fi

# 3.2 Проверка config.yaml
log_info "Проверка config.yaml..."
if [ -f "/home/yan/litellm/config.yaml" ]; then
    check_passed "config.yaml существует"
else
    check_failed "config.yaml не найден"
fi

# 3.3 Проверка docker-compose.yml
log_info "Проверка docker-compose.yml..."
if [ -f "/home/yan/litellm/docker-compose.yml" ]; then
    check_passed "docker-compose.yml существует"
else
    check_failed "docker-compose.yml не найден"
fi

# 3.4 Проверка prometheus.yml
log_info "Проверка prometheus.yml..."
if [ -f "/home/yan/litellm/prometheus.yml" ]; then
    check_passed "prometheus.yml существует"
else
    check_warning "prometheus.yml не найден"
fi

echo ""

#############################################################################
# 4. Проверка SSH доступа к новому серверу
#############################################################################

echo -e "${BLUE}[4] Проверка SSH доступа к новому серверу${NC}"
echo "----------------------------------------------------------------------"

log_info "Проверка SSH подключения к ${NEW_SERVER_USER}@${NEW_SERVER}..."
if ssh -o ConnectTimeout=10 -o BatchMode=yes "${NEW_SERVER_USER}@${NEW_SERVER}" "echo 'SSH OK'" &>/dev/null; then
    check_passed "SSH подключение успешно"
else
    check_warning "SSH подключение не удалось (может потребоваться пароль или настройка ключей)"
    log_info "Попробуйте: ssh-copy-id ${NEW_SERVER_USER}@${NEW_SERVER}"
fi

# Проверка доступности целевой директории
log_info "Проверка доступности целевой директории на новом сервере..."
if ssh -o ConnectTimeout=10 -o BatchMode=yes "${NEW_SERVER_USER}@${NEW_SERVER}" "test -d ${NEW_SERVER_PATH}" &>/dev/null; then
    check_warning "Директория ${NEW_SERVER_PATH} уже существует на новом сервере"
else
    check_passed "Директория ${NEW_SERVER_PATH} не существует (будет создана)"
fi

echo ""

#############################################################################
# 5. Проверка скриптов миграции
#############################################################################

echo -e "${BLUE}[5] Проверка скриптов миграции${NC}"
echo "----------------------------------------------------------------------"

# 5.1 Проверка backup.sh
log_info "Проверка backup.sh..."
if [ -f "/home/yan/litellm/scripts/backup.sh" ] && [ -x "/home/yan/litellm/scripts/backup.sh" ]; then
    check_passed "backup.sh найден и исполняемый"
else
    check_warning "backup.sh не найден или не исполняемый"
fi

# 5.2 Проверка restore.sh
log_info "Проверка restore.sh..."
if [ -f "/home/yan/litellm/scripts/restore.sh" ] && [ -x "/home/yan/litellm/scripts/restore.sh" ]; then
    check_passed "restore.sh найден и исполняемый"
else
    check_warning "restore.sh не найден или не исполняемый"
fi

# 5.3 Проверка sync-remote.sh
log_info "Проверка sync-remote.sh..."
if [ -f "/home/yan/litellm/scripts/sync-remote.sh" ] && [ -x "/home/yan/litellm/scripts/sync-remote.sh" ]; then
    check_passed "sync-remote.sh найден и исполняемый"
else
    check_warning "sync-remote.sh не найден или не исполняемый"
fi

echo ""

#############################################################################
# 6. Проверка свободного места
#############################################################################

echo -e "${BLUE}[6] Проверка свободного места${NC}"
echo "----------------------------------------------------------------------"

# На текущем сервере
log_info "Проверка свободного места на текущем сервере..."
DISK_AVAIL=$(df -h /home/yan/litellm | tail -1 | awk '{print $4}')
DISK_USED=$(df -h /home/yan/litellm | tail -1 | awk '{print $5}')
check_passed "Свободно на текущем сервере: $DISK_AVAIL (использовано: $DISK_USED)"

# На новом сервере
log_info "Проверка свободного места на новом сервере..."
if ssh -o ConnectTimeout=10 -o BatchMode=yes "${NEW_SERVER_USER}@${NEW_SERVER}" "df -h /home" &>/dev/null; then
    NEW_DISK_AVAIL=$(ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "df -h /home | tail -1 | awk '{print \$4}'")
    NEW_DISK_USED=$(ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "df -h /home | tail -1 | awk '{print \$5}'")
    check_passed "Свободно на новом сервере: $NEW_DISK_AVAIL (использовано: $NEW_DISK_USED)"
else
    check_warning "Не удалось проверить место на новом сервере"
fi

echo ""

#############################################################################
# 7. Проверка версий на новом сервере
#############################################################################

echo -e "${BLUE}[7] Проверка установленного ПО на новом сервере${NC}"
echo "----------------------------------------------------------------------"

if ssh -o ConnectTimeout=10 -o BatchMode=yes "${NEW_SERVER_USER}@${NEW_SERVER}" "echo 'test'" &>/dev/null; then
    # Docker
    log_info "Проверка Docker на новом сервере..."
    if ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "docker --version" &>/dev/null; then
        NEW_DOCKER_VERSION=$(ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "docker --version")
        check_passed "Docker установлен: $NEW_DOCKER_VERSION"
    else
        check_failed "Docker не установлен на новом сервере"
    fi

    # Docker Compose
    log_info "Проверка Docker Compose на новом сервере..."
    if ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "docker compose version" &>/dev/null; then
        NEW_COMPOSE_VERSION=$(ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "docker compose version")
        check_passed "Docker Compose установлен: $NEW_COMPOSE_VERSION"
    else
        check_failed "Docker Compose не установлен на новом сервере"
    fi

    # PostgreSQL client
    log_info "Проверка PostgreSQL client на новом сервере..."
    if ssh "${NEW_SERVER_USER}@${NEW_SERVER}" "psql --version" &>/dev/null; then
        check_passed "PostgreSQL client установлен"
    else
        check_warning "PostgreSQL client не установлен (может понадобиться для восстановления)"
    fi
else
    check_warning "Не удалось подключиться к новому серверу для проверки ПО"
fi

echo ""

#############################################################################
# Итоговый отчет
#############################################################################

echo "======================================================================"
echo "  ИТОГОВЫЙ ОТЧЕТ"
echo "======================================================================"
echo ""
echo -e "${GREEN}Успешных проверок:${NC} $CHECKS_PASSED"
echo -e "${YELLOW}Предупреждений:${NC} $CHECKS_WARNING"
echo -e "${RED}Неудачных проверок:${NC} $CHECKS_FAILED"
echo ""

if [ $CHECKS_FAILED -eq 0 ] && [ $CHECKS_WARNING -eq 0 ]; then
    echo -e "${GREEN}✓ Система готова к миграции!${NC}"
    echo ""
    echo "Следующие шаги:"
    echo "1. Запустите финальный бэкап: ./scripts/backup.sh"
    echo "2. Запустите скрипт миграции: ./scripts/migrate-to-new.sh"
    exit 0
elif [ $CHECKS_FAILED -eq 0 ]; then
    echo -e "${YELLOW}⚠ Система в основном готова, но есть предупреждения${NC}"
    echo "Рекомендуется устранить предупреждения перед миграцией"
    echo ""
    echo "Продолжить миграцию можно командой: ./scripts/migrate-to-new.sh"
    exit 0
else
    echo -e "${RED}✗ Обнаружены критические проблемы!${NC}"
    echo "Необходимо устранить все ошибки перед миграцией"
    exit 1
fi
