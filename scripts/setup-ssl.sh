#!/bin/bash

#############################################################################
# SSL Certificate Setup Script for LiteLLM
# Automatically obtains Let's Encrypt SSL certificates via certbot
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
echo "  SSL Certificate Setup for LiteLLM"
echo "  Server: $(hostname)"
echo "======================================================================"
echo ""

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    log_error "Этот скрипт должен выполняться с правами root (sudo)"
    exit 1
fi

# Проверка certbot
if ! command -v certbot &> /dev/null; then
    log_error "certbot не установлен"
    log_info "Установите certbot: sudo apt install certbot python3-certbot-nginx"
    exit 1
fi

# Проверка nginx
if ! systemctl is-active --quiet nginx; then
    log_error "Nginx не запущен"
    exit 1
fi

#############################################################################
# Функция для получения SSL сертификата
#############################################################################

obtain_certificate() {
    local domain=$1

    log_info "Получение SSL сертификата для ${domain}..."

    # Проверка DNS
    log_info "Проверка DNS для ${domain}..."
    SERVER_IP=$(hostname -I | awk '{print $1}')
    DOMAIN_IP=$(dig +short ${domain} | tail -n1)

    if [ -z "$DOMAIN_IP" ]; then
        log_warning "Не удалось определить IP для ${domain}"
        log_warning "Убедитесь, что DNS записи обновлены"
        echo ""
        read -p "Продолжить получение сертификата? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Пропуск ${domain}"
            return 1
        fi
    elif [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
        log_warning "DNS для ${domain} указывает на ${DOMAIN_IP}, но IP сервера ${SERVER_IP}"
        log_warning "Certbot может не пройти валидацию"
        echo ""
        read -p "Продолжить получение сертификата? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Пропуск ${domain}"
            return 1
        fi
    else
        log_success "DNS для ${domain} настроен корректно (${DOMAIN_IP})"
    fi

    # Получение сертификата
    if certbot --nginx -d ${domain} --non-interactive --agree-tos --email admin@pro-4.ru --redirect; then
        log_success "SSL сертификат для ${domain} получен успешно"
        return 0
    else
        log_error "Не удалось получить сертификат для ${domain}"
        return 1
    fi
}

#############################################################################
# Получение сертификатов для доменов
#############################################################################

SUCCESS_COUNT=0
FAILED_COUNT=0

echo "Будут получены SSL сертификаты для следующих доменов:"
echo "  - litellm.pro-4.ru"
echo "  - dash.pro-4.ru"
echo ""
log_warning "ВАЖНО: Убедитесь, что DNS записи обновлены и указывают на этот сервер!"
echo ""
read -p "Продолжить? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Отменено пользователем"
    exit 0
fi

echo ""

# litellm.pro-4.ru
if obtain_certificate "litellm.pro-4.ru"; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
else
    FAILED_COUNT=$((FAILED_COUNT + 1))
fi

echo ""

# dash.pro-4.ru
if obtain_certificate "dash.pro-4.ru"; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
else
    FAILED_COUNT=$((FAILED_COUNT + 1))
fi

#############################################################################
# Проверка конфигурации nginx
#############################################################################

echo ""
log_info "Проверка конфигурации nginx..."
if nginx -t; then
    log_success "Конфигурация nginx корректна"
else
    log_error "Ошибка в конфигурации nginx"
    exit 1
fi

#############################################################################
# Перезагрузка nginx
#############################################################################

log_info "Перезагрузка nginx..."
systemctl reload nginx
log_success "Nginx перезагружен"

#############################################################################
# Итоговый отчет
#############################################################################

echo ""
echo "======================================================================"
echo "  ИТОГОВЫЙ ОТЧЕТ"
echo "======================================================================"
echo ""
echo -e "${GREEN}Успешно:${NC} $SUCCESS_COUNT"
echo -e "${RED}Ошибок:${NC} $FAILED_COUNT"
echo ""

if [ $SUCCESS_COUNT -gt 0 ]; then
    echo "Полученные сертификаты:"
    if [ -d "/etc/letsencrypt/live/litellm.pro-4.ru" ]; then
        echo "  ✓ litellm.pro-4.ru"
    fi
    if [ -d "/etc/letsencrypt/live/dash.pro-4.ru" ]; then
        echo "  ✓ dash.pro-4.ru"
    fi
    echo ""
fi

if [ $FAILED_COUNT -eq 0 ]; then
    echo -e "${GREEN}✓ Все SSL сертификаты получены успешно!${NC}"
    echo ""
    echo "Проверьте доступность:"
    echo "  https://litellm.pro-4.ru"
    echo "  https://dash.pro-4.ru"
    echo ""
    echo "Автоматическое обновление сертификатов:"
    echo "  Certbot автоматически настроил cron для обновления"
    echo "  Проверка: sudo systemctl status certbot.timer"
else
    echo -e "${YELLOW}⚠ Некоторые сертификаты не были получены${NC}"
    echo ""
    echo "Возможные причины:"
    echo "  1. DNS записи не обновлены или не распространились"
    echo "  2. Порт 80 недоступен извне"
    echo "  3. Домены не указывают на этот сервер"
    echo ""
    echo "Ручное получение сертификата:"
    echo "  sudo certbot --nginx -d litellm.pro-4.ru"
    echo "  sudo certbot --nginx -d dash.pro-4.ru"
fi

echo ""
echo "======================================================================"
