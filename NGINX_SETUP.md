# Настройка Nginx на новом сервере

## Описание

Эта инструкция описывает настройку nginx reverse proxy для:
- **litellm.pro-4.ru** → LiteLLM API (localhost:4000)
- **dash.pro-4.ru** → Grafana Dashboard (localhost:3098)

## Предварительные требования

✅ Nginx установлен (проверено: nginx/1.18.0)
✅ Certbot установлен (проверено: certbot 1.21.0)
✅ Docker сервисы запущены на портах 4000 и 3098
✅ Скрипты скопированы в `/home/yan/litellm/scripts/`

## Шаг 1: Настройка Nginx (без SSL)

Подключитесь к новому серверу и выполните:

```bash
ssh yan@65.21.202.252
cd /home/yan/litellm
sudo ./scripts/setup-nginx.sh
```

### Что делает скрипт:

1. ✅ Создает `/etc/nginx/sites-available/litellm.pro-4.ru.conf`
2. ✅ Создает `/etc/nginx/sites-available/dash.pro-4.ru.conf`
3. ✅ Удаляет старый конфиг `dash-pro4.conf` (указывал на порт 8051)
4. ✅ Создает символические ссылки в `/etc/nginx/sites-enabled/`
5. ✅ Проверяет конфигурацию nginx (`nginx -t`)
6. ✅ Перезагружает nginx

### Конфигурации nginx:

#### litellm.pro-4.ru.conf

```nginx
server {
    server_name litellm.pro-4.ru;

    proxy_connect_timeout 300s;
    proxy_send_timeout 300s;
    proxy_read_timeout 300s;
    send_timeout 300s;
    client_max_body_size 200M;

    location / {
        proxy_pass http://localhost:4000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    listen 80;
}
```

#### dash.pro-4.ru.conf

```nginx
server {
    server_name dash.pro-4.ru;

    proxy_connect_timeout 300s;
    proxy_send_timeout 300s;
    proxy_read_timeout 300s;
    send_timeout 300s;
    client_max_body_size 200M;

    location / {
        proxy_pass http://localhost:3098;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    listen 80;
}
```

## Шаг 2: Обновление DNS записей

**КРИТИЧНО:** Обновите DNS записи перед получением SSL сертификатов!

```
litellm.pro-4.ru  →  A-запись  →  65.21.202.252
dash.pro-4.ru     →  A-запись  →  65.21.202.252
```

Подождите 5-15 минут для распространения DNS.

### Проверка DNS:

```bash
# На любом компьютере
dig +short litellm.pro-4.ru
dig +short dash.pro-4.ru

# Должно вернуть: 65.21.202.252
```

## Шаг 3: Установка SSL сертификатов

После обновления DNS выполните:

```bash
ssh yan@65.21.202.252
cd /home/yan/litellm
sudo ./scripts/setup-ssl.sh
```

### Что делает скрипт:

1. ✅ Проверяет DNS для каждого домена
2. ✅ Получает SSL сертификаты через Let's Encrypt (certbot)
3. ✅ Настраивает автоматический redirect с HTTP на HTTPS
4. ✅ Обновляет конфигурации nginx
5. ✅ Перезагружает nginx

### Ручная установка SSL (если скрипт не сработал):

```bash
sudo certbot --nginx -d litellm.pro-4.ru
sudo certbot --nginx -d dash.pro-4.ru
```

## Проверка работы

### После Шага 1 (без SSL):

```bash
# На новом сервере
curl http://localhost:4000/health/liveliness
# Ожидается: "I'm alive!"

curl -I http://localhost:3098/api/health
# Ожидается: HTTP 200 OK
```

### После Шага 2 и 3 (с SSL):

```bash
# С любого компьютера (после обновления DNS)
curl https://litellm.pro-4.ru/health/liveliness
# Ожидается: "I'm alive!"

# В браузере
https://dash.pro-4.ru
# Ожидается: Grafana login page
```

## Автоматическое обновление сертификатов

