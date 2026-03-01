# LiteLLM Production Runbook

Операционное руководство для управления LiteLLM в production.

---

## 🚨 Быстрый доступ к критическим операциям

### Экстренное восстановление сервиса
```bash
# 1. Проверка статуса
ssh yan@142.252.220.116
cd /home/yan/litellm
docker compose ps

# 2. Перезапуск всех сервисов
docker compose restart

# 3. Проверка логов
docker compose logs --tail 100 litellm
```

### Восстановление из бэкапа
```bash
# См. раздел "Disaster Recovery" ниже
cd /home/yan/litellm/backups/latest
./RESTORE.sh
```

---

## 📊 Мониторинг и health checks

### Ежедневная проверка (автоматическая)
```bash
# Запускается автоматически каждые 15 минут через cron
/home/yan/litellm/scripts/health-check.sh
```

### Ручная проверка
```bash
ssh yan@142.252.220.116
cd /home/yan/litellm

# Быстрая проверка всех сервисов
./scripts/health-check.sh

# Проверка конкретного сервиса
docker logs litellm-litellm-1 --tail 50
docker logs litellm_db --tail 50
docker logs litellm-grafana-1 --tail 50

# Проверка API
curl https://litellm.pro-4.ru/health/liveliness
curl https://dash.pro-4.ru/api/health
```

### Метрики в Grafana
- URL: https://dash.pro-4.ru
- Логин: `admin`
- Пароль: `admin123`
- Дашборды:
  - Teams Dashboard (по командам)
  - OpenWebUI User Dashboard (по пользователям)

---

## 🔧 Распространенные проблемы и решения

### 1. LiteLLM API не отвечает

**Симптомы:**
- `curl https://litellm.pro-4.ru/health/liveliness` возвращает ошибку
- В Grafana нет новых метрик

**Диагностика:**
```bash
# Проверить статус контейнера
docker ps | grep litellm-litellm

# Проверить логи
docker logs litellm-litellm-1 --tail 100

# Проверить конфигурацию
cat /home/yan/litellm/config.yaml

# Проверить переменные окружения
docker exec litellm-litellm-1 env | grep LITELLM
```

**Решение:**
```bash
# Вариант 1: Перезапуск контейнера
docker compose restart litellm

# Вариант 2: Полный перезапуск
docker compose down
docker compose up -d

# Вариант 3: Проверка базы данных
docker exec litellm_db psql -U llmproxy -d litellm -c "SELECT COUNT(*) FROM \"LiteLLM_SpendLogs\""
```

---

### 2. PostgreSQL недоступна

**Симптомы:**
- Ошибки подключения к БД в логах LiteLLM
- `docker exec litellm_db pg_isready` возвращает ошибку

**Диагностика:**
```bash
# Проверить статус
docker ps | grep litellm_db

# Проверить логи
docker logs litellm_db --tail 100

# Проверить подключение
docker exec litellm_db pg_isready -U llmproxy -d litellm

# Проверить размер базы
docker exec litellm_db psql -U llmproxy -d litellm -c "SELECT pg_size_pretty(pg_database_size('litellm'))"
```

**Решение:**
```bash
# Вариант 1: Перезапуск
docker compose restart db

# Вариант 2: Проверка connections
docker exec litellm_db psql -U llmproxy -d litellm -c "SELECT COUNT(*) FROM pg_stat_activity"

# Вариант 3: Восстановление из бэкапа (КРИТИЧНО!)
cd /home/yan/litellm/backups/latest
./RESTORE.sh
```

---

### 3. Grafana не показывает данные

**Симптомы:**
- Дашборды пустые или показывают "No data"
- Datasource не работает

**Диагностика:**
```bash
# Проверить Prometheus
curl -s http://localhost:9092/-/healthy

# Проверить метрики
curl -s http://localhost:9093/metrics | grep litellm_spend

# Проверить Grafana логи
docker logs litellm-grafana-1 --tail 50

# Проверить datasource в Grafana UI
# Settings → Data Sources → Prometheus
```

**Решение:**
```bash
# Перезапуск связанных сервисов
docker compose restart prometheus grafana litellm-metrics-exporter

# Проверка сбора метрик
docker logs litellm-metrics-exporter-1 --tail 50

# Ручная проверка метрик Prometheus
curl -s 'http://localhost:9092/api/v1/query?query=litellm_spend_usd_total'
```

---

### 4. SSL сертификат истекает

**Симптомы:**
- Браузер показывает предупреждение о сертификате
- Health check показывает менее 7 дней до истечения

