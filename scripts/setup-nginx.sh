#!/bin/bash

#############################################################################
# Nginx Setup Script for LiteLLM on New Server
# Configures nginx reverse proxy for litellm.pro-4.ru and dash.pro-4.ru
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

echo "======================================================================"
echo "  Nginx Configuration Setup for LiteLLM"
echo "  Server: $(hostname)"
echo "======================================================================"
echo ""

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    log_error "Этот скрипт должен выполняться с правами root (sudo)"
    exit 1
fi

#############################################################################
# 1. Создание конфигурации для litellm.pro-4.ru
#############################################################################

log_info "Создание конфигурации для litellm.pro-4.ru..."

cat > /etc/nginx/sites-available/litellm.pro-4.ru.conf <<'NGINX_LITELLM'
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
NGINX_LITELLM

log_success "Конфигурация litellm.pro-4.ru создана"

#############################################################################
# 2. Обновление конфигурации для dash.pro-4.ru
#############################################################################

log_info "Создание конфигурации для dash.pro-4.ru..."

cat > /etc/nginx/sites-available/dash.pro-4.ru.conf <<'NGINX_DASH'
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
NGINX_DASH

log_success "Конфигурация dash.pro-4.ru создана"

#############################################################################
# 3. Удаление старого конфига dash-pro4.conf если он есть
#############################################################################

if [ -L "/etc/nginx/sites-enabled/dash-pro4.conf" ]; then
    log_info "Удаление старого symlink dash-pro4.conf..."
    rm /etc/nginx/sites-enabled/dash-pro4.conf
    log_success "Старый symlink удален"
fi

#############################################################################
# 4. Создание символических ссылок
#############################################################################

log_info "Создание символических ссылок..."

# litellm.pro-4.ru
if [ ! -L "/etc/nginx/sites-enabled/litellm.pro-4.ru.conf" ]; then
    ln -s /etc/nginx/sites-available/litellm.pro-4.ru.conf /etc/nginx/sites-enabled/
    log_success "Symlink для litellm.pro-4.ru создан"
else
    log_info "Symlink для litellm.pro-4.ru уже существует"
fi

# dash.pro-4.ru
if [ -L "/etc/nginx/sites-enabled/dash.pro-4.ru.conf" ]; then
    rm /etc/nginx/sites-enabled/dash.pro-4.ru.conf
fi
ln -s /etc/nginx/sites-available/dash.pro-4.ru.conf /etc/nginx/sites-enabled/
log_success "Symlink для dash.pro-4.ru создан"

#############################################################################
# 5. Проверка конфигурации nginx
#############################################################################

log_info "Проверка конфигурации nginx..."
if nginx -t; then
    log_success "Конфигурация nginx корректна"
else
    log_error "Ошибка в конфигурации nginx"
    exit 1
fi

#############################################################################
# 6. Перезагрузка nginx
#############################################################################

log_info "Перезагрузка nginx..."
systemctl reload nginx
log_success "Nginx перезагружен"

#############################################################################
# 7. Проверка состояния nginx
#############################################################################

log_info "Проверка состояния nginx..."
if systemctl is-active --quiet nginx; then
    log_success "Nginx работает"
else
    log_error "Nginx не запущен"
    exit 1
fi

echo ""
echo "======================================================================"
echo -e "${GREEN}✓ Nginx настроен успешно!${NC}"
echo "======================================================================"
echo ""
echo "Следующие шаги:"
echo ""
echo "1. Обновите DNS записи (если еще не обновили):"
echo "   litellm.pro-4.ru  →  $(hostname -I | awk '{print $1}')"
echo "   dash.pro-4.ru     →  $(hostname -I | awk '{print $1}')"
echo ""
echo "2. Установите SSL сертификаты через certbot:"
echo "   sudo certbot --nginx -d litellm.pro-4.ru"
echo "   sudo certbot --nginx -d dash.pro-4.ru"
echo ""
echo "   Или используйте скрипт:"
echo "   sudo /home/yan/litellm/scripts/setup-ssl.sh"
echo ""
echo "3. Проверьте доступность (после обновления DNS):"
echo "   http://litellm.pro-4.ru  (будет redirect на https)"
echo "   http://dash.pro-4.ru     (будет redirect на https)"
echo ""
echo "======================================================================"
