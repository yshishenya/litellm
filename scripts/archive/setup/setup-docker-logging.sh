#!/bin/bash
#
# Setup Docker Logging Configuration
# Настраивает ротацию логов для Docker контейнеров
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

echo "======================================================================"
echo "  Docker Logging Configuration Setup"
echo "======================================================================"
echo ""

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    log_error "Этот скрипт должен выполняться с правами root (sudo)"
    exit 1
fi

# Создание конфигурации Docker daemon
log_info "Создание /etc/docker/daemon.json..."

cat > /etc/docker/daemon.json <<'DOCKER_DAEMON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3",
    "compress": "true"
  },
  "storage-driver": "overlay2"
}
DOCKER_DAEMON

log_success "Конфигурация Docker daemon создана"

# Проверка синтаксиса
log_info "Проверка синтаксиса конфигурации..."
if ! python3 -m json.tool /etc/docker/daemon.json > /dev/null; then
    log_error "Ошибка в синтаксисе JSON"
    exit 1
fi
log_success "Синтаксис корректен"

# Перезапуск Docker
log_info "Перезапуск Docker daemon..."
systemctl restart docker

# Ожидание запуска
sleep 5

# Проверка статуса
if systemctl is-active --quiet docker; then
    log_success "Docker daemon перезапущен успешно"
else
    log_error "Docker daemon не запустился"
    exit 1
fi

echo ""
echo "======================================================================"
echo -e "${GREEN}✓ Docker logging настроен успешно!${NC}"
echo "======================================================================"
echo ""
echo "Параметры ротации логов:"
echo "  - Максимальный размер файла: 10MB"
echo "  - Количество файлов: 3"
echo "  - Сжатие: Включено"
echo ""
echo "ВАЖНО: Эти настройки применяются только к НОВЫМ контейнерам."
echo "Для применения к существующим контейнерам выполните:"
echo "  cd /home/yan/litellm"
echo "  docker compose down"
echo "  docker compose up -d"
echo ""