**Диагностика:**
```bash
# Проверить сертификаты
sudo certbot certificates

# Проверить дату истечения
echo | openssl s_client -servername litellm.pro-4.ru -connect litellm.pro-4.ru:443 2>/dev/null | \
  openssl x509 -noout -dates
```

**Решение:**
```bash
# Обновить сертификаты вручную
sudo certbot renew

# Или принудительно
sudo certbot renew --force-renewal

# Перезагрузить nginx
sudo systemctl reload nginx

# Проверка автообновления (должно быть настроено)
sudo systemctl status certbot.timer
```

---

### 5. Диск переполнен

**Симптомы:**
- Health check показывает >90% использования диска
- Сервисы падают с ошибками I/O

**Диагностика:**
```bash
# Проверить использование диска
df -h

# Найти большие файлы
du -sh /var/lib/docker/* | sort -h
du -sh /home/yan/litellm/backups/* | sort -h

# Проверить логи Docker
du -sh /var/lib/docker/containers/*
```

**Решение:**
```bash
# 1. Очистить старые Docker логи
docker system prune -a --volumes

# 2. Удалить старые бэкапы вручную
cd /home/yan/litellm/backups/daily
ls -lt | tail -n +8 | awk '{print $9}' | xargs rm -rf

# 3. Очистить логи Nginx
sudo truncate -s 0 /var/log/nginx/access.log
sudo truncate -s 0 /var/log/nginx/error.log

# 4. Настроить ротацию логов (если не настроено)
sudo /home/yan/litellm/scripts/setup-docker-logging.sh
```

---

### 6. Бэкапы не создаются

**Симптомы:**
- Последний бэкап старше 25 часов
- Health check показывает ошибку бэкапа
- Нет новых файлов в `/home/yan/litellm/backups/`

**Диагностика:**
```bash
# Проверить cron
crontab -l | grep backup

# Проверить логи бэкапов
tail -50 /home/yan/litellm/backups/cron.log
tail -50 /home/yan/litellm/backups/sync-cron.log

# Проверить статус офсайт бэкапа
ssh yan@162.120.16.66 "ls -lah /opt/backups/projects/litellm/ | tail"
```

**Решение:**
```bash
# Запустить бэкап вручную
cd /home/yan/litellm
./scripts/backup.sh

# Проверить синхронизацию
./scripts/sync-backups.sh

# Проверить права на файлы
ls -lah scripts/backup.sh scripts/sync-backups.sh

# Восстановить cron если нужно
(crontab -l 2>/dev/null; echo "0 3 * * * /home/yan/litellm/scripts/backup.sh >> /home/yan/litellm/backups/cron.log 2>&1 && /home/yan/litellm/scripts/sync-backups.sh >> /home/yan/litellm/backups/sync-cron.log 2>&1") | crontab -
```

---

### 7. Высокая нагрузка / медленная работа

**Симптомы:**
- API отвечает медленно (>5 секунд)
- High CPU или RAM usage
- Таймауты в логах

**Диагностика:**
```bash
# Проверить ресурсы контейнеров
docker stats

# Проверить системные ресурсы
htop
free -h
df -h

# Проверить активные запросы к БД
docker exec litellm_db psql -U llmproxy -d litellm -c "
SELECT pid, usename, application_name, state, query_start, query
FROM pg_stat_activity
WHERE state = 'active'
ORDER BY query_start;"

# Проверить размер таблиц
docker exec litellm_db psql -U llmproxy -d litellm -c "
SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;"
```

**Решение:**
```bash
# 1. Проверить Redis кеш
docker exec litellm-redis-1 redis-cli INFO stats

# 2. Перезапустить сервисы по очереди
docker compose restart redis
sleep 5
docker compose restart litellm

# 3. Увеличить ресурсы (если нужно) в docker-compose.yml
# Добавить лимиты:
# services:
#   litellm:
#     deploy:
#       resources:
#         limits:
#           memory: 2G
#         reservations:
#           memory: 1G

# 4. Очистить старые данные (ОСТОРОЖНО!)
# Например, удалить записи старше 6 месяцев
docker exec litellm_db psql -U llmproxy -d litellm -c "
DELETE FROM \"LiteLLM_SpendLogs\"
WHERE \"startTime\" < NOW() - INTERVAL '6 months';"
```

---

## 🔄 Disaster Recovery

### Полное восстановление из бэкапа

**Сценарий: Сервер полностью вышел из строя**