Certbot автоматически настраивает обновление сертификатов через systemd timer:

```bash
# Проверка статуса
sudo systemctl status certbot.timer

# Тест обновления (dry-run)
sudo certbot renew --dry-run
```

Сертификаты будут автоматически обновляться за 30 дней до истечения.

## Порты на новом сервере

| Сервис | Внутренний порт | Внешний доступ | Домен |
|--------|-----------------|----------------|-------|
| LiteLLM API | 4000 | Nginx proxy | litellm.pro-4.ru |
| Grafana | 3098 | Nginx proxy | dash.pro-4.ru |
| PostgreSQL | 5434 | Локальный | - |
| Redis | 6381 | Локальный | - |
| Prometheus | 9092 | Локальный | - |
| Metrics Exporter | 9093 | Локальный | - |

## Отличия от старого сервера

| Параметр | Старый сервер | Новый сервер | Примечание |
|----------|---------------|--------------|------------|
| PostgreSQL порт | 5433 | 5434 | Изменен из-за конфликта |
| Metrics Exporter | 9090 | 9093 | Изменен из-за конфликта |
| LiteLLM API | 4000 | 4000 | Без изменений |
| Grafana | 3098 | 3098 | Без изменений |

## Логи nginx

```bash
# Логи доступа
sudo tail -f /var/log/nginx/access.log

# Логи ошибок
sudo tail -f /var/log/nginx/error.log

# Статус nginx
sudo systemctl status nginx
```

## Устранение неполадок

### Ошибка "nginx: [emerg] bind() to 0.0.0.0:80 failed"

Порт 80 уже занят другим процессом:

```bash
# Проверить что занимает порт 80
sudo lsof -i :80

# Остановить другой веб-сервер
sudo systemctl stop apache2  # если Apache
```

### Certbot не может получить сертификат

**Причина 1:** DNS не обновлен

```bash
dig +short litellm.pro-4.ru
# Должно вернуть: 65.21.202.252
```

**Причина 2:** Порт 80 недоступен извне

```bash
# Проверка с другого компьютера
curl -I http://65.21.202.252
```

**Причина 3:** Firewall блокирует порт 80/443

```bash
# Проверка ufw
sudo ufw status

# Разрешить HTTP/HTTPS
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

### Nginx не перезагружается

```bash
# Проверить конфигурацию
sudo nginx -t

# Посмотреть логи
sudo journalctl -u nginx -n 50
```

## Скрипты

### [scripts/setup-nginx.sh](scripts/setup-nginx.sh)

Настройка nginx reverse proxy (без SSL).

**Использование:**
```bash
sudo /home/yan/litellm/scripts/setup-nginx.sh
```

### [scripts/setup-ssl.sh](scripts/setup-ssl.sh)

Получение SSL сертификатов через Let's Encrypt.

**Использование:**
```bash
sudo /home/yan/litellm/scripts/setup-ssl.sh
```

**Требования:**
- DNS записи обновлены
- Nginx настроен и запущен
- Порты 80 и 443 открыты

## Следующие шаги

После успешной настройки nginx и SSL:

1. ✅ Проверьте доступность через браузер:
   - https://litellm.pro-4.ru
   - https://dash.pro-4.ru

2. ✅ Настройте автоматические бэкапы:
   ```bash
   sudo /home/yan/litellm/scripts/setup-cron.sh
   ```

3. ✅ Мониторинг в течение 48 часов

4. ✅ Старый сервер можно остановить через 48 часов

## Дополнительная информация

- [MIGRATION_README.md](MIGRATION_README.md) - Полное руководство по миграции
- [GIT_MIGRATION_COMPLETE.md](GIT_MIGRATION_COMPLETE.md) - Отчет о Git миграции
- [DNS_UPDATE_INSTRUCTIONS.md](DNS_UPDATE_INSTRUCTIONS.md) - Инструкции по DNS

---

**Дата создания:** 2025-11-02
**Сервер:** 65.21.202.252
**Пользователь:** yan
