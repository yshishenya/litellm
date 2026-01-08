# Скрипты эксплуатации LiteLLM

В этой папке находятся рабочие скрипты для бэкапов, восстановления, health‑check, офсайт‑синхронизации и безопасных действий с Docker.

## Что есть

- `backup.sh` — локальные бэкапы (БД + Grafana + конфиги) с ротацией и проверками.
- `restore.sh` — интерактивное восстановление из любого бэкапа.
- `health-check.sh` — периодические проверки + уведомления в Telegram.
- `sync-backups.sh` — офсайт‑синхронизация последнего бэкапа через SSH + rsync.
- `telegram-notify.sh` — Telegram уведомления (тест + ручные сообщения).
- `docker-safe.sh` — безопасная обертка над `docker compose`, чтобы избежать потери данных.

## Структура и дефолты

- Корень проекта: `/opt/projects/litellm`
- Локальные бэкапы: `/opt/backups/litellm`
  - `daily/`, `weekly/`, `monthly/`, symlink `latest`
  - `cron.log`, `sync-cron.log`, `.backup_status`

## Требуемые пакеты

- `docker`, `docker compose`
- `psql`, `pg_dump`
- `gzip`, `rsync`, `ssh`, `curl`, `openssl`
- `df`, `free`, `stat`, `find`, `du`

## Настройка .env (обязательно)

Все скрипты читают конфиг из `../.env`, если он есть.

```sh
# Telegram
TELEGRAM_BOT_TOKEN="123456:ABCDEF"
TELEGRAM_CHAT_IDS="-1001234567890,234583347"

# Локальные бэкапы
BACKUP_BASE_DIR="/opt/backups/litellm"

# Офсайт‑бэкапы
BACKUP_REMOTE_HOST="1.2.3.4"
BACKUP_REMOTE_USER="backupuser"
BACKUP_REMOTE_PATH="/opt/backups/projects/litellm"
BACKUP_REMOTE_PORT="22"
BACKUP_RETENTION_DAYS="30"
```

Примечания:
- `TELEGRAM_CHAT_IDS` — список через запятую и имеет приоритет над `TELEGRAM_CHAT_ID`.
- Для chat ID группы добавьте бота в группу и упомяните его, затем получите ID через `getUpdates` (обычно отрицательный).

## Настройка cron (рекомендуется)

Пример расписания:

```cron
0 3 * * * /opt/projects/litellm/scripts/backup.sh >> /opt/backups/litellm/cron.log 2>&1 && /opt/projects/litellm/scripts/sync-backups.sh >> /opt/backups/litellm/sync-cron.log 2>&1
*/15 * * * * /opt/projects/litellm/scripts/health-check.sh >> /opt/projects/litellm/logs/health-check.log 2>&1
```

Проверка:
```sh
crontab -l
```

## Как делается бэкап

1. Дамп БД (gzip) в `postgresql_litellm.sql.gz`.
2. Копирование Grafana provisioning.
3. Копирование конфигов в `configs/` (включая `.env`).
4. Запись инвентаря.
5. Генерация `RESTORE.sh` для быстрого восстановления.
6. Обновление symlink `latest`.
7. Ротация + очистка при нехватке места.

Запуск вручную:
```sh
./scripts/backup.sh
```

## Восстановление

Интерактивно:
```sh
./scripts/restore.sh
```

Прямой путь:
```sh
./scripts/restore.sh /opt/backups/litellm/daily/2026-01-08_030001
```

Безопасность:
- Проверяет наличие и читаемость бэкапа.
- Спрашивает перед восстановлением `.env`.
- Делает резервные копии текущих конфигов.
- Пишет лог восстановления в папку бэкапа.

## Офсайт‑синхронизация

Только последний бэкап:
```sh
./scripts/sync-backups.sh
```

Примечания:
- SSH запускается с `BatchMode=yes` и коротким таймаутом.
- Нужны ключи SSH для пользователя бэкапов.
- Remote‑путь создается автоматически, если его нет.
- Ротация на удаленном сервере по `BACKUP_RETENTION_DAYS`.

## Health Check

Проверяет:
- контейнеры Docker + health status
- API endpoints
- PostgreSQL
- диск и память
- сроки SSL
- локальные и офсайт‑бэкапы
- Nginx

Запуск вручную:
```sh
./scripts/health-check.sh
```

## Уведомления Telegram

Тест:
```sh
./scripts/telegram-notify.sh test
```

Ручное сообщение:
```sh
./scripts/telegram-notify.sh info "Начаты работы по обслуживанию"
```

## Безопасный Docker

Защищает от `docker compose down -v` и других разрушительных команд.

```sh
./scripts/docker-safe.sh up -d
./scripts/docker-safe.sh down
./scripts/docker-safe.sh down -v   # спросит подтверждение + сделает бэкап
```

## Чеклист для нового сервера

1. Поставить зависимости (docker, postgres client, rsync, ssh, curl, openssl).
2. Развернуть проект в `/opt/projects/litellm` (или обновить пути).
3. Создать `/opt/backups/litellm` и выставить права.
4. Заполнить `.env` (Telegram + backup + remote).
5. Настроить SSH ключи для офсайт‑синхронизации.
6. Запустить `./scripts/telegram-notify.sh test`.
7. Запустить `./scripts/backup.sh`.
8. Запустить `./scripts/health-check.sh`.
9. Добавить cron и убедиться, что задачи выполняются.

## Типовые проблемы

- Нет уведомлений Telegram: проверьте токен и chat ID, затем `./scripts/telegram-notify.sh test`.
- Offsite sync не работает: проверьте SSH ключи и `BACKUP_REMOTE_*`.
- Restore падает: смотрите лог восстановления внутри папки бэкапа.
- Health‑check зависает на SSL: убедитесь, что `timeout` установлен (опционально).
