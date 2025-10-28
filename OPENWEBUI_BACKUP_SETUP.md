# Инструкция по настройке системы бэкапов для OpenWebUI

> **Назначение**: Эта инструкция предназначена для LLM-ассистента, который должен настроить полноценную систему бэкапов для OpenWebUI по образцу системы LiteLLM.

## 📋 Содержание

1. [Обзор системы](#обзор-системы)
2. [Архитектура решения](#архитектура-решения)
3. [Шаг 1: Настройка внешних Docker volumes](#шаг-1-настройка-внешних-docker-volumes)
4. [Шаг 2: Создание скриптов бэкапа](#шаг-2-создание-скриптов-бэкапа)
5. [Шаг 3: Скрипт восстановления](#шаг-3-скрипт-восстановления)
6. [Шаг 4: Удаленная синхронизация](#шаг-4-удаленная-синхронизация)
7. [Шаг 5: Telegram уведомления](#шаг-5-telegram-уведомления)
8. [Шаг 6: Docker Safety Wrapper](#шаг-6-docker-safety-wrapper)
9. [Шаг 7: Автоматизация через cron](#шаг-7-автоматизация-через-cron)
10. [Шаг 8: Тестирование](#шаг-8-тестирование)
11. [Шаг 9: Документация](#шаг-9-документация)

---

## Обзор системы

### Что будет создано

Полноценная система бэкапов с:
- ✅ **Защитой от случайного удаления** (внешние Docker volumes)
- ✅ **Автоматическими бэкапами** (ночью в 3:00)
- ✅ **Ротацией бэкапов** (7 дневных, 4 недельных, 12 месячных)
- ✅ **Удаленным хранением** (синхронизация на другой сервер)
- ✅ **Уведомлениями** (Telegram бот)
- ✅ **Безопасностью** (защита от опасных команд Docker)

### Принципы 3-2-1

- **3** копии данных (рабочая + локальный бэкап + удаленный бэкап)
- **2** типа носителей (SSD сервера + удаленный сервер)
- **1** копия offsite (на удаленном сервере)

---

## Архитектура решения

```
OpenWebUI Server
├── Docker Volumes (external) ← Защита от 'docker compose down -v'
│   ├── openwebui_data_external
│   └── openwebui_postgres_data_external (если используется PostgreSQL)
│
├── /backups/ ← Локальные бэкапы
│   ├── daily/   (хранятся 7 дней)
│   ├── weekly/  (хранятся 4 недели)
│   └── monthly/ (хранятся 12 месяцев)
│
├── /scripts/
│   ├── backup.sh          ← Создание бэкапов
│   ├── restore.sh         ← Восстановление
│   ├── sync-remote.sh     ← Синхронизация с удаленным сервером
│   ├── telegram-notify.sh ← Отправка уведомлений
│   └── docker-safe.sh     ← Защита от опасных команд
│
└── Cron Job (3:00 AM)
    └── backup.sh → sync-remote.sh → telegram-notify.sh

Remote Server (65.21.202.252)
└── /backups/openwebui/ ← Удаленные копии
    ├── daily/
    ├── weekly/
    └── monthly/
```

---

## Шаг 1: Настройка внешних Docker volumes

### 1.1 Определите текущие volumes

**Задача**: Найдите в `docker-compose.yml` все volumes, которые нужно защитить.

Для OpenWebUI обычно это:
- База данных (SQLite или PostgreSQL)
- Uploaded files / документы
- Конфигурационные файлы
- Модели (если локально хранятся)

**Пример из OpenWebUI**:
```yaml
volumes:
  openwebui-data:
  postgres-data:  # если используется PostgreSQL
```

### 1.2 Создайте внешние volumes

```bash
# Найдите имена текущих volumes
docker volume ls | grep openwebui

# Создайте внешние volumes
docker volume create openwebui_data_external
docker volume create openwebui_postgres_data_external  # если используется PostgreSQL
```

### 1.3 Мигрируйте данные

**КРИТИЧЕСКИ ВАЖНО**: Перед миграцией создайте резервную копию!

```bash
# Остановите сервисы
cd /path/to/openwebui
docker compose down

# Скопируйте данные из старого volume в новый
docker run --rm \
  -v openwebui_openwebui-data:/source:ro \
  -v openwebui_data_external:/target \
  alpine sh -c "cd /source && cp -a . /target && echo 'OpenWebUI data copied'"

# Если используется PostgreSQL:
docker run --rm \
  -v openwebui_postgres-data:/source:ro \
  -v openwebui_postgres_data_external:/target \
  alpine sh -c "cd /source && cp -a . /target && echo 'PostgreSQL data copied'"
```

### 1.4 Обновите docker-compose.yml

**Замените**:
```yaml
volumes:
  openwebui-data:
  postgres-data:
```

**На**:
```yaml
volumes:
  openwebui-data:
    name: openwebui_data_external
    external: true
  postgres-data:
    name: openwebui_postgres_data_external
    external: true
```

### 1.5 Запустите и проверьте

```bash
# Запустите сервисы
docker compose up -d

# Проверьте что все работает
docker compose ps
docker compose logs --tail 50

# ВАЖНО: Проверьте что данные не потерялись!
# Откройте OpenWebUI в браузере и убедитесь что все на месте

# Проверьте защиту от удаления
docker compose down -v  # volumes НЕ должны удалиться
docker volume ls | grep openwebui_data_external  # должен остаться
```

---

## Шаг 2: Создание скриптов бэкапа

### 2.1 Создайте директорию для скриптов

```bash
cd /path/to/openwebui
mkdir -p scripts
chmod 755 scripts
```

### 2.2 Создайте backup.sh

**Файл**: `scripts/backup.sh`

**Содержимое** (адаптируйте под OpenWebUI):

```bash
#!/bin/bash

#==============================================================================
# OpenWebUI Backup Script
# Создает резервные копии с автоматической ротацией
#==============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# Конфигурация
#------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_ROOT="${PROJECT_DIR}/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DATE_DAILY=$(date +%Y%m%d)
DATE_WEEKLY=$(date +%Y_week%W)
DATE_MONTHLY=$(date +%Y%m)

# Retention periods
DAILY_RETENTION=7
WEEKLY_RETENTION=4
MONTHLY_RETENTION=12

# Telegram notifications (из .env)
if [ -f "${PROJECT_DIR}/.env" ]; then
    source "${PROJECT_DIR}/.env" 2>/dev/null || true
fi

#------------------------------------------------------------------------------
# Функции
#------------------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

send_telegram() {
    local message="$1"
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        "${SCRIPT_DIR}/telegram-notify.sh" info "$message" || true
    fi
}

cleanup_old_backups() {
    local backup_type=$1
    local retention=$2
    local backup_dir="${BACKUP_ROOT}/${backup_type}"

    if [ ! -d "$backup_dir" ]; then
        return
    fi

    log "Cleaning up old ${backup_type} backups (keeping ${retention})..."

    # Найти и удалить старые бэкапы
    find "$backup_dir" -mindepth 1 -maxdepth 1 -type d | \
        sort -r | \
        tail -n +$((retention + 1)) | \
        while read -r old_backup; do
            log "Removing old backup: $(basename "$old_backup")"
            rm -rf "$old_backup"
        done
}

#------------------------------------------------------------------------------
# Определение типа бэкапа
#------------------------------------------------------------------------------

DAY_OF_WEEK=$(date +%u)  # 1=Monday, 7=Sunday
DAY_OF_MONTH=$(date +%d)

if [ "$DAY_OF_MONTH" = "01" ]; then
    BACKUP_TYPE="monthly"
    BACKUP_DATE="$DATE_MONTHLY"
    log "Creating MONTHLY backup"
elif [ "$DAY_OF_WEEK" = "7" ]; then
    BACKUP_TYPE="weekly"
    BACKUP_DATE="$DATE_WEEKLY"
    log "Creating WEEKLY backup"
else
    BACKUP_TYPE="daily"
    BACKUP_DATE="$DATE_DAILY"
    log "Creating DAILY backup"
fi

BACKUP_DIR="${BACKUP_ROOT}/${BACKUP_TYPE}/${BACKUP_DATE}_${TIMESTAMP}"

#------------------------------------------------------------------------------
# Создание директорий
#------------------------------------------------------------------------------

mkdir -p "$BACKUP_DIR"
log "Backup directory: $BACKUP_DIR"

#------------------------------------------------------------------------------
# Бэкап базы данных
#------------------------------------------------------------------------------

log "Backing up database..."

# Для SQLite (если используется)
if docker compose exec -T openwebui test -f /app/backend/data/webui.db 2>/dev/null; then
    docker compose exec -T openwebui sqlite3 /app/backend/data/webui.db .dump > "${BACKUP_DIR}/sqlite_webui.sql"
    log "SQLite database backed up"
fi

# Для PostgreSQL (если используется)
if docker compose exec -T db pg_isready -U openwebui 2>/dev/null; then
    PGPASSWORD="${DB_PASSWORD:-openwebui}" docker compose exec -T db \
        pg_dump -U "${DB_USER:-openwebui}" "${DB_NAME:-openwebui}" \
        > "${BACKUP_DIR}/postgresql_openwebui.sql"
    log "PostgreSQL database backed up"
fi

#------------------------------------------------------------------------------
# Бэкап Docker volumes
#------------------------------------------------------------------------------

log "Backing up Docker volumes..."

# OpenWebUI data volume
docker run --rm \
    -v openwebui_data_external:/source:ro \
    -v "${BACKUP_DIR}:/backup" \
    alpine tar czf /backup/openwebui_data.tar.gz -C /source .

log "OpenWebUI data backed up"

# PostgreSQL data (если используется)
if docker volume ls | grep -q openwebui_postgres_data_external; then
    docker run --rm \
        -v openwebui_postgres_data_external:/source:ro \
        -v "${BACKUP_DIR}:/backup" \
        alpine tar czf /backup/postgres_data.tar.gz -C /source .
    log "PostgreSQL data backed up"
fi

#------------------------------------------------------------------------------
# Бэкап конфигурационных файлов
#------------------------------------------------------------------------------

log "Backing up configuration files..."

# docker-compose.yml
if [ -f "${PROJECT_DIR}/docker-compose.yml" ]; then
    cp "${PROJECT_DIR}/docker-compose.yml" "${BACKUP_DIR}/"
fi

# .env (если есть)
if [ -f "${PROJECT_DIR}/.env" ]; then
    cp "${PROJECT_DIR}/.env" "${BACKUP_DIR}/"
fi

# Любые другие конфигурационные файлы
# Добавьте здесь специфичные для OpenWebUI файлы

#------------------------------------------------------------------------------
# Создание инвентарного файла
#------------------------------------------------------------------------------

cat > "${BACKUP_DIR}/BACKUP_INVENTORY.txt" << EOF
OpenWebUI Backup Inventory
==========================
Created: $(date '+%Y-%m-%d %H:%M:%S')
Type: ${BACKUP_TYPE}
Hostname: $(hostname)
Server IP: $(hostname -I | awk '{print $1}')

Files in this backup:
EOF

ls -lh "$BACKUP_DIR" >> "${BACKUP_DIR}/BACKUP_INVENTORY.txt"

#------------------------------------------------------------------------------
# Создание скрипта восстановления
#------------------------------------------------------------------------------

cat > "${BACKUP_DIR}/RESTORE.sh" << 'RESTORE_SCRIPT'
#!/bin/bash
set -euo pipefail

echo "=== OpenWebUI Backup Restoration ==="
echo "Backup from: BACKUP_DATE"
echo ""
echo "WARNING: This will replace your current OpenWebUI data!"
echo "Make sure you have stopped the services: docker compose down"
echo ""
read -p "Continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Restoration cancelled"
    exit 1
fi

BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$(dirname "$BACKUP_DIR")")")"

echo "Restoring from: $BACKUP_DIR"
echo "Project directory: $PROJECT_DIR"

# Restore database
if [ -f "${BACKUP_DIR}/sqlite_webui.sql" ]; then
    echo "Restoring SQLite database..."
    # Add SQLite restore commands
fi

if [ -f "${BACKUP_DIR}/postgresql_openwebui.sql" ]; then
    echo "Restoring PostgreSQL database..."
    # Add PostgreSQL restore commands
fi

# Restore volumes
if [ -f "${BACKUP_DIR}/openwebui_data.tar.gz" ]; then
    echo "Restoring OpenWebUI data..."
    docker run --rm \
        -v openwebui_data_external:/target \
        -v "${BACKUP_DIR}:/backup:ro" \
        alpine sh -c "rm -rf /target/* && tar xzf /backup/openwebui_data.tar.gz -C /target"
fi

echo ""
echo "✅ Restoration complete!"
echo "Start services: cd $PROJECT_DIR && docker compose up -d"
RESTORE_SCRIPT

chmod +x "${BACKUP_DIR}/RESTORE.sh"

#------------------------------------------------------------------------------
# Подсчет статистики
#------------------------------------------------------------------------------

BACKUP_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
FILE_COUNT=$(find "$BACKUP_DIR" -type f | wc -l)

log "Backup completed: ${BACKUP_SIZE}, ${FILE_COUNT} files"

#------------------------------------------------------------------------------
# Создание симлинка на последний бэкап
#------------------------------------------------------------------------------

ln -sfn "$BACKUP_DIR" "${BACKUP_ROOT}/latest"

#------------------------------------------------------------------------------
# Ротация старых бэкапов
#------------------------------------------------------------------------------

cleanup_old_backups "daily" $DAILY_RETENTION
cleanup_old_backups "weekly" $WEEKLY_RETENTION
cleanup_old_backups "monthly" $MONTHLY_RETENTION

#------------------------------------------------------------------------------
# Отправка уведомления
#------------------------------------------------------------------------------

send_telegram "✅ OpenWebUI Backup Complete
Type: ${BACKUP_TYPE}
Size: ${BACKUP_SIZE}
Files: ${FILE_COUNT}
Location: ${BACKUP_DIR}"

log "All done! ✅"
```

### 2.3 Сделайте скрипт исполняемым

```bash
chmod +x scripts/backup.sh
```

---

## Шаг 3: Скрипт восстановления

### 3.1 Создайте restore.sh

**Файл**: `scripts/restore.sh`

```bash
#!/bin/bash

#==============================================================================
# OpenWebUI Restore Script
# Восстанавливает данные из резервной копии
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_ROOT="${PROJECT_DIR}/backups"

#------------------------------------------------------------------------------
# Функции
#------------------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

#------------------------------------------------------------------------------
# Выбор бэкапа
#------------------------------------------------------------------------------

echo "=== OpenWebUI Backup Restoration ==="
echo ""
echo "Available backups:"
echo ""

# Показать все доступные бэкапы
find "$BACKUP_ROOT" -mindepth 2 -maxdepth 2 -type d | sort -r | nl

echo ""
read -p "Enter backup number (or 'latest' for most recent): " choice

if [ "$choice" = "latest" ]; then
    BACKUP_DIR="${BACKUP_ROOT}/latest"
    if [ ! -d "$BACKUP_DIR" ]; then
        error "No latest backup found"
        exit 1
    fi
else
    BACKUP_DIR=$(find "$BACKUP_ROOT" -mindepth 2 -maxdepth 2 -type d | sort -r | sed -n "${choice}p")
    if [ ! -d "$BACKUP_DIR" ]; then
        error "Invalid backup selection"
        exit 1
    fi
fi

echo ""
echo "Selected backup: $BACKUP_DIR"
echo ""

#------------------------------------------------------------------------------
# Подтверждение
#------------------------------------------------------------------------------

echo "⚠️  WARNING: This will REPLACE your current OpenWebUI data!"
echo ""
echo "Backup contains:"
ls -lh "$BACKUP_DIR"
echo ""
read -p "Are you sure? Type 'yes' to continue: " confirm

if [ "$confirm" != "yes" ]; then
    log "Restoration cancelled"
    exit 0
fi

#------------------------------------------------------------------------------
# Проверка что сервисы остановлены
#------------------------------------------------------------------------------

log "Checking if services are stopped..."

if docker compose ps | grep -q "Up"; then
    error "Services are still running! Please stop them first:"
    echo "  cd $PROJECT_DIR && docker compose down"
    exit 1
fi

#------------------------------------------------------------------------------
# Восстановление
#------------------------------------------------------------------------------

log "Starting restoration..."

# Восстановление volumes
if [ -f "${BACKUP_DIR}/openwebui_data.tar.gz" ]; then
    log "Restoring OpenWebUI data volume..."
    docker run --rm \
        -v openwebui_data_external:/target \
        -v "${BACKUP_DIR}:/backup:ro" \
        alpine sh -c "rm -rf /target/* /target/..?* /target/.[!.]* 2>/dev/null || true; tar xzf /backup/openwebui_data.tar.gz -C /target"
    log "✅ OpenWebUI data restored"
fi

if [ -f "${BACKUP_DIR}/postgres_data.tar.gz" ]; then
    log "Restoring PostgreSQL data volume..."
    docker run --rm \
        -v openwebui_postgres_data_external:/target \
        -v "${BACKUP_DIR}:/backup:ro" \
        alpine sh -c "rm -rf /target/* /target/..?* /target/.[!.]* 2>/dev/null || true; tar xzf /backup/postgres_data.tar.gz -C /target"
    log "✅ PostgreSQL data restored"
fi

# Восстановление базы данных (если нужно)
# Добавьте команды восстановления БД здесь

#------------------------------------------------------------------------------
# Завершение
#------------------------------------------------------------------------------

log "✅ Restoration complete!"
echo ""
echo "Next steps:"
echo "  1. Start services: cd $PROJECT_DIR && docker compose up -d"
echo "  2. Check logs: docker compose logs -f"
echo "  3. Verify in browser"
echo ""
```

### 3.2 Сделайте скрипт исполняемым

```bash
chmod +x scripts/restore.sh
```

---

## Шаг 4: Удаленная синхронизация

### 4.1 Настройте SSH ключи

**На локальном сервере** (где OpenWebUI):

```bash
# Создайте SSH ключ если нет
ssh-keygen -t ed25519 -f ~/.ssh/openwebui_backup -C "openwebui-backup"

# Скопируйте ключ на удаленный сервер
ssh-copy-id -i ~/.ssh/openwebui_backup yan@65.21.202.252

# Проверьте подключение
ssh -i ~/.ssh/openwebui_backup yan@65.21.202.252 "echo 'SSH работает!'"
```

**На удаленном сервере**:

```bash
# Создайте директорию для бэкапов
mkdir -p /home/yan/backups/openwebui/{daily,weekly,monthly}
chmod 700 /home/yan/backups
```

### 4.2 Создайте sync-remote.sh

**Файл**: `scripts/sync-remote.sh`

```bash
#!/bin/bash

#==============================================================================
# OpenWebUI Remote Sync Script
# Синхронизирует локальные бэкапы на удаленный сервер
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Загрузить конфигурацию из .env
if [ -f "${PROJECT_DIR}/.env" ]; then
    source "${PROJECT_DIR}/.env" 2>/dev/null || true
fi

# Конфигурация удаленного сервера
REMOTE_HOST="${BACKUP_REMOTE_HOST:-65.21.202.252}"
REMOTE_USER="${BACKUP_REMOTE_USER:-yan}"
REMOTE_PATH="${BACKUP_REMOTE_PATH:-/home/yan/backups/openwebui}"
REMOTE_PORT="${BACKUP_REMOTE_PORT:-22}"
SSH_KEY="${BACKUP_SSH_KEY:-$HOME/.ssh/openwebui_backup}"

LOCAL_BACKUP_DIR="${PROJECT_DIR}/backups"

#------------------------------------------------------------------------------
# Функции
#------------------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

send_telegram() {
    local level="$1"
    local message="$2"
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        "${SCRIPT_DIR}/telegram-notify.sh" "$level" "$message" || true
    fi
}

#------------------------------------------------------------------------------
# Проверки
#------------------------------------------------------------------------------

if [ ! -f "$SSH_KEY" ]; then
    error "SSH key not found: $SSH_KEY"
    send_telegram "error" "❌ Remote sync failed: SSH key not found"
    exit 1
fi

# Проверка SSH подключения
if ! ssh -o ConnectTimeout=10 -i "$SSH_KEY" -p "$REMOTE_PORT" \
    "${REMOTE_USER}@${REMOTE_HOST}" "echo 'Connection OK'" >/dev/null 2>&1; then
    error "Cannot connect to remote server"
    send_telegram "error" "❌ Remote sync failed: Cannot connect to $REMOTE_HOST"
    exit 1
fi

#------------------------------------------------------------------------------
# Синхронизация
#------------------------------------------------------------------------------

log "Starting remote synchronization to ${REMOTE_USER}@${REMOTE_HOST}"

RSYNC_OPTS=(
    -avz
    --partial
    --progress
    --delete
    --stats
    -e "ssh -i $SSH_KEY -p $REMOTE_PORT"
)

# Синхронизация daily бэкапов
if [ -d "${LOCAL_BACKUP_DIR}/daily" ]; then
    log "Syncing daily backups..."
    rsync "${RSYNC_OPTS[@]}" \
        "${LOCAL_BACKUP_DIR}/daily/" \
        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/daily/" \
        2>&1 | tee /tmp/rsync_daily.log
fi

# Синхронизация weekly бэкапов
if [ -d "${LOCAL_BACKUP_DIR}/weekly" ]; then
    log "Syncing weekly backups..."
    rsync "${RSYNC_OPTS[@]}" \
        "${LOCAL_BACKUP_DIR}/weekly/" \
        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/weekly/" \
        2>&1 | tee /tmp/rsync_weekly.log
fi

# Синхронизация monthly бэкапов
if [ -d "${LOCAL_BACKUP_DIR}/monthly" ]; then
    log "Syncing monthly backups..."
    rsync "${RSYNC_OPTS[@]}" \
        "${LOCAL_BACKUP_DIR}/monthly/" \
        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/monthly/" \
        2>&1 | tee /tmp/rsync_monthly.log
fi

#------------------------------------------------------------------------------
# Статистика
#------------------------------------------------------------------------------

# Подсчет размера на удаленном сервере
REMOTE_SIZE=$(ssh -i "$SSH_KEY" -p "$REMOTE_PORT" \
    "${REMOTE_USER}@${REMOTE_HOST}" \
    "du -sh ${REMOTE_PATH} 2>/dev/null | cut -f1" || echo "unknown")

log "✅ Remote sync complete!"
log "Remote backup size: $REMOTE_SIZE"

send_telegram "success" "✅ Remote Sync Complete
Server: ${REMOTE_HOST}
Size: ${REMOTE_SIZE}"
```

### 4.3 Добавьте настройки в .env

```bash
# Remote Backup Server
BACKUP_REMOTE_HOST="65.21.202.252"
BACKUP_REMOTE_USER="yan"
BACKUP_REMOTE_PATH="/home/yan/backups/openwebui"
BACKUP_REMOTE_PORT="22"
BACKUP_SSH_KEY="$HOME/.ssh/openwebui_backup"
```

### 4.4 Сделайте скрипт исполняемым

```bash
chmod +x scripts/sync-remote.sh
```

---

## Шаг 5: Telegram уведомления

### 5.1 Создайте Telegram бота

1. Откройте Telegram и найдите [@BotFather](https://t.me/BotFather)
2. Отправьте команду `/newbot`
3. Следуйте инструкциям (имя бота, username)
4. Скопируйте токен (например: `1234567890:ABCdefGHIjklMNOpqrsTUVwxyz`)

### 5.2 Получите Chat ID

1. Найдите вашего бота в Telegram
2. Нажмите START
3. Получите chat ID:
```bash
curl "https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates" | grep chat
```

### 5.3 Создайте telegram-notify.sh

**Файл**: `scripts/telegram-notify.sh`

```bash
#!/bin/bash

#==============================================================================
# Telegram Notification Script
# Отправляет уведомления в Telegram
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Загрузить настройки из .env
if [ -f "${PROJECT_DIR}/.env" ]; then
    source "${PROJECT_DIR}/.env" 2>/dev/null || true
fi

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"

#------------------------------------------------------------------------------
# Проверка конфигурации
#------------------------------------------------------------------------------

if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "Telegram not configured. Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in .env"
    exit 0
fi

#------------------------------------------------------------------------------
# Параметры
#------------------------------------------------------------------------------

LEVEL="${1:-info}"
MESSAGE="${2:-Test message}"

# Эмодзи в зависимости от уровня
case "$LEVEL" in
    success)
        ICON="✅"
        ;;
    error)
        ICON="❌"
        ;;
    warning)
        ICON="⚠️"
        ;;
    info)
        ICON="ℹ️"
        ;;
    *)
        ICON="📝"
        ;;
esac

#------------------------------------------------------------------------------
# Формирование сообщения
#------------------------------------------------------------------------------

FULL_MESSAGE="${ICON} **OpenWebUI Backup**

${MESSAGE}

Server: $(hostname)
Time: $(date '+%Y-%m-%d %H:%M:%S')"

#------------------------------------------------------------------------------
# Отправка
#------------------------------------------------------------------------------

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${CHAT_ID}" \
    -d text="${FULL_MESSAGE}" \
    -d parse_mode="Markdown" \
    > /dev/null

if [ $? -eq 0 ]; then
    echo "✅ Telegram notification sent"
else
    echo "❌ Failed to send Telegram notification"
    exit 1
fi
```

### 5.4 Добавьте настройки в .env

```bash
# Telegram Bot Notifications
TELEGRAM_BOT_TOKEN="your_bot_token_here"
TELEGRAM_CHAT_ID="your_chat_id_here"
```

### 5.5 Сделайте скрипт исполняемым и протестируйте

```bash
chmod +x scripts/telegram-notify.sh

# Тест
./scripts/telegram-notify.sh success "Test notification!"
```

---

## Шаг 6: Docker Safety Wrapper

### 6.1 Создайте docker-safe.sh

**Файл**: `scripts/docker-safe.sh`

```bash
#!/bin/bash

#==============================================================================
# Docker Safety Wrapper
# Защищает от случайного удаления volumes
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

COMMAND="$*"

#------------------------------------------------------------------------------
# Опасные паттерны
#------------------------------------------------------------------------------

DANGEROUS_PATTERNS=(
    "down -v"
    "down.*-v"
    "compose down -v"
    "volume prune"
    "volume rm"
    "rm -f.*volume"
)

#------------------------------------------------------------------------------
# Проверка команды
#------------------------------------------------------------------------------

IS_DANGEROUS=false

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
    if echo "$COMMAND" | grep -qE "$pattern"; then
        IS_DANGEROUS=true
        break
    fi
done

if [ "$IS_DANGEROUS" = false ]; then
    # Безопасная команда - выполняем сразу
    exec docker $COMMAND
fi

#------------------------------------------------------------------------------
# Опасная команда - требуем подтверждения
#------------------------------------------------------------------------------

echo ""
echo "⚠️  WARNING: DANGEROUS DOCKER COMMAND DETECTED! ⚠️"
echo ""
echo "Command: docker $COMMAND"
echo ""
echo "This command may DELETE Docker volumes and ALL DATA!"
echo ""
echo "Before proceeding:"
echo "  1. Make sure you have a recent backup"
echo "  2. Understand the consequences"
echo ""

read -p "Type 'I UNDERSTAND THE RISKS' to continue: " confirm

if [ "$confirm" != "I UNDERSTAND THE RISKS" ]; then
    echo "❌ Command cancelled"
    exit 1
fi

echo ""
echo "⚠️  FINAL CONFIRMATION ⚠️"
echo ""
read -p "Type 'YES DELETE' to execute: " final_confirm

if [ "$final_confirm" != "YES DELETE" ]; then
    echo "❌ Command cancelled"
    exit 1
fi

#------------------------------------------------------------------------------
# Автоматический бэкап перед опасной операцией
#------------------------------------------------------------------------------

echo ""
echo "Creating emergency backup before executing dangerous command..."
"${SCRIPT_DIR}/backup.sh"

if [ $? -eq 0 ]; then
    echo "✅ Emergency backup created"
else
    echo "❌ Backup failed!"
    read -p "Continue anyway? (yes/no): " continue_anyway
    if [ "$continue_anyway" != "yes" ]; then
        echo "❌ Command cancelled"
        exit 1
    fi
fi

#------------------------------------------------------------------------------
# Выполнение команды
#------------------------------------------------------------------------------

echo ""
echo "Executing: docker $COMMAND"
exec docker $COMMAND
```

### 6.2 Создайте alias

Добавьте в `~/.bashrc` или `~/.zshrc`:

```bash
# Docker Safety Wrapper для OpenWebUI
alias docker-compose='/path/to/openwebui/scripts/docker-safe.sh compose'
```

Примените:
```bash
source ~/.bashrc  # или ~/.zshrc
```

### 6.3 Сделайте скрипт исполняемым

```bash
chmod +x scripts/docker-safe.sh
```

---

## Шаг 7: Автоматизация через cron

### 7.1 Настройте cron job

```bash
# Откройте crontab
crontab -e

# Добавьте задачу (каждую ночь в 3:00)
0 3 * * * /path/to/openwebui/scripts/backup.sh >> /path/to/openwebui/backup.log 2>&1 && /path/to/openwebui/scripts/sync-remote.sh >> /path/to/openwebui/sync.log 2>&1
```

**Замените `/path/to/openwebui` на реальный путь!**

### 7.2 Проверьте что cron работает

```bash
# Проверьте список задач
crontab -l

# Проверьте что cron daemon запущен
systemctl status cron  # или crond
```

---

## Шаг 8: Тестирование

### 8.1 Тестирование локального бэкапа

```bash
cd /path/to/openwebui

# Создайте тестовый бэкап
./scripts/backup.sh

# Проверьте что бэкап создан
ls -lh backups/daily/
ls -lh backups/latest/

# Проверьте содержимое
cat backups/latest/BACKUP_INVENTORY.txt
```

### 8.2 Тестирование удаленной синхронизации

```bash
# Запустите синхронизацию
./scripts/sync-remote.sh

# Проверьте на удаленном сервере
ssh yan@65.21.202.252 "ls -lh /home/yan/backups/openwebui/daily/"
```

### 8.3 Тестирование восстановления

**ВАЖНО**: Тестируйте на ТЕСТОВОЙ системе!

```bash
# Остановите сервисы
docker compose down

# Запустите восстановление
./scripts/restore.sh

# Выберите latest backup
# Подтвердите восстановление

# Запустите сервисы
docker compose up -d

# Проверьте логи
docker compose logs -f
```

### 8.4 Тестирование Telegram уведомлений

```bash
./scripts/telegram-notify.sh success "Тест успешного уведомления"
./scripts/telegram-notify.sh error "Тест ошибки"
./scripts/telegram-notify.sh warning "Тест предупреждения"
./scripts/telegram-notify.sh info "Тест информации"
```

### 8.5 Тестирование Docker Safety

```bash
# Попробуйте опасную команду
docker-compose down -v

# Должно запросить подтверждение и создать бэкап
```

---

## Шаг 9: Документация

### 9.1 Создайте BACKUP_GUIDE.md

**Файл**: `BACKUP_GUIDE.md`

```markdown
# OpenWebUI Backup System Guide

> **✅ СТАТУС: Система полностью настроена и работает!**
> - ✅ Автоматические бэкапы каждую ночь в 3:00
> - ✅ Удаленная синхронизация на 65.21.202.252
> - ✅ Telegram уведомления настроены
> - 📅 Дата настройки: [ДАТА]

## Быстрый старт

### Создать бэкап вручную
\`\`\`bash
cd /path/to/openwebui
./scripts/backup.sh
\`\`\`

### Восстановить из бэкапа
\`\`\`bash
cd /path/to/openwebui
docker compose down
./scripts/restore.sh
docker compose up -d
\`\`\`

### Проверить удаленные бэкапы
\`\`\`bash
ssh yan@65.21.202.252 "ls -lh /home/yan/backups/openwebui/daily/"
\`\`\`

## Архитектура

[Скопируйте сюда информацию из раздела "Архитектура решения"]

## Ротация бэкапов

- **Daily**: 7 дней
- **Weekly**: 4 недели
- **Monthly**: 12 месяцев

## Расположение бэкапов

- **Локальные**: `/path/to/openwebui/backups/`
- **Удаленные**: `yan@65.21.202.252:/home/yan/backups/openwebui/`
- **Последний**: `/path/to/openwebui/backups/latest` (симлинк)

## Что бэкапится

- ✅ База данных (SQLite или PostgreSQL)
- ✅ Uploaded files
- ✅ Docker volumes
- ✅ Конфигурационные файлы (.env, docker-compose.yml)

## Автоматизация

Cron job запускается каждую ночь в 3:00:
\`\`\`
0 3 * * * /path/to/openwebui/scripts/backup.sh && /path/to/openwebui/scripts/sync-remote.sh
\`\`\`

## Мониторинг

Проверить логи:
\`\`\`bash
tail -f /path/to/openwebui/backup.log
tail -f /path/to/openwebui/sync.log
\`\`\`

## Troubleshooting

[Добавьте типичные проблемы и решения]
```

### 9.2 Создайте README.md для scripts/

**Файл**: `scripts/README.md`

```markdown
# OpenWebUI Backup Scripts

Набор скриптов для автоматизации резервного копирования OpenWebUI.

## Скрипты

### backup.sh
Создает резервные копии с автоматической ротацией.

**Использование**:
\`\`\`bash
./backup.sh
\`\`\`

### restore.sh
Восстанавливает данные из резервной копии.

**Использование**:
\`\`\`bash
docker compose down
./restore.sh
docker compose up -d
\`\`\`

### sync-remote.sh
Синхронизирует локальные бэкапы на удаленный сервер.

**Использование**:
\`\`\`bash
./sync-remote.sh
\`\`\`

### telegram-notify.sh
Отправляет уведомления в Telegram.

**Использование**:
\`\`\`bash
./telegram-notify.sh [level] "[message]"

# Примеры:
./telegram-notify.sh success "Backup complete"
./telegram-notify.sh error "Backup failed"
./telegram-notify.sh warning "Disk space low"
./telegram-notify.sh info "Starting backup"
\`\`\`

### docker-safe.sh
Защищает от случайного удаления Docker volumes.

**Использование**:
\`\`\`bash
# Создайте alias в ~/.bashrc:
alias docker-compose='/path/to/openwebui/scripts/docker-safe.sh compose'
\`\`\`

## Конфигурация

Все настройки в файле `.env`:

\`\`\`bash
# Remote Backup Server
BACKUP_REMOTE_HOST="65.21.202.252"
BACKUP_REMOTE_USER="yan"
BACKUP_REMOTE_PATH="/home/yan/backups/openwebui"

# Telegram Bot
TELEGRAM_BOT_TOKEN="your_token"
TELEGRAM_CHAT_ID="your_chat_id"
\`\`\`
```

---

## Чеклист для LLM

При выполнении настройки следуйте этому чеклисту:

- [ ] **Шаг 1**: Создать внешние Docker volumes
  - [ ] Остановить сервисы
  - [ ] Создать внешние volumes
  - [ ] Скопировать данные
  - [ ] Обновить docker-compose.yml
  - [ ] Запустить и проверить

- [ ] **Шаг 2**: Создать backup.sh
  - [ ] Создать директорию scripts/
  - [ ] Адаптировать скрипт под OpenWebUI
  - [ ] Сделать исполняемым
  - [ ] Протестировать

- [ ] **Шаг 3**: Создать restore.sh
  - [ ] Создать скрипт
  - [ ] Сделать исполняемым
  - [ ] Протестировать (на тестовой системе!)

- [ ] **Шаг 4**: Настроить удаленную синхронизацию
  - [ ] Создать SSH ключи
  - [ ] Настроить доступ к удаленному серверу
  - [ ] Создать sync-remote.sh
  - [ ] Добавить настройки в .env
  - [ ] Протестировать

- [ ] **Шаг 5**: Настроить Telegram
  - [ ] Создать бота через @BotFather
  - [ ] Получить Chat ID
  - [ ] Создать telegram-notify.sh
  - [ ] Добавить настройки в .env
  - [ ] Протестировать

- [ ] **Шаг 6**: Создать Docker Safety Wrapper
  - [ ] Создать docker-safe.sh
  - [ ] Создать alias
  - [ ] Протестировать

- [ ] **Шаг 7**: Настроить автоматизацию
  - [ ] Добавить cron job
  - [ ] Проверить что работает

- [ ] **Шаг 8**: Провести тестирование
  - [ ] Тест локального бэкапа
  - [ ] Тест удаленной синхронизации
  - [ ] Тест восстановления
  - [ ] Тест Telegram уведомлений
  - [ ] Тест Docker Safety

- [ ] **Шаг 9**: Создать документацию
  - [ ] BACKUP_GUIDE.md
  - [ ] scripts/README.md
  - [ ] Обновить основной README проекта

---

## Важные замечания

1. **Пути**: Замените `/path/to/openwebui` на реальный путь к проекту
2. **Имена volumes**: Проверьте реальные имена Docker volumes для OpenWebUI
3. **База данных**: OpenWebUI может использовать SQLite или PostgreSQL - адаптируйте скрипты
4. **Специфичные файлы**: Добавьте в бэкап любые специфичные для OpenWebUI файлы
5. **Тестирование**: ВСЕГДА тестируйте восстановление на тестовой системе сначала!

---

## Поддержка

Если возникнут проблемы:
1. Проверьте логи: `tail -f backup.log sync.log`
2. Проверьте права доступа: `ls -la scripts/`
3. Проверьте SSH: `ssh -vvv yan@65.21.202.252`
4. Проверьте Telegram: `./scripts/telegram-notify.sh info "test"`

---

**Готово!** Система бэкапов настроена и готова к работе! 🎉