```bash
# 1. Подготовить новый сервер
# - Ubuntu Server
# - Docker + Docker Compose
# - Nginx + Certbot

# 2. Скопировать последний бэкап
scp -r yan@162.120.16.66:/opt/backups/projects/litellm/latest /tmp/restore

# 3. Создать структуру
mkdir -p /home/yan/litellm/{backups,scripts,grafana/provisioning}

# 4. Скопировать конфиги из бэкапа
cd /tmp/restore
cp configs/*.backup /home/yan/litellm/

# 5. Создать Docker volumes
docker volume create litellm_postgres_data_external
docker volume create litellm_grafana_data_external

# 6. Восстановить PostgreSQL volume
docker run --rm \
  -v litellm_postgres_data_external:/target \
  -v /tmp/restore:/backup:ro \
  alpine sh -c "cd /target && tar xzf /backup/postgres_data.tar.gz"

# 7. Восстановить Grafana volume
docker run --rm \
  -v litellm_grafana_data_external:/target \
  -v /tmp/restore:/backup:ro \
  alpine sh -c "cd /target && tar xzf /backup/grafana_data.tar.gz"

# 8. Запустить сервисы
cd /home/yan/litellm
docker compose up -d

# 9. Проверить
./scripts/health-check.sh

# 10. Настроить DNS и SSL
# Обновить DNS A-записи
# Запустить certbot для SSL
```

### Восстановление только базы данных

```bash
cd /home/yan/litellm

# Остановить зависимые сервисы
docker compose stop litellm litellm-metrics-exporter

# Восстановить из SQL dump
docker exec -i litellm_db psql -U llmproxy -d postgres < backups/latest/postgresql_litellm.sql

# Запустить сервисы
docker compose start litellm litellm-metrics-exporter

# Проверить
docker exec litellm_db psql -U llmproxy -d litellm -c 'SELECT COUNT(*) FROM "LiteLLM_SpendLogs"'
```

---

## 📋 Регулярные задачи

### Ежедневно (автоматически)
- ✅ Бэкапы в 03:00 (локальные + офсайт)
- ✅ Health checks каждые 15 минут
- ✅ Автоматические обновления безопасности

### Еженедельно (вручную)
- Проверить логи: `tail -100 /home/yan/litellm/backups/cron.log`
- Проверить метрики в Grafana
- Проверить размер БД: `docker exec litellm_db psql -U llmproxy -d litellm -c "SELECT pg_size_pretty(pg_database_size('litellm'))"`

### Ежемесячно (вручную)
- Проверить SSL сертификаты: `sudo certbot certificates`
- Проверить использование диска: `df -h`
- Проверить статус Fail2ban: `sudo fail2ban-client status`
- Обновить Docker образы:
  ```bash
  cd /home/yan/litellm
  docker compose pull
  docker compose up -d
  ```

### Ежеквартально (вручную)
- Тестировать восстановление из бэкапа
- Проверить и обновить документацию
- Ревью и очистка старых данных в БД

---

## 🔐 Безопасность

### Проверка безопасности
```bash
# UFW статус
sudo ufw status verbose

# Fail2ban статус
sudo fail2ban-client status
sudo fail2ban-client status sshd
sudo fail2ban-client status nginx-http-auth

# Проверка открытых портов
sudo netstat -tuln | grep LISTEN

# Проверка логов авторизации
sudo tail -50 /var/log/auth.log
```

### Разблокировка IP в Fail2ban
```bash
# Проверить забаненные IP
sudo fail2ban-client status sshd

# Разблокировать IP
sudo fail2ban-client set sshd unbanip <IP_ADDRESS>
```

---

## 📞 Контакты и ссылки

### Endpoints
- **LiteLLM API**: https://litellm.pro-4.ru
- **Grafana**: https://dash.pro-4.ru
- **Сервер**: `ssh yan@142.252.220.116`

### Документация
- Отчёт о миграции: `/home/yan/litellm/MIGRATION_COMPLETE_REPORT.md`
- Скрипты: `/home/yan/litellm/scripts/`
- Конфигурации: `/home/yan/litellm/docker-compose.yml`, `config.yaml`, `.env`

### Полезные команды
```bash
# Быстрый статус
docker compose ps

# Все логи
docker compose logs --tail 100

# Перезапуск
docker compose restart

# Полная остановка и запуск
docker compose down && docker compose up -d

# Health check
./scripts/health-check.sh

# Ручной бэкап
./scripts/backup.sh && ./scripts/sync-backups.sh
```

---

*Последнее обновление: 16 декабря 2025*
